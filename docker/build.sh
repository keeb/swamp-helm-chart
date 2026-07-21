#!/usr/bin/env bash
# Build the swamp-serve container image.
#
# Stages the swamp binary next to the Dockerfile (Docker COPY can only read from
# the build context) and builds the image. The staged copy is git-ignored.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-swamp-serve:local}"
SWAMP_BIN="${SWAMP_BIN:-$(command -v swamp)}"

if [[ -z "${SWAMP_BIN}" || ! -x "${SWAMP_BIN}" ]]; then
  echo "error: swamp binary not found; set SWAMP_BIN=/path/to/swamp" >&2
  exit 1
fi

echo "Staging binary from ${SWAMP_BIN} ..."
cp "${SWAMP_BIN}" "${HERE}/swamp"
trap 'rm -f "${HERE}/swamp"' EXIT

echo "Building ${IMAGE} ..."
docker build -t "${IMAGE}" -f "${HERE}/Dockerfile" "${HERE}"
echo "Built ${IMAGE}"
