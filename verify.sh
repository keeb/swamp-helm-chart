#!/usr/bin/env bash
# End-to-end local verification of the swamp-serve Helm chart on kind.
#
# Builds the image, creates a kind cluster, loads the image into it (kind runs
# the cluster as Docker containers, so there is no registry — the image is
# copied into the node), installs the chart, waits for readiness, and runs the
# in-cluster Helm test that probes the health endpoint. Then checks that repo
# prep is idempotent — both for the image entrypoint re-run against a volume it
# already prepared, and for the chart's initContainer across a pod replacement
# on a PVC.
#
#   ./deploy/verify.sh          # build + create + install + test
#   KEEP=1 ./deploy/verify.sh   # leave the cluster running afterwards
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${CLUSTER:-swampdemo}"
IMAGE="${IMAGE:-swamp-serve:local}"
NS="${NS:-demo}"
RELEASE="${RELEASE:-serve}"
CHART="${HERE}/charts/swamp-serve"
CTX="kind-${CLUSTER}"
VOL="swamp-serve-verify-$$"

cleanup() {
  docker volume rm -f "${VOL}" >/dev/null 2>&1 || true
  [[ "${KEEP:-0}" == "1" ]] || kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Rendering chart (lint + values matrix)"
helm lint "${CHART}" >/dev/null
# Positive: OAuth with an admission policy, an API key and an ingress renders.
helm template t "${CHART}" \
  --set serve.authMode=oauth \
  --set serve.admins='{alice}' \
  --set serve.oauth.allowedCollectives='{acme-corp}' \
  --set swampAuth.existingSecret=acme-auth \
  --set ingress.enabled=true --set ingress.hosts='{a.example.com}' >/dev/null
# Negative: each of these must be refused at template time, not at runtime.
refuses() {
  local what="$1"; shift
  if helm template t "${CHART}" "$@" >/dev/null 2>&1; then
    echo "FAIL: chart rendered despite ${what}" >&2
    exit 1
  fi
}
refuses "oauth without an admission policy" --set serve.authMode=oauth --set swampAuth.existingSecret=x
refuses "oauth without a swamp-club API key" --set serve.authMode=oauth --set serve.oauth.allowedCollectives='{acme}'
refuses "off-loopback bind without TLS" --set tls.enabled=false
refuses "an unknown auth mode" --set serve.authMode=bogus

echo "==> Building image ${IMAGE}"
IMAGE="${IMAGE}" bash "${HERE}/docker/build.sh"

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "==> Creating kind cluster ${CLUSTER}"
  kind create cluster --name "${CLUSTER}" --wait 120s
fi

echo "==> Loading image into cluster"
kind load docker-image "${IMAGE}" --name "${CLUSTER}"

echo "==> Installing chart"
kubectl --context "${CTX}" get ns "${NS}" >/dev/null 2>&1 || kubectl --context "${CTX}" create ns "${NS}"
helm --kube-context "${CTX}" -n "${NS}" upgrade --install "${RELEASE}" "${CHART}" \
  --set image.repository="${IMAGE%%:*}" --set image.tag="${IMAGE##*:}" --wait --timeout 180s

echo "==> Rollout status"
kubectl --context "${CTX}" -n "${NS}" rollout status "deploy/${RELEASE}-swamp-serve" --timeout=180s

echo "==> Helm test"
helm --kube-context "${CTX}" -n "${NS}" test "${RELEASE}"

# ---------------------------------------------------------------------------
# Restart safety.
#
# `swamp repo init` exits 1 with "Repository already initialized" on a second run
# against the same volume, and a duplicate `vault create` exits 1 too — so repo
# prep that is not idempotent starts cleanly once and fails on every later start.
# docker/entrypoint.sh branches on the .swamp.yaml marker instead: init when it
# is absent, `swamp repo upgrade` when it is present, and never
# `repo init --force`, which regenerates the repoId and makes a configured
# datastore refuse the namespace the repo already owns.
#
# Two independent consumers of that logic, so two tests. Note the serve
# container overrides `command:`, so entrypoint.sh runs only in the
# initContainer — a serve-container restart re-runs no prep at all, and neither
# case below is reachable through it.
#
#   A. The image entrypoint re-run against a volume it already prepared. That is
#      how the image behaves for anyone keeping the default ENTRYPOINT rather
#      than overriding `command:`, i.e. an in-house chart, on every container
#      restart — including on emptyDir, which outlives the container.
#   B. This chart's repo-init initContainer against a PVC. Init containers re-run
#      on every new pod, so a durable repo volume means the second pod onwards
#      meets a repo that already exists.
# ---------------------------------------------------------------------------
fail() { echo "FAIL: $1" >&2; [[ -n "${2:-}" ]] && echo "$2" >&2; exit 1; }

echo "==> Restart safety A: image entrypoint re-run on an existing repo"
# No args => prep-only mode, so this exercises prep without starting a server.
prep_run() {
  docker run --rm -v "${VOL}:/repo" -e SWAMP_REPO_DIR=/repo \
    --entrypoint /usr/local/bin/entrypoint.sh "${IMAGE}" 2>&1
}
# The whole `repoId: <uuid>` line, compared verbatim across runs. Asserted
# non-empty so a renamed marker key fails loudly instead of comparing "" to "".
marker_id() {
  docker run --rm -v "${VOL}:/repo" --entrypoint bash "${IMAGE}" \
    -c 'grep -E "^repoId:" /repo/.swamp.yaml' 2>&1
}

FIRST="$(prep_run)" || fail "first prep run failed on an empty volume" "${FIRST}"
grep -q "initializing swamp repository" <<<"${FIRST}" \
  || fail "first run did not initialize the repo" "${FIRST}"
ID1="$(marker_id)"
[[ -n "${ID1}" ]] || fail "no repoId line in /repo/.swamp.yaml after init"

SECOND="$(prep_run)" \
  || fail "second prep run failed — repo prep is not idempotent" "${SECOND}"
grep -q "upgrading in place" <<<"${SECOND}" \
  || fail "second run did not take the repo-upgrade branch" "${SECOND}"
grep -q "already present" <<<"${SECOND}" \
  || fail "second run did not detect the existing vault" "${SECOND}"
if grep -q "initializing swamp repository" <<<"${SECOND}"; then
  fail "second run re-initialized an existing repo" "${SECOND}"
fi
ID2="$(marker_id)"
[[ "${ID2}" == "${ID1}" ]] || fail "repoId changed across re-run: '${ID1}' -> '${ID2}'"
echo "    OK: re-run upgraded in place, vault guard held, ${ID1} preserved"

echo "==> Restart safety B: initContainer on a PVC across pod replacement"
k() { kubectl --context "${CTX}" -n "${NS}" "$@"; }
pod_of() {
  k get pod -l "app.kubernetes.io/name=swamp-serve,app.kubernetes.io/instance=$1" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'
}
pod_repo_id() { k exec "$1" -c serve -- bash -c 'grep -E "^repoId:" /repo/.swamp.yaml'; }

PVC_REL="${RELEASE}-pvc"
helm --kube-context "${CTX}" -n "${NS}" upgrade --install "${PVC_REL}" "${CHART}" \
  --set image.repository="${IMAGE%%:*}" --set image.tag="${IMAGE##*:}" \
  --set persistence.repo.enabled=true --wait --timeout 240s

POD1="$(pod_of "${PVC_REL}")"
[[ -n "${POD1}" ]] || fail "no running pod for release ${PVC_REL}"
PVC_ID1="$(pod_repo_id "${POD1}")"
[[ -n "${PVC_ID1}" ]] || fail "no repoId on the PVC repo"

# Replace the pod. The PVC (and the repo on it) outlives it, so the replacement's
# initContainer meets an initialized repo — the case that used to exit 1.
k delete pod "${POD1}" --timeout=180s
k rollout status "deploy/${PVC_REL}-swamp-serve" --timeout=240s
POD2="$(pod_of "${PVC_REL}")"
[[ -n "${POD2}" ]] || fail "no running pod after replacement"
[[ "${POD2}" != "${POD1}" ]] || fail "pod ${POD1} was not actually replaced"

INIT_LOG="$(k logs "${POD2}" -c repo-init)"
grep -q "upgrading in place" <<<"${INIT_LOG}" \
  || fail "initContainer did not take the repo-upgrade branch" "${INIT_LOG}"
if grep -q "initializing swamp repository" <<<"${INIT_LOG}"; then
  fail "initContainer re-initialized a persistent repo" "${INIT_LOG}"
fi
PVC_ID2="$(pod_repo_id "${POD2}")"
[[ "${PVC_ID2}" == "${PVC_ID1}" ]] \
  || fail "repoId changed across pod replacement: '${PVC_ID1}' -> '${PVC_ID2}'"
echo "    OK: ${POD1} -> ${POD2} reused the PVC repo, ${PVC_ID1} preserved"

echo "==> SUCCESS: swamp serve is running and healthy on kind."
# Must not be the final command as a bare `[[ ]] && echo`: when KEEP is unset the
# test is false, the compound returns 1, and the script exits 1 on a good run.
if [[ "${KEEP:-0}" == "1" ]]; then
  echo "    Cluster '${CLUSTER}' left running (KEEP=1). Delete with: kind delete cluster --name ${CLUSTER}"
fi
exit 0
