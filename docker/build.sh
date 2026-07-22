#!/usr/bin/env bash
# Build (and optionally push) the swamp-serve container image.
#
# The swamp CLI is bootstrapped inside the image by the official installer, so
# no local swamp binary is needed — just Docker and network access.
#
#   ./build.sh                                  # build swamp-serve:local
#   IMAGE=ghcr.io/you/swamp-serve:0.1.0 ./build.sh --push
#   SWAMP_VERSION=20260721.223850.0-sha.713c6583 ./build.sh   # pin a release
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-swamp-serve:local}"
SWAMP_VERSION="${SWAMP_VERSION:-stable}"

PUSH=0
[[ "${1:-}" == "--push" ]] && PUSH=1

echo "Building ${IMAGE} (swamp version: ${SWAMP_VERSION}) ..."
docker build \
  --build-arg "SWAMP_VERSION=${SWAMP_VERSION}" \
  -t "${IMAGE}" \
  -f "${HERE}/Dockerfile" \
  "${HERE}"
echo "Built ${IMAGE}"

if [[ "${PUSH}" == "1" ]]; then
  echo "Pushing ${IMAGE} ..."
  docker push "${IMAGE}"
  echo "Pushed ${IMAGE}"
fi
