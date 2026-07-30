# swamp-serve Helm chart

A Helm chart that runs [`swamp serve`](https://swamp-club.com) — the swamp
WebSocket API server for workflow and model execution — on Kubernetes, plus the
tooling to build the image and verify it locally on [kind](https://kind.sigs.k8s.io).

```
deploy/
├── docker/
│   ├── Dockerfile          # debian:bookworm-slim + the swamp binary
│   ├── entrypoint.sh       # idempotent repo prep, then exec swamp
│   └── build.sh            # stages the binary and builds swamp-serve:local
├── charts/swamp-serve/     # the Helm chart
├── values/
│   └── example.yaml        # deployment overlay template — copy and fill in
└── verify.sh               # one-shot: build → kind → load → install → test
```

The chart carries no site-specific configuration. Everything that differs per
deployment — hostnames, collective, admins, image, storage — belongs in an
overlay values file. Start from [`values/example.yaml`](values/example.yaml),
which marks every field that must be filled in:

```bash
cp values/example.yaml values/my-deployment.yaml
$EDITOR values/my-deployment.yaml      # replace every FILL-ME
helm -n <namespace> upgrade --install serve ./charts/swamp-serve \
  --create-namespace -f values/my-deployment.yaml
```

Keep filled-in overlays out of this repository when the hostnames or collective
names are not public.

## Quick start (local, on kind)

```bash
./deploy/verify.sh            # render checks, build image, create kind cluster, install, test
KEEP=1 ./deploy/verify.sh     # ...and leave the cluster running
```

`verify.sh` starts with a lint and a values matrix (see
[Pre-flight validation](#pre-flight-validation)), so template-level mistakes
surface in seconds rather than after an image build.

Or step by step:

```bash
# 1. Build the image (the installer fetches the swamp binary at build time)
IMAGE=swamp-serve:local ./deploy/docker/build.sh

# 2. Create a cluster and load the image (kind has no registry — copy it in)
kind create cluster --name swampdemo
kind load docker-image swamp-serve:local --name swampdemo

# 3. Install
kubectl create namespace demo
helm -n demo install serve ./deploy/charts/swamp-serve

# 4. Verify
kubectl -n demo rollout status deploy/serve-swamp-serve
helm -n demo test serve
```

## Requirements

- `docker`, `kubectl`, `helm`, and (for local verification) `kind`.
- The image is self-contained: the swamp CLI is bootstrapped at build time by the
  official installer (`curl -fsSL https://swamp-club.com/install.sh | sh`), so no
  local swamp binary is needed — just Docker and network access. Pin a release
  with `SWAMP_VERSION=<version> ./deploy/docker/build.sh`.

## Deploying to a real (remote) cluster

A remote cluster can't use a local `kind load` — it pulls the image from a
registry. Build, push, then point the chart at it:

```bash
# 1. Build and push to a registry your cluster can pull from
IMAGE=ghcr.io/<you>/swamp-serve:0.1.0 ./deploy/docker/build.sh --push

# 2. Install, overriding the image (and pull secret if the registry is private)
helm -n swamp upgrade --install serve ./deploy/charts/swamp-serve \
  --create-namespace \
  --set image.repository=ghcr.io/<you>/swamp-serve \
  --set image.tag=0.1.0 \
  --set image.pullPolicy=IfNotPresent
```

For production also consider: a real TLS cert via `tls.existingSecret`
(e.g. cert-manager) instead of the generated self-signed one, real
`serve.admins` principals, and `persistence.*` PVCs so the repo/datastore
survive restarts.

## Updating swamp

`swamp serve` is updated by **rebuilding the image**, not in place.

`swamp update` does not work inside the pod. The container runs as uid `65532`
with `runAsNonRoot` and all capabilities dropped, while the binary is root-owned
at `/usr/local/bin/swamp`, so it fails with
`Cannot update /usr/local/bin/swamp: permission denied`. Even with root it would
be the wrong move — the new binary would live only in the container's writable
layer and vanish on the next pod replacement, silently reverting the version.

```bash
# 1. Rebuild. --no-cache is REQUIRED when tracking `stable`: the version is a
#    build arg, so an unchanged `SWAMP_VERSION=stable` hits the Docker layer
#    cache and silently rebuilds the OLD binary.
docker build --no-cache --build-arg SWAMP_VERSION=stable \
  -t swamp-serve:local -f deploy/docker/Dockerfile deploy/docker

# 2. Confirm what you actually got before shipping it
docker run --rm --entrypoint swamp swamp-serve:local --version

# 3a. kind: load the image, then restart
kind load docker-image swamp-serve:local --name <cluster>
kubectl -n <ns> rollout restart deploy/<release>-swamp-serve

# 3b. Remote cluster: push a NEW tag and roll it out. Do not overwrite a tag
#     in place — with `pullPolicy: IfNotPresent` nodes keep the cached layer.
IMAGE=ghcr.io/<you>/swamp-serve:<new-version> ./deploy/docker/build.sh --push
helm -n <ns> upgrade serve ./deploy/charts/swamp-serve \
  -f values/<your-overlay>.yaml --set image.tag=<new-version>

# 4. Verify
kubectl -n <ns> exec deploy/<release>-swamp-serve -c serve -- swamp --version
```

`build.sh` takes `SWAMP_VERSION` (default `stable`) but exposes no `--no-cache`
flag, which is why step 1 calls `docker build` directly. Pin a specific release
with `SWAMP_VERSION=<version> ./deploy/docker/build.sh` — pinned versions change
the build arg, so they invalidate the cache on their own.

### An update does not disturb authentication

No device flow, and no `swamp auth server-login` for your users. The two pieces
of auth state both live outside the container image:

| State | Lives in | Survives an image swap? |
| --- | --- | --- |
| OAuth client creds, resolved admins, server tokens | repo vault, on the `persistence.repo` PVC | yes |
| Grants, session records | the datastore tier (PVC, S3, Mongo, …) | yes |

A healthy post-update start logs `Using stored OAuth client credentials from
vault` and `Using cached admin resolution` for each admin. If it instead prints a
device-flow URL, the repo volume was lost — check `persistence.repo`, not the
update.

Two unrelated operations *do* invalidate credentials, so don't confuse them with
an update: repointing the datastore at a **new or empty namespace** (drops
session records — everyone re-runs `swamp auth server-login`), and clearing
`oauth-client-id` from the vault to **re-register** (repeats the device flow).

The init container runs `swamp repo upgrade` on every start, so repo-format
migrations are applied automatically and idempotently.

### Client/server version skew

Some operations are served by the server and need both ends recent — notably
`swamp extension pull --server`, which on an older server hangs until the client
gives up with `Request timed out … the server may not support this operation`.
Read paths like `swamp extension list --server` keep working, which makes it look
like auth or the datastore rather than a version gap.

To locate the layer, run the same pull four ways — local repo, in-pod
(`kubectl exec … --repo-dir /repo`), `--server` read, `--server` write. The first
one that hangs names it.

Note that **local dev builds all report `20260206.200442.0-sha.`** — a
placeholder, not a date, recognisable by the empty `-sha.` suffix. A dev build is
usually *newer* than published stable, so never infer skew direction from it.
Compare against the server's real CalVer from `swamp --version` in the pod.

## How it works

`swamp serve` enforces two rules that shape this chart:

1. **Off-loopback binding requires TLS *and* authentication.** A Kubernetes
   Service must reach the pod on its pod IP, so the server binds `0.0.0.0`.
   That means TLS (`tls.enabled`, on by default — a self-signed cert is
   generated at install time) and `serve.authMode: token` (or `oauth`) are
   both required. Do **not** set `serve.host: 127.0.0.1` — the Service and
   probes would not be able to reach the server.
2. **serve needs an initialized repository.** An init container runs
   `swamp repo init` in the repo volume on first start, and creates the vault
   (`serve.vault.*`) that holds minted token secrets and OAuth client
   credentials.

`HOME` is set to `/home/swamp` so the embedded extension runtime (`~/.swamp`)
has a writable home. The repo and home directories are `emptyDir` by default;
enable `persistence.*` to back them with PVCs.

### Pre-flight validation

The chart re-checks the server's own hard refusals at template time, so a bad
overlay fails during `helm install` with an actionable message instead of
crash-looping the pod with the reason buried in a log. Rendering is refused
when:

- `serve.authMode` is not `none`, `token` or `oauth`
- `serve.host` is off-loopback and `tls.enabled` is false
- `serve.host` is off-loopback and `serve.authMode` is `none`
- `serve.authMode` is `oauth` with neither `serve.oauth.allowedCollectives` nor
  `serve.oauth.allowedUsers` set
- `serve.authMode` is `oauth` with an empty `serve.admins`
- `serve.authMode` is `oauth` with no swamp-club API key (see
  [Authentication](#authentication)) and `swampAuth.assumeExistingLogin` false

`verify.sh` asserts each of these is refused, plus a positive OAuth render,
before it builds anything — so a `helm lint`-clean chart that quietly stopped
enforcing a rule fails the run.

### Health checks

`GET /` is an **unauthenticated** health endpoint returning
`{"status":"ok",...}`. Startup, readiness and liveness probes use it over HTTPS.
The WebSocket API itself requires credentials, so an unauthenticated WS
handshake returns `401` — that is expected.

## Authentication

Two things authenticate independently, and it is easy to conflate them:

- **The server to swamp-club.** `--auth-mode token` and `--auth-mode oauth`
  require the *server process* to hold a swamp-club API key with the `serve:*`
  scope. There is no browser in a pod, so supply it as a Secret rather than
  relying on `swamp auth login`.
- **Clients to the server.** Either minted tokens (`token`) or per-user
  swamp-club login (`oauth`).

Provide the server's key once:

```bash
swamp auth token create --collective <slug> --scopes 'serve:*' --name k8s-serve
kubectl -n <ns> create secret generic swamp-serve-auth \
  --from-literal=SWAMP_API_KEY=swamp_org_...
```

```yaml
swampAuth:
  existingSecret: swamp-serve-auth
```

`swampAuth.apiKey` sets it inline instead (it then lands in the Helm release
history in plaintext — fine for a scratch cluster, not for production). If the
image or the home PVC already carries `~/.swamp` credentials, set
`swampAuth.assumeExistingLogin: true` to satisfy the chart's pre-flight check.

### OAuth mode

OAuth replaces token distribution with self-service login: users authenticate
to swamp-club, and admission is decided by collective membership.

```yaml
serve:
  authMode: oauth
  # swamp-club usernames — NOT user:<sub> ids, which are the token-mode form
  admins:
    - alice
    - bob
  oauth:
    allowedCollectives:
      - acme-corp
    allowedUsers: []          # optional, admits individuals outside the collective
    groupRefreshInterval: 4h  # how often memberships are re-checked
```

At least one of `allowedCollectives` / `allowedUsers` is required — the chart
refuses to render without one. A user matching either policy is admitted;
everyone else is rejected. Membership is managed in swamp-club, not here.

Admission and permissions are separate: `allowedCollectives` decides who may
connect at all, while grants targeting `idp-group:<collective-slug>` decide what
they can do once connected.

#### First start registers an OAuth client

With `oauth.clientId` empty, the server registers itself with swamp-club on
first start using the device flow — it prints a verification URL and a code to
the pod log and **waits** until someone approves it in a browser:

```bash
kubectl -n <ns> logs -f deploy/<release>-swamp-serve -c serve
```

Two consequences worth planning for:

- The pod is not listening during this window. The chart ships a `startupProbe`
  (10 minutes by default, `probes.startup.*`) so the liveness probe does not
  kill the pod mid-registration. Disabling it will break the bootstrap. If you
  deploy your own chart instead of this one and it has no `startupProbe`, raise
  the liveness `initialDelaySeconds` to cover the whole approval window —
  otherwise liveness kills the pod partway through and the flow never finishes.
- The resulting credentials are stored in the repo vault. On the default
  `emptyDir` repo they survive container restarts but **not** pod replacement,
  so every `helm upgrade` or reschedule discards them and the device flow
  repeats. Set `persistence.repo.enabled: true` to keep them, or pre-seed the
  vault (below) to skip the flow entirely.

The pod needs egress to `https://swamp-club.com` (or whatever
`serve.oauth.provider` points at) for both registration and group refresh.

#### Skipping the device flow with a pre-seeded vault

Blocking first boot on a human approving a code in a browser is not viable for
an automated deploy — and on an `emptyDir` repo it recurs on every release. To
avoid the flow, seed the credentials of an already-registered client into the
repo vault before `swamp serve` starts.

`serve.oauth.clientId` on its own is **not** enough. The server takes the
pre-registered path only when it finds a client secret alongside the ID, and it
then still has to turn admin usernames into `user:<sub>` subjects. All three of
these must be present:

| vault key | value |
| --- | --- |
| `oauth-client-id` | the registered client's ID (or pass it as `serve.oauth.clientId`) |
| `oauth-client-secret` | that client's secret — **required**, or the server falls back to the device flow |
| `oauth-resolved-admins` | JSON map of username to subject, e.g. `{"alice":"<sub>","bob":"<sub>"}` |

Supply `oauth-resolved-admins` for every principal in `serve.admins` *and*
`serve.oauth.allowedUsers` (allowed users are keyed `allowed:<username>`).
Without it — and without a stored bootstrap access token — startup fails with
`Cannot resolve usernames — no access token and no cached resolutions`, because
usernames that never resolve to subjects would match no grants.

Seeding from a Kubernetes Secret in the entrypoint works on an `emptyDir` repo,
which makes it the practical option when a PVC is not available.

#### User login

```bash
swamp auth server-login --server wss://swamp.example.com
```

The CLI prints a verification URL and code, the user approves in a browser, and
the token is stored in `~/.config/swamp/servers.json`. Subsequent commands with
`--server wss://swamp.example.com` authenticate automatically.

## Connecting the swamp CLI (`--server`)

`swamp <cmd> --server https://…` needs to (a) **trust the server's TLS cert** and
(b) **present credentials**. The CLI has no `--cert`/`--insecure` flag and no way
to skip verification, so trust comes from the `DENO_CERT` environment variable
(swamp is a Deno binary).

Step 1 below applies to both auth modes. Under `authMode: oauth` the credential
comes from `swamp auth server-login` (see [OAuth mode](#oauth-mode)) and steps 2
and 3 do not apply — skip to using `--server` directly.

> Gotcha: if either the cert isn't trusted **or** the token is missing/invalid,
> the CLI prints the same generic `Could not connect to wss://…`. A trusted-cert
> request with no token is really a `401` — check the server logs
> (`WebSocket auth rejected: no token provided`) to tell them apart.

**1. Trust the cert.** The generated TLS secret includes the signing CA at
`ca.crt` (trusting the leaf `tls.crt` alone is not enough):

```bash
kubectl -n <ns> get secret <release>-swamp-serve-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > swamp-ca.crt
export DENO_CERT="$PWD/swamp-ca.crt"
```

**2. Get a token** (`authMode: token` only). Mint one for an admin principal.
The init container already created the vault that stores the plaintext
(`serve.vault.name`, default `serve`). Run inside the pod so it lands in the
server's datastore:

```bash
kubectl -n <ns> exec deploy/<release>-swamp-serve -c serve -- \
  swamp access token mint mytoken --principal 'user:token|admin' --repo-dir /repo --json
# → copy the "token": "mytoken.<secret>" value
```

**3. Run the command** (port-forward, then use both):

```bash
kubectl -n <ns> port-forward svc/<release>-swamp-serve 9090:9090
DENO_CERT="$PWD/swamp-ca.crt" \
  swamp datastore status --server https://127.0.0.1:9090/ --token 'mytoken.<secret>'
```

> `emptyDir` repos are ephemeral — a vault/token created this way is lost on pod
> restart. Enable `persistence.repo.enabled` to keep them, or supply a real cert
> via `tls.existingSecret` so `DENO_CERT` isn't needed at all.
>
> **Existing installs:** the cert is reused across upgrades, so a release created
> before this change won't have `ca.crt` yet. Delete the TLS secret and upgrade
> to regenerate it: `kubectl -n <ns> delete secret <release>-swamp-serve-tls`,
> then `helm upgrade …` and restart the deployment.

## Ingress (ingress-nginx)

Enable an Ingress that terminates client TLS and reverse-proxies to the service:

```yaml
ingress:
  enabled: true
  path: /
  hosts:
    - swamp-int.example.com
  annotations:
    nginx.ingress.kubernetes.io/server-alias: swamp.example.com
```

Two swamp-specific details are handled for you:

1. **Backend must be HTTPS.** swamp serve only listens on HTTPS (off-loopback
   requires TLS — a hard, non-configurable rule), so the chart injects
   `nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"` plus WebSocket proxy
   timeouts. ingress-nginx does not verify the backend cert, so swamp's
   self-signed cert is fine. (You can't use a plain-HTTP backend.)
2. **Ingress hostnames are auto-trusted.** swamp's Host-header (DNS-rebinding)
   defense rejects WebSocket upgrades whose `Host` isn't trusted — a client
   hitting the ingress hostname would otherwise get `403 "untrusted host"`. The
   chart automatically adds `ingress.hosts` **and** any `server-alias` hosts to
   `--trusted-hosts`. Add further names via `serve.trustedHosts` if needed.

Client TLS: with `ingress.tls.enabled` (default) and no `ingress.tls.secretName`,
a self-signed cert is generated for `ingress.hosts`. Point `ingress.tls.secretName`
at a real cert (e.g. cert-manager) for production.

## Key values

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` / `image.tag` | `swamp-serve` / `local` | Image (use `kind load`ed local tag). |
| `serve.host` | `0.0.0.0` | Bind address. Keep off-loopback for Service access. |
| `serve.port` | `9090` | Listen port. |
| `serve.authMode` | `token` | `none` \| `token` \| `oauth`. Off-loopback needs token/oauth. |
| `serve.admins` | `["user:token\|admin"]` | Admin principals — `user:<sub>` for token mode, plain usernames for oauth. |
| `serve.noSchedule` | `false` | Disable the workflow scheduler. |
| `serve.trustedHosts` | `[]` | Extra Host-header allowlist entries. |
| `serve.extraArgs` | `[]` | Raw extra flags for `swamp serve`. |
| `serve.oauth.allowedCollectives` | `[]` | swamp-club collectives admitted (oauth). One of this/`allowedUsers` is required. |
| `serve.oauth.allowedUsers` | `[]` | Individual usernames or `user:<sub>` subjects admitted (oauth). |
| `serve.oauth.provider` | `""` | OAuth server URL. Empty = `https://swamp-club.com`. |
| `serve.oauth.clientId` | `""` | Pre-registered client ID. Only skips the device flow when an `oauth-client-secret` is also in the vault — see [Skipping the device flow](#skipping-the-device-flow-with-a-pre-seeded-vault). Empty = self-registration on first start. |
| `serve.oauth.groupsField` | `""` | Userinfo field for memberships. Empty = `collectives`. |
| `serve.oauth.groupRefreshInterval` | `""` | Membership re-check interval. Empty = `4h`. |
| `serve.vault.ensure` | `true` | Init container creates the vault holding token/OAuth-client secrets. |
| `serve.vault.type` / `serve.vault.name` | `local_encryption` / `serve` | Vault to create. |
| `swampAuth.existingSecret` | `""` | Secret holding the server's swamp-club API key (`serve:*` scope). |
| `swampAuth.existingSecretKey` | `SWAMP_API_KEY` | Key within that Secret. |
| `swampAuth.apiKey` | `""` | Inline API key (stored in Helm release history — avoid in production). |
| `swampAuth.assumeExistingLogin` | `false` | Skip the API-key pre-flight check when `~/.swamp` already has credentials. |
| `extraEnv` | `[]` | Extra env vars for the init and serve containers. |
| `probes.startup.enabled` | `true` | Gate liveness until the server listens — required for first-boot OAuth registration. |
| `probes.startup.failureThreshold` | `60` | With `periodSeconds: 10`, allows 10 minutes to approve the device flow. |
| `tls.enabled` | `true` | Serve HTTPS/WSS. Required when off-loopback. |
| `tls.existingSecret` | `""` | Use an existing `kubernetes.io/tls` secret instead of generating one. |
| `tls.cert` / `tls.key` | `""` | Inline PEM instead of generating. |
| `persistence.repo.enabled` | `false` | Back the repo dir with a PVC. |
| `persistence.home.enabled` | `false` | Back `~/.swamp` with a PVC. |
| `service.type` / `service.port` | `ClusterIP` / `9090` | Service. |
| `ingress.enabled` | `false` | Create an ingress-nginx Ingress. |
| `ingress.className` | `nginx` | Ingress class. |
| `ingress.path` / `ingress.pathType` | `/` / `Prefix` | Route path. |
| `ingress.hosts` | `[swamp.example.com]` | Hostnames (auto-added to `--trusted-hosts`). |
| `ingress.annotations` | `{}` | Merged over required backend-protocol/WS-timeout defaults. |
| `ingress.tls.enabled` | `true` | Terminate client TLS at the ingress. |
| `ingress.tls.secretName` | `""` | Existing TLS secret; else self-signed for `hosts`. |

## Running your own chart

Plenty of organisations deploy `swamp serve` through an in-house generic-service
chart and cannot adopt this one. This chart is then a reference: it encodes the
server's hard refusals and the non-obvious operational requirements, and
`docker/entrypoint.sh` is directly reusable regardless of which chart starts it.

If you are wiring `swamp serve` into your own chart, these are the requirements
that are easy to miss and expensive to discover in production:

1. **Repo prep must be idempotent, and `repo init` is not.** An entrypoint that
   runs `swamp repo init` unconditionally works on first start and then exits 1
   with `Repository already initialized` on every subsequent start against the
   same volume. This bites sooner than it looks: an `emptyDir` repo survives
   container restarts, so a crash-looping pod hits it on restart #2 even without
   a PVC, and the second failure has a different cause than the first. Branch on
   the `.swamp.yaml` marker: `swamp repo init` when absent, `swamp repo upgrade`
   when present. Never `repo init --force` — it regenerates the `repoId`, and a
   configured datastore then refuses the namespace it already owns.
2. **Guard every `vault create`.** A duplicate exits 1 (`Vault already exists`).
   `swamp vault get <name>` exits 0 when present, 1 when missing.
3. **Point serve at the repo you prepared.** `swamp serve` resolves the repo from
   the working directory unless `--repo-dir` is passed or `SWAMP_REPO_DIR` is
   exported, so a successful init can still be followed by
   `Not a swamp repository: /home/swamp`.
4. **Off-loopback binding requires TLS *and* auth.** This is a non-configurable
   refusal, so the pod must serve HTTPS and your ingress backend protocol must be
   HTTPS. There is no plain-HTTP backend.
5. **Every hostname clients connect through must be trusted.** The Host-header
   (DNS-rebinding) defence answers `403 untrusted host` to WebSocket upgrades
   otherwise. Include ingress hosts and any server aliases in `--trusted-hosts`.
6. **Give the first boot room.** `GET /` is unauthenticated and safe for probes,
   but under `authMode: oauth` the server is not listening while it waits for
   device-flow approval. Use a `startupProbe`, or a liveness
   `initialDelaySeconds` long enough to cover the approval window — or avoid the
   wait entirely by pre-seeding the vault (see
   [Skipping the device flow](#skipping-the-device-flow-with-a-pre-seeded-vault)).
7. **Both `token` and `oauth` need a swamp-club API key on the server process**,
   with the `serve:*` scope, supplied from a Secret. See
   [Authentication](#authentication).
8. **Do not scale past one replica.** Vault and token state is per-pod; a second
   replica breaks auth. Use `Recreate`, and size memory with headroom — the
   process idles around 275-300Mi and in-container CLI runs need more, so a
   512Mi limit gets OOMKilled.

`./deploy/verify.sh` asserts the refusals in 1, 4 and 7 at template time, so it
is worth reading even if you never install this chart.

## Production notes

- Replace the generated self-signed cert with a real one via
  `tls.existingSecret` (e.g. from cert-manager) or `tls.cert`/`tls.key`.
- The chart uses a single replica with a `Recreate` strategy because
  `swamp serve` owns a local datastore — it is not horizontally scalable as-is.
- Runs as non-root (uid/gid `65532`) with all capabilities dropped.
- Enable `persistence.repo` under `authMode: oauth`. The registered OAuth client
  credentials live in the repo vault; on an `emptyDir` repo every restart
  repeats the interactive device flow.
- Supply the server's swamp-club API key via `swampAuth.existingSecret` rather
  than `swampAuth.apiKey`, which is stored in the Helm release history in
  plaintext.

## Teardown

```bash
kind delete cluster --name swampdemo
```
