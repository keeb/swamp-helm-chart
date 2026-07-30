#!/usr/bin/env bash
# Image entrypoint for `swamp serve`.
#
# Prepares the repo directory, then `exec swamp "$@"`. Written to be safe to run
# on EVERY container start against a *durable* repo volume (PVC), where the
# directory survives restarts in whatever state the previous pod left it.
#
# The rule that drives the whole design:
#
#   `swamp repo init --force` is NOT an idempotency fix. It rewrites .swamp.yaml
#   with a brand-new repoId (repo_marker_repository.ts createInitMarker() calls
#   crypto.randomUUID() unconditionally) and drops any custom keys in that file.
#   With a shared datastore the new ID makes the repo fail to reclaim its own
#   namespace ("Namespace X is already registered in this datastore by repo Y"),
#   and the local datastore cache at $HOME/.swamp/repos/<repoId> goes cold.
#
# So: init ONLY when there is no marker, `repo upgrade` (repoId-preserving)
# otherwise, and guard every create with an existence check.
#
# Config (env, all optional):
#   SWAMP_REPO_DIR         repo path                      [/repo]
#   SWAMP_INIT_TOOL        --tool for init/upgrade        [none]
#   SWAMP_INIT_VAULT       vault to ensure, "" to skip    [default]
#   SWAMP_INIT_VAULT_TYPE  vault type                     [local_encryption]
#   SWAMP_INIT_UPGRADE     run repo upgrade on restart    [1]
#   SWAMP_INIT_RETRIES     attempts per swamp call        [3]
#   SWAMP_INIT_LOCK_TTL    seconds before a lock is stale [300]
#   SWAMP_INIT_SKIP        skip all prep, straight to exec[0]

set -Eeuo pipefail

REPO_DIR="${SWAMP_REPO_DIR:-/repo}"
# Export it so the exec'd command resolves the SAME repo we just prepared.
# Without this, a bare `swamp serve` (no --repo-dir) falls back to the CWD and
# dies with "Not a swamp repository: /home/swamp" after a perfectly good init.
# An explicit --repo-dir in the args still wins over the env var.
export SWAMP_REPO_DIR="${REPO_DIR}"
INIT_TOOL="${SWAMP_INIT_TOOL:-none}"
VAULT_NAME="${SWAMP_INIT_VAULT-default}"
VAULT_TYPE="${SWAMP_INIT_VAULT_TYPE:-local_encryption}"
DO_UPGRADE="${SWAMP_INIT_UPGRADE:-1}"
RETRIES="${SWAMP_INIT_RETRIES:-3}"
LOCK_TTL="${SWAMP_INIT_LOCK_TTL:-300}"
SKIP="${SWAMP_INIT_SKIP:-0}"

MARKER="${REPO_DIR}/.swamp.yaml"
LOCK_DIR="${REPO_DIR}/.swamp-entrypoint.lock"
LOCK_HELD=0

