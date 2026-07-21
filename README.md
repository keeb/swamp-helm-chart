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
- **The `swamp` binary must be on your PATH to build the image** — `docker/build.sh`
  copies it into the build context. If you don't have swamp installed, either
  install it first or set `image.repository`/`image.tag` to a pre-built image
  someone pushed to a registry and skip the build step.

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
