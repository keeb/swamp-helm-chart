#!/usr/bin/env bash
# End-to-end local verification of the swamp-serve Helm chart on kind.
#
# Builds the image, creates a kind cluster, loads the image into it (kind runs
# the cluster as Docker containers, so there is no registry — the image is
# copied into the node), installs the chart, waits for readiness, and runs the
# in-cluster Helm test that probes the health endpoint.
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

cleanup() { [[ "${KEEP:-0}" == "1" ]] || kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true; }
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

echo "==> SUCCESS: swamp serve is running and healthy on kind."
[[ "${KEEP:-0}" == "1" ]] && echo "    Cluster '${CLUSTER}' left running (KEEP=1). Delete with: kind delete cluster --name ${CLUSTER}"