log()  { printf '%s [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

# Every swamp call here is non-interactive: --log forces line-oriented output
# (no TTY spinners in pod logs) and --no-color keeps it greppable.
swamp_q() { swamp "$@" --log --no-color --no-telemetry; }

# ---------------------------------------------------------------------------
# Diagnostics. A failed prep step is invisible in `kubectl logs` unless we say
# what the volume actually looked like, so dump it on any unexpected exit.
# ---------------------------------------------------------------------------
on_err() {
  local rc=$?
  log "prep failed (exit ${rc}); repo state follows"
  log "  whoami:  $(id 2>/dev/null || echo unknown)"
  log "  version: $(swamp --version 2>&1 | tr '\n' ' ' || echo unknown)"
  log "  repo:    ${REPO_DIR}"
  { ls -la "${REPO_DIR}" 2>&1 || true; } | while IFS= read -r l; do log "    ${l}"; done
  log "  marker:  $( [ -f "${MARKER}" ] && echo present || echo absent )"
  log "  df:      $(df -Ph "${REPO_DIR}" 2>&1 | tail -n1 || true)"
  return "${rc}"
}
trap 'on_err' ERR

# The lock dir holds an `owner` file, so a bare rmdir fails on ENOTEMPTY and
# silently leaks the lock -- which wedges every later start until the stale-break
# TTL. Drop the known contents first, then rmdir; no recursive delete.
release_lock() {
  [ "${LOCK_HELD}" -eq 1 ] || return 0
  rm -f "${LOCK_DIR}/owner" 2>/dev/null || true
  rmdir "${LOCK_DIR}" 2>/dev/null || log "WARN: could not release ${LOCK_DIR}"
  LOCK_HELD=0
}
trap 'release_lock' EXIT

# ---------------------------------------------------------------------------
# Retry. Covers the transient IO you get on network-backed volumes (EBS attach
# races, NFS/EFS stalls) rather than real errors -- a deterministic failure just
# burns its attempts and reports the last message.
# ---------------------------------------------------------------------------
retry() {
  local n=1 out rc
  while :; do
    if out="$("$@" 2>&1)"; then
      [ -n "${out}" ] && printf '%s\n' "${out}" >&2
      return 0
    fi
    rc=$?
    if [ "${n}" -ge "${RETRIES}" ]; then
      printf '%s\n' "${out}" >&2
      return "${rc}"
    fi
    log "attempt ${n}/${RETRIES} failed (exit ${rc}), retrying in $((n * 2))s: $*"
    sleep "$((n * 2))"
    n=$((n + 1))
  done
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  mkdir -p "${REPO_DIR}" 2>/dev/null || true
  [ -d "${REPO_DIR}" ] || die "repo dir ${REPO_DIR} does not exist and could not be created"

  # A freshly provisioned PVC is root-owned unless the pod sets fsGroup, and
  # swamp runs as uid 65532. Without this probe the failure surfaces much later
  # as a bare "Permission denied (os error 13): mkdir .../models".
  local probe="${REPO_DIR}/.swamp-write-probe.$$"
  if ! : > "${probe}" 2>/dev/null; then
    die "repo dir ${REPO_DIR} is not writable by uid $(id -u). \
Set pod securityContext.fsGroup to $(id -g) (or chown the volume) so the \
mounted PVC is writable."
  fi
  rm -f "${probe}"

  # $HOME/.swamp holds CLI config and the datastore cache (repos/<repoId>).
  # Read-only HOME is survivable but degrades every restart, so warn loudly.
  local hprobe="${HOME:-/home/swamp}/.swamp-write-probe.$$"
  if ! mkdir -p "${HOME:-/home/swamp}" 2>/dev/null || ! : > "${hprobe}" 2>/dev/null; then
    log "WARN: HOME (${HOME:-unset}) is not writable; CLI config and the \
datastore cache cannot persist. Mount a writable volume at HOME."
  else
    rm -f "${hprobe}"
  fi
}

# ---------------------------------------------------------------------------
# Lock. Two pods overlapping during a rolling update can both init the same
# volume; mkdir is atomic on ext4/xfs and NFS alike. Stale locks (SIGKILLed
# pod) are broken after LOCK_TTL so a crash can't wedge every future start.
# ---------------------------------------------------------------------------
acquire_lock() {
  local waited=0
  while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
    local age
    age="$(( $(date +%s) - $(stat -c %Y "${LOCK_DIR}" 2>/dev/null || date +%s) ))"
    if [ "${age}" -ge "${LOCK_TTL}" ]; then
      log "breaking stale lock ${LOCK_DIR} (age ${age}s >= ${LOCK_TTL}s)"
      rm -f "${LOCK_DIR}/owner" 2>/dev/null || true
      rmdir "${LOCK_DIR}" 2>/dev/null || true
      continue
    fi
    if [ "${waited}" -ge "${LOCK_TTL}" ]; then
      die "timed out after ${waited}s waiting for ${LOCK_DIR}"
    fi
    [ "${waited}" -eq 0 ] && log "waiting for concurrent init to release ${LOCK_DIR}"
    sleep 2
    waited=$((waited + 2))
  done
  LOCK_HELD=1
  # $HOSTNAME is set by bash; the hostname(1) binary is not in a slim image.
  printf 'pid=%s host=%s at=%s\n' "$$" "${HOSTNAME:-unknown}" "$(date -u +%FT%TZ)" \
    > "${LOCK_DIR}/owner" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Repo
# ---------------------------------------------------------------------------
ensure_repo() {
  if [ -f "${MARKER}" ]; then
    # Already initialized. NEVER re-init here -- see the header note on repoId.
    if [ "${DO_UPGRADE}" = "1" ]; then
      log "repo present at ${REPO_DIR}; upgrading in place (preserves repoId)"
      if ! retry swamp_q repo upgrade "${REPO_DIR}" --tool "${INIT_TOOL}"; then
        # Non-fatal: an upgrade failure on an otherwise-valid repo should not
        # stop the server from booting on the existing layout.
        log "WARN: repo upgrade failed; continuing with the repo as-is"
      fi
    else
      log "repo present at ${REPO_DIR}; upgrade disabled"
    fi
    return 0
  fi

  # No marker. Either a genuinely empty volume or a crash between creating the
  # scaffold and writing the marker. Plain `init` handles both -- it is happy
  # with pre-existing subdirs (and with the lost+found that ext4 PVCs carry) --
  # and there is no repoId to preserve, since the marker that held it is gone.
  if [ -e "${REPO_DIR}/.swamp" ] || [ -d "${REPO_DIR}/vaults" ]; then
    log "repo at ${REPO_DIR} has scaffold but no marker (interrupted init?); completing it"
  else
    log "initializing swamp repository at ${REPO_DIR}"
  fi

  retry swamp_q repo init "${REPO_DIR}" --tool "${INIT_TOOL}" \
    || die "repo init failed at ${REPO_DIR}"
  [ -f "${MARKER}" ] || die "repo init reported success but ${MARKER} is missing"
}

# ---------------------------------------------------------------------------
# Vault. `vault create` on an existing name exits 1 with "Vault already exists",
# which is what took the old entrypoint down on the second boot off a durable
# disk. Guard with `vault get` (0 present / 1 missing) and treat a lost create
# race as success.
# ---------------------------------------------------------------------------
ensure_vault() {
  [ -n "${VAULT_NAME}" ] || { log "vault ensure disabled"; return 0; }

  if swamp vault get "${VAULT_NAME}" --repo-dir "${REPO_DIR}" >/dev/null 2>&1; then
    log "vault ${VAULT_NAME} already present"
    return 0
  fi

  log "creating ${VAULT_TYPE} vault ${VAULT_NAME}"
  if retry swamp_q vault create "${VAULT_TYPE}" "${VAULT_NAME}" --repo-dir "${REPO_DIR}"; then
    return 0
  fi

  if swamp vault get "${VAULT_NAME}" --repo-dir "${REPO_DIR}" >/dev/null 2>&1; then
    log "vault ${VAULT_NAME} created concurrently; continuing"
    return 0
  fi
  die "could not create vault ${VAULT_NAME} (type ${VAULT_TYPE})"
}

# ---------------------------------------------------------------------------
main() {
  if [ "${SKIP}" = "1" ]; then
    log "SWAMP_INIT_SKIP=1; skipping repo prep"
  else
    preflight
    acquire_lock
    ensure_repo
    ensure_vault
    release_lock
    log "repo ready at ${REPO_DIR}"
  fi

  # No args => prep-only. Lets an initContainer share this exact logic instead
  # of re-implementing it inline in the chart: command: [entrypoint.sh], args: [].
  if [ "$#" -eq 0 ]; then
    trap - ERR EXIT
    log "no command given; prep-only, exiting 0"
    exit 0
  fi

  # Hand off. exec replaces PID 1 so swamp receives SIGTERM directly and k8s
  # gets a real graceful shutdown instead of a 30s kill timeout.
  trap - ERR EXIT
  log "exec: swamp $*"
  exec swamp "$@"
}

main "$@"
