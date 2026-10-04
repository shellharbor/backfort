# syntax=docker/dockerfile:1.7
# Backfort relies on GNU tar semantics for ACLs, xattrs, sparse files, and
# ownership. Debian provides the required GNU userland; Alpine/BusyBox does not.
FROM docker:29-cli AS docker-cli
FROM mikefarah/yq:4.45.1 AS yq
FROM rclone/rclone:1.75.1 AS rclone

FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="Backfort" \
      org.opencontainers.image.description="Recovery-first Linux backup and restore tool" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/shellharbor/backfort"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        acl \
        age \
        attr \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        gawk \
        gnupg \
        gzip \
        minisign \
        msmtp-mta \
        tar \
        util-linux \
        zstd \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -m 0700 /var/lib/backfort /var/tmp/backfort

ENV HOME=/var/lib/backfort \
    XDG_STATE_HOME=/var/lib/backfort \
    TMPDIR=/var/tmp/backfort \
    GNUPGHOME=/var/lib/backfort/gnupg

# The Docker client is only used when a job explicitly configures a
# docker_compose source and the caller deliberately mounts the host socket.
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-compose \
  /usr/local/libexec/docker/cli-plugins/docker-compose
COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

COPY --chmod=0755 backfort.sh /usr/local/bin/backfort
COPY config.example.yaml /usr/share/doc/backfort/config.example.yaml
COPY LICENSE /usr/share/doc/backfort/LICENSE

# Root is deliberate: preserving numeric owners and restoring application data
# owned by other UIDs requires it. Operators can supply --user for files-only
# jobs where their mounts do not require full recovery fidelity.
USER root
WORKDIR /work
STOPSIGNAL SIGTERM

# Backfort is a one-shot CLI, not a daemon. A default doctor run provides a
# useful configuration/readiness result and fails clearly when no config mount
# is supplied. Do not add a Docker HEALTHCHECK for an exited job container.
ENTRYPOINT ["/usr/local/bin/backfort"]
CMD ["-c", "/etc/backfort/config.yaml", "doctor"]
