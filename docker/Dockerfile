# Container image for `swamp serve`.
#
# The swamp CLI is bootstrapped at build time via the official installer
# (https://swamp-club.com/install.sh). Run as root, the installer drops the
# binary at /usr/local/bin/swamp and auto-detects the platform, so this image
# builds for whatever arch you build it on (linux/amd64 or linux/arm64) with no
# local swamp install required. The binary is glibc-linked, so a slim glibc
# base (debian:bookworm-slim, glibc 2.36) is used.
FROM debian:bookworm-slim

# Release to install: "stable" (default) or a pinned version like
# 20260721.223850.0-sha.713c6583. Override with --build-arg SWAMP_VERSION=...
ARG SWAMP_VERSION=stable

# ca-certificates + curl: fetch the installer and release archive over TLS.
# tar: the installer extracts a .tar.gz. bash: used by the pod command/probes.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tar bash \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://swamp-club.com/install.sh | sh -s -- --version="${SWAMP_VERSION}" \
    && /usr/local/bin/swamp --version \
    && groupadd -g 65532 swamp \
    && useradd -u 65532 -g 65532 -m -d /home/swamp -s /usr/sbin/nologin swamp \
    && mkdir -p /repo && chown 65532:65532 /repo

# Entrypoint wrapper: makes repo prep idempotent against a durable (PVC) repo
# volume, then execs swamp with the container args. See docker/entrypoint.sh.
# Set SWAMP_INIT_SKIP=1 to bypass prep and run the CLI bare.
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER 65532:65532
ENV HOME=/home/swamp
WORKDIR /home/swamp

EXPOSE 9090

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
