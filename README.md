# swamp-serve Helm chart

A Helm chart that runs [`swamp serve`](https://swamp-club.com) — the swamp
WebSocket API server for workflow and model execution — on Kubernetes, plus the
tooling to build the image and verify it locally on [kind](https://kind.sigs.k8s.io).

```
deploy/
├── docker/
│   ├── Dockerfile          # debian:bookworm-slim + the swamp binary
│   └── build.sh            # stages the binary and builds swamp-serve:local
├── charts/swamp-serve/     # the Helm chart
└── verify.sh               # one-shot: build → kind → load → install → test
```

## Quick start (local, on kind)

```bash
./deploy/verify.sh            # build image, create kind cluster, install, test
KEEP=1 ./deploy/verify.sh     # ...and leave the cluster running
```

Or step by step:

```bash
# 1. Build the image (bakes in the swamp binary from your PATH)
SWAMP_BIN=$(command -v swamp) IMAGE=swamp-serve:local ./deploy/docker/build.sh

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

## How it works

`swamp serve` enforces two rules that shape this chart:

1. **Off-loopback binding requires TLS *and* authentication.** A Kubernetes
   Service must reach the pod on its pod IP, so the server binds `0.0.0.0`.
   That means TLS (`tls.enabled`, on by default — a self-signed cert is
   generated at install time) and `serve.authMode: token` (or `oauth`) are
   both required. Do **not** set `serve.host: 127.0.0.1` — the Service and
   probes would not be able to reach the server.
2. **serve needs an initialized repository.** An init container runs
   `swamp repo init` in the repo volume on first start.

`HOME` is set to `/home/swamp` so the embedded extension runtime (`~/.swamp`)
has a writable home. The repo and home directories are `emptyDir` by default;
enable `persistence.*` to back them with PVCs.

### Health checks

`GET /` is an **unauthenticated** health endpoint returning
`{"status":"ok",...}`. Readiness and liveness probes use it over HTTPS. The
WebSocket API itself requires a bearer token, so an unauthenticated WS handshake
returns `401` — that is expected.

## Connecting the swamp CLI (`--server`)

`swamp <cmd> --server https://…` needs to (a) **trust the server's TLS cert** and
(b) **present a token** (the server runs `authMode: token`). The CLI has no
`--cert`/`--insecure` flag and no way to skip verification, so trust comes from
the `DENO_CERT` environment variable (swamp is a Deno binary).

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

**2. Get a token.** Mint one for an admin principal (needs a vault to store the
plaintext). Run inside the pod so it lands in the server's datastore:

```bash
kubectl -n <ns> exec deploy/<release>-swamp-serve -c serve -- \
  swamp vault create local_encryption tokens --repo-dir /repo
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
| `serve.admins` | `["user:token\|admin"]` | Admin principals. |
| `serve.noSchedule` | `false` | Disable the workflow scheduler. |
| `serve.trustedHosts` | `[]` | Extra Host-header allowlist entries. |
| `serve.extraArgs` | `[]` | Raw extra flags for `swamp serve`. |
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

## Production notes

- Replace the generated self-signed cert with a real one via
  `tls.existingSecret` (e.g. from cert-manager) or `tls.cert`/`tls.key`.
- The chart uses a single replica with a `Recreate` strategy because
  `swamp serve` owns a local datastore — it is not horizontally scalable as-is.
- Runs as non-root (uid/gid `65532`) with all capabilities dropped.

## Teardown

```bash
kind delete cluster --name swampdemo
```
