# syntax=docker/dockerfile:1
#
# Network Monitor Agent — Docker image (one-shot run)
#
#   docker run --rm --network host \
#     -e NETWORK_MONITOR_API_KEY -e NETWORK_MONITOR_API_BASE_URL \
#     ghcr.io/pidiman/network-monitor:latest
#
# Contains the same agent as the Raspberry Pi / Debian installer
# (src/network-speedtest.sh) and the official Ookla Speedtest CLI from
# Ookla's packagecloud apt repository. apt selects the package matching the
# target platform (amd64 / arm64 / armhf) — no architecture guessing.
#
# No API key is baked into the image; it is passed at runtime via env.
#
ARG DEBIAN_RELEASE=trixie

FROM debian:${DEBIAN_RELEASE}-slim

ARG OOKLA_REPO_URL=https://packagecloud.io/ookla/speedtest-cli/debian
ARG OOKLA_GPG_URL=https://packagecloud.io/ookla/speedtest-cli/gpgkey
ARG OOKLA_KEYRING=/etc/apt/keyrings/ookla_speedtest-cli-archive-keyring.asc

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Package versions are intentionally not pinned: the image picks up Debian
# security updates on every rebuild.
# hadolint ignore=DL3008
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends bash ca-certificates curl jq tini; \
    # official Ookla repository, same method as install.sh
    . /etc/os-release; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL --retry 3 "$OOKLA_GPG_URL" -o "$OOKLA_KEYRING"; \
    grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$OOKLA_KEYRING"; \
    echo "deb [signed-by=$OOKLA_KEYRING] $OOKLA_REPO_URL/ $VERSION_CODENAME main" \
        > /etc/apt/sources.list.d/ookla_speedtest-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends speedtest; \
    speedtest --version | grep -q 'Speedtest by Ookla'; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 src/network-speedtest.sh /usr/local/bin/network-speedtest

# Unprivileged runtime user. HOME must be writable: the Ookla CLI stores
# its license/GDPR acceptance in ~/.config/ookla.
RUN groupadd --system --gid 10001 monitor \
    && useradd --system --uid 10001 --gid 10001 --create-home --home-dir /home/monitor \
        --shell /usr/sbin/nologin monitor

USER 10001:10001
WORKDIR /home/monitor

# Default API URL (same default as install.sh). NETWORK_MONITOR_API_KEY has
# no default and must be provided at runtime.
ENV NETWORK_MONITOR_API_BASE_URL=https://notes.pidiman.sk/api/network

LABEL org.opencontainers.image.title="network-monitor" \
      org.opencontainers.image.description="Network Monitor agent: Ookla speedtest -> notes.pidiman.sk API (one-shot)" \
      org.opencontainers.image.source="https://github.com/pidiman/network-monitor" \
      org.opencontainers.image.licenses=""

# tini as PID 1: forwards signals (docker stop) and reaps children.
# One run, then exit with the agent's exit code.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/network-speedtest"]
CMD []
