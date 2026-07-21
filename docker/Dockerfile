# Container image for `swamp serve`.
#
# The swamp binary is a ~265 MB glibc-linked x86-64 executable (requires glibc
# >= 2.27, no libstdc++ dependency), so a slim glibc base works. It is copied in
# from the build context — see deploy/docker/build.sh, which stages it next to
# this Dockerfile before building.
FROM debian:bookworm-slim

# ca-certificates: TLS trust for any outbound calls the runtime makes.
# curl: used by the Helm test hook to probe the health endpoint.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 65532 swamp \
    && useradd -u 65532 -g 65532 -m -d /home/swamp -s /usr/sbin/nologin swamp \
    && mkdir -p /repo && chown 65532:65532 /repo

COPY swamp /usr/local/bin/swamp
RUN chmod 0755 /usr/local/bin/swamp

USER 65532:65532
ENV HOME=/home/swamp
WORKDIR /home/swamp

EXPOSE 9090

ENTRYPOINT ["swamp"]
CMD ["serve"]
