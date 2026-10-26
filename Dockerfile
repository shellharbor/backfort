# syntax=docker/dockerfile:1.7
# Backfort relies on GNU tar semantics for ACLs, xattrs, sparse files, and
# ownership. Debian provides the required GNU userland; Alpine/BusyBox does not.
FROM docker:29-cli@sha256:5e6baf67325a79f64ed3bed6863954d5e05d0f3d4e57cbdb14809346814bbfdb AS docker-cli
FROM mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e AS yq
FROM rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5 AS rclone

FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad

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
        gnupg \
        gzip \
        mawk \
        minisign \
        msmtp-mta \
        tar \
        util-linux \
        zstd \
    && test "$(readlink -f /usr/bin/awk)" = /usr/bin/mawk \
    && test "$(dpkg-query -W -f='${db:Status-Status}' gawk 2>/dev/null)" != installed \
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
