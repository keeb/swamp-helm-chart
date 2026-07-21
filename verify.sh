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
