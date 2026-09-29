# Network Monitor Agent

Client agent for **Network Monitor**: measures internet connectivity with the
**official Ookla Speedtest CLI** and reports results to the Network Monitor API
at **[notes.pidiman.sk](https://notes.pidiman.sk)**.

Two ways to run the same agent:

- **Raspberry Pi / Debian** — interactive installer (`install.sh`)
- **Docker** — image `ghcr.io/pidiman/network-monitor`, primarily for
  **Synology NAS + Container Manager**, usable on any Docker host

Scheduling (systemd timer / periodic container) is **not implemented yet** —
each run performs one measurement. See [systemd/README.md](systemd/README.md).

---

## Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Raspberry Pi / Debian installation](#3-raspberry-pi--debian-installation)
4. [Docker](#4-docker)
5. [Synology Container Manager](#5-synology-container-manager)
6. [Configuration](#6-configuration)
7. [Manual run](#7-manual-run)
8. [Updating](#8-updating)
9. [Uninstall](#9-uninstall)
10. [GHCR](#10-ghcr)
11. [Security](#11-security)
12. [Troubleshooting](#12-troubleshooting)

Appendix: [Development & tests](#development--tests)

---

## 1. Overview

One run of the agent:

1. loads the API key + API URL (environment variables or config file),
2. `GET {base}/config` — the server identifies the device by its API key and
   returns `device_key`, `enabled`, interval, offset,
3. `enabled=false` → exits `0` without measuring,
4. runs `speedtest --accept-license --accept-gdpr --format=json`,
5. converts the Ookla JSON into the API payload,
6. `POST {base}/speedtests`, prints the result, exits.

> This repository contains **only the client side**. The server application
> and database live in the separate `notes-by-chatgpt` project.

Device name, interval and offset are **never configured on the device** — they
are managed in the notes.pidiman.sk admin.

## 2. Architecture

```
Ookla Speedtest CLI
        ↓
Network Monitor Agent   (src/network-speedtest.sh — same script everywhere)
        ↓
HTTP API                (X-API-Key, JSON)
        ↓
notes.pidiman.sk
        ↓
PostgreSQL / Dashboard
```

Delivery paths:

```
Raspberry Pi / Debian                     Docker / Synology
─────────────────────                     ─────────────────
git clone                                 GitHub repository (push to main / tag v*)
    ↓                                         ↓
sudo ./install.sh                         GitHub Actions (Buildx, multi-arch)
    ↓                                         ↓
/usr/local/bin/network-speedtest          ghcr.io/pidiman/network-monitor
/etc/notes-network-monitor/agent.env          ↓
                                          Synology Container Manager (env vars)
```

Repository layout:

```
network-monitor/
├── README.md
├── install.sh                      # RPi/Debian interactive installer / updater
├── uninstall.sh                    # removes agent, optionally config
├── src/
│   └── network-speedtest.sh        # the agent (used by installer AND Docker image)
├── config/
│   └── agent.env.example           # config file template (no secrets)
├── docker/
│   ├── Dockerfile                  # image: Debian slim + Ookla CLI + agent
│   ├── docker-compose.example.yml  # Synology / Compose example (no secrets)
│   └── .env.example                # template for a local, git-ignored .env
├── .github/workflows/
│   └── docker-publish.yml          # tests + multi-arch build + push to GHCR
├── .dockerignore                   # build context = the agent script only
├── systemd/
│   └── README.md                   # placeholder, scheduling comes later
└── tests/
    ├── test-agent.sh               # offline agent tests (fake curl/speedtest)
    ├── test-docker.sh              # image tests against a mock API container
    └── fixtures/
        ├── fake-speedtest          # canned Ookla output
        └── mock_api.py             # mock of the device API
```

### Getting a device API key (both variants)

1. **notes.pidiman.sk → Admin → Network Devices → Add device**.
2. Set name, device key (e.g. `rpi-npm`, `ds220`), interval / offset, enabled.
3. Copy the generated API key (`nm_xxxxxxxxxxxxxxxx`). It is shown **once** —
   the server stores only its SHA-256 hash, the plaintext key exists only on
   the device afterwards.

---

## 3. Raspberry Pi / Debian installation

### Supported systems

| OS                                   | Architecture (dpkg)       | Status                         |
|--------------------------------------|---------------------------|--------------------------------|
| Raspberry Pi OS 64-bit (bookworm+)   | `arm64` / aarch64         | primary target                 |
| Raspberry Pi OS 32-bit               | `armhf` / armv7l          | supported (Ookla armhf build)  |
| Debian 11 / 12 / 13                  | `arm64`, `amd64`          | supported                      |
| Debian derivatives (Ubuntu, …)       | `arm64`, `amd64`          | best effort, warning shown     |
| Pi Zero / Pi 1 (ARMv6)               | `armhf` / armv6l          | not guaranteed (warning shown) |

The installer checks `/etc/os-release` and `dpkg --print-architecture`
(the dpkg architecture matters: a 64-bit kernel with a 32-bit userland reports
`aarch64` but needs `armhf` packages).

### Prerequisites

- Debian-based system with `apt-get`, `bash`
- `sudo` rights (or a root shell)
- Internet access to `packagecloud.io` (Ookla repository) and to the API
- A **device API key** (see [above](#getting-a-device-api-key-both-variants))

Installed automatically when missing: `curl`, `jq`, `ca-certificates`,
official **Ookla Speedtest CLI** (package `speedtest`).

> ⚠️ The Python package `speedtest-cli` (`apt install speedtest-cli` /
> `pip install speedtest-cli`) is a **different program** with a different JSON
> format and is **not supported**. The installer detects it — see
> [Troubleshooting](#wrong-speedtest-python-speedtest-cli).

### Install

```bash
sudo apt-get update && sudo apt-get install -y git   # if git is missing
git clone https://github.com/pidiman/network-monitor.git
cd network-monitor
sudo ./install.sh
```

Run `install.sh` **with sudo from your normal user** (e.g. `pi`). The config
will then be owned by that user, so the agent runs without sudo.

Installer flow:

```
Network Monitor Agent Installer

Detected OS: Debian GNU/Linux 12 (bookworm) (Raspberry Pi)
Architecture: aarch64 (dpkg: arm64)
Agent user: pi

Installing dependencies...
✓ curl already installed
✓ jq already installed
✓ ca-certificates already installed

Checking Ookla Speedtest...
✓ Official Ookla Speedtest CLI already installed: Speedtest by Ookla 1.2.0.84 ...

Installing agent...
✓ Installed /usr/local/bin/network-speedtest (version 0.2.0)

Configuration

API URL:
[https://notes.pidiman.sk/api/network] (Enter for default):

Device API key (hidden input):
✓ Configuration written: /etc/notes-network-monitor/agent.env (owner pi, mode 600)

Testing API connection...

✓ Authentication successful

Device:   rpi-npm
Enabled:  true
Interval: 60 min
Offset:   5 min

Installation complete.
Run first speedtest now? [y/N]:
```

What `install.sh` does, step by step:

1. Re-executes itself via `sudo` if not started as root (`SUDO_USER` is kept).
2. Checks OS (`/etc/os-release`: Debian / Raspberry Pi OS) and architecture.
3. Determines the **agent user**: `$SUDO_USER`; when run directly as root it
   asks (default: owner of an existing config, else `root`).
4. Installs only the missing packages among `curl jq ca-certificates`
   (`apt-get update` only when something must be installed; never `upgrade`).
5. Ookla CLI:
   - already the official Ookla CLI → nothing to do;
   - Python `speedtest-cli` from the Debian package → offers `apt-get remove speedtest-cli` (default **No**);
   - Python `speedtest-cli` from pip or an unknown `speedtest` binary → stops with instructions, **removes nothing**;
   - missing → adds the official Ookla packagecloud apt repository (key in
     `/etc/apt/keyrings/`, `signed-by=`), then `apt-get install speedtest`.
     If Ookla does not publish the current Debian codename yet, it falls back
     to `bookworm` → `bullseye` → `buster` (the CLI is a static binary).
6. Installs/updates `/usr/local/bin/network-speedtest` (mode 755, root-owned).
7. Config: keeps an existing one (asks), or asks for API URL + hidden API key.
8. Tests the API as the agent user (`network-speedtest --check`) and shows the
   device info from the server. On HTTP 401 it offers to enter another key; on
   a connection error it offers to change the URL.
9. Optionally runs the first real speedtest.

Testing against a local/dev server — just type a different URL at the prompt:

```
API URL:
[https://notes.pidiman.sk/api/network] (Enter for default): http://192.168.1.27:3077/api/network
```

---

## 4. Docker

Image: **`ghcr.io/pidiman/network-monitor`**

| Tag                    | Source                                     |
|------------------------|--------------------------------------------|
| `latest`               | every push to `main`                       |
| `1.2.3`, `1.2`, `v1.2.3` | Git tag `v1.2.3`                         |
| `sha-abc1234`          | the exact commit                           |

Platforms: `linux/amd64`, `linux/arm64`, `linux/arm/v7` — one multi-arch tag,
Docker pulls the right variant automatically.

The image contains Debian (trixie-slim), `bash`, `curl`, `jq`,
`ca-certificates`, `tini`, the **official Ookla Speedtest CLI** (from Ookla's
packagecloud apt repository — apt picks the package for the target
architecture) and the unchanged agent `src/network-speedtest.sh` as
`/usr/local/bin/network-speedtest`. It runs as an unprivileged user
(uid/gid `10001`). **No API key is part of the image.**

### Behaviour: one-shot

```
docker run --rm ...
      ↓
GET config → speedtest → POST result
      ↓
exit (container stops)
```

The container's exit code is the agent's exit code (see [Manual run](#7-manual-run)).
`enabled=false` → exit `0` without a speedtest. There is no scheduler, loop or
healthcheck (a one-shot job does not need one).

### docker run

```bash
# key is read from your shell environment, not typed on the command line:
read -rs NETWORK_MONITOR_API_KEY && export NETWORK_MONITOR_API_KEY

docker run --rm --network host \
  -e NETWORK_MONITOR_API_KEY \
  -e NETWORK_MONITOR_API_BASE_URL=https://notes.pidiman.sk/api/network \
  ghcr.io/pidiman/network-monitor:latest

# other commands
docker run --rm ghcr.io/pidiman/network-monitor:latest --version
docker run --rm --network host -e NETWORK_MONITOR_API_KEY \
  ghcr.io/pidiman/network-monitor:latest --check      # auth test, no speedtest
```

`-e NETWORK_MONITOR_API_KEY` (without `=value`) passes the variable from your
shell, so the key does not end up in shell history. Alternatively use
`--env-file`. `NETWORK_MONITOR_API_BASE_URL` defaults to
`https://notes.pidiman.sk/api/network` inside the image.

### Docker Compose

[docker/docker-compose.example.yml](docker/docker-compose.example.yml):

```yaml
services:
  network-monitor:
    image: ghcr.io/pidiman/network-monitor:latest
    container_name: network-monitor
    network_mode: host
    environment:
      NETWORK_MONITOR_API_KEY: "${NETWORK_MONITOR_API_KEY}"
      NETWORK_MONITOR_API_BASE_URL: "${NETWORK_MONITOR_API_BASE_URL:-https://notes.pidiman.sk/api/network}"
    restart: "no"
```

```bash
cd docker
cp .env.example .env && chmod 600 .env   # fill in the key; .env is git-ignored
docker compose -f docker-compose.example.yml up       # one run, then exits
```

`network_mode: host` — the measurement uses the host's network stack directly
(no Docker NAT in between). No ports are published; the container only makes
outbound connections.

---

## 5. Synology Container Manager

Tested target: DSM 7.2+ with **Container Manager**. Works on x86_64 models
(e.g. DS220+, `linux/amd64`) and ARMv8 models (e.g. DS220j, `linux/arm64`).

### Step 1 — register the device

1. **notes.pidiman.sk → Admin → Network Devices → Add device**
2. Fill in, e.g.:

   | Field      | Value                                           |
   |------------|-------------------------------------------------|
   | Name       | `Synology DS220`                                |
   | Device key | `ds220`                                         |
   | IP         | IP address of the NAS                           |
   | Interface  | `eth0` (see note below)                         |
   | Enabled    | ON                                              |
   | Interval   | `60`                                            |
   | Offset     | `10`                                            |

3. Copy the one-time **`nm_…` API key**.

> Interface note: with `network_mode: host` Ookla reports the NAS's own
> interface. On Synology it is usually `eth0`, but can be `ovs_eth0`
> (Open vSwitch enabled, e.g. by Virtual Machine Manager) or `bond0`.
> The first result shows the real value (`interface_name`).

### Step 2 — make sure the image can be pulled

The GHCR package should be **public** (see [GHCR](#10-ghcr)). If it is
private, set up credentials first ([private package](#private-package-credentials)).

### Step 3 — create the project

1. **File Station**: create a folder, e.g. `docker/network-monitor`
   (on the `docker` shared folder).
2. **Container Manager → Project → Create**
   - **Project name:** `network-monitor`
   - **Path:** `/docker/network-monitor`
   - **Source:** *Create docker-compose.yml*
3. Paste the YAML and fill in the two values:

   ```yaml
   services:
     network-monitor:
       image: ghcr.io/pidiman/network-monitor:latest
       container_name: network-monitor
       network_mode: host
       environment:
         NETWORK_MONITOR_API_KEY: "nm_PASTE_YOUR_DEVICE_KEY_HERE"
         NETWORK_MONITOR_API_BASE_URL: "http://192.168.1.27:3077/api/network"
       restart: "no"
   ```

   - `NETWORK_MONITOR_API_KEY` — the key from step 1.
   - `NETWORK_MONITOR_API_BASE_URL` — see [LAN variant](#lan-variant-no-hairpin-nat)
     below. If the NAS can reach the public URL, use
     `https://notes.pidiman.sk/api/network`.

   This compose file is stored **only on the NAS** (in the project folder), never
   in Git. Keep the folder's permissions restricted to administrators.

   *Alternative:* keep the `${NETWORK_MONITOR_API_KEY}` placeholders from
   `docker/docker-compose.example.yml` and create a `.env` file with the values
   in the same project folder (File Station); Compose reads `.env` from the
   project directory.

4. **Web portal settings:** leave disabled (no web UI, no ports).
5. **Summary:** keep *Start the project once it is created* checked → **Done**.

Container Manager pulls the image, runs the container once, and the container
stops.

### Step 4 — check the result

**Container Manager → Container → `network-monitor` → Details → Log**
(or *Project → network-monitor → Container → Log*):

```
Network Monitor
Device: ds220

Running speedtest...

Download: 925.28 Mbps
Upload:   931.49 Mbps
Ping:     2.713 ms
Jitter:   0.935 ms
Server:   ACS, Bratislava
Result:   https://www.speedtest.net/result/c/...

Sending result to API...

Result stored successfully.
ID: 42
```

The container status is then *Stopped* (exit code `0` = success). The API key
never appears in the log. Then check the dashboard on notes.pidiman.sk.

**Another measurement:** Container → `network-monitor` → **Start** (runs once
again, then stops).

### LAN variant (no hairpin NAT)

`notes.pidiman.sk` resolves to the **public IP**. Devices inside the home LAN
can reach it only if the router supports *hairpin NAT* (NAT loopback). The
current LAN has no working hairpin NAT, so LAN devices use the API server's
**LAN address** directly:

```
NETWORK_MONITOR_API_BASE_URL=http://192.168.1.27:3077/api/network
```

This is specific to the current home network, **not a general requirement**:

- devices outside the LAN, or a LAN with working hairpin NAT / split DNS,
  use `https://notes.pidiman.sk/api/network` (the default);
- the LAN URL is plain HTTP — the key travels unencrypted inside the LAN only.
  Prefer HTTPS as soon as the network allows it (NAT loopback on the router, or
  a local DNS record for `notes.pidiman.sk` pointing to the internal reverse proxy).

The same applies to Raspberry Pi installs (enter the LAN URL at the installer prompt).

---

## 6. Configuration

The agent reads exactly two settings:

| Variable                        | Meaning                                        |
|---------------------------------|------------------------------------------------|
| `NETWORK_MONITOR_API_KEY`       | device API key (`nm_…`)                        |
| `NETWORK_MONITOR_API_BASE_URL`  | API base, e.g. `https://notes.pidiman.sk/api/network` (no `/config` suffix) |

Where they come from (first match wins):

1. **Environment variables** — if **both** are set (Docker, Compose, Synology).
2. **Config file** `/etc/notes-network-monitor/agent.env` (Raspberry Pi /
   Debian installer). Path override for tests: `NETWORK_MONITOR_CONFIG=/path`.

If only one variable is set and no config file exists, the agent exits with a
clear configuration error (exit `2`). The Docker image sets a default
`NETWORK_MONITOR_API_BASE_URL`, so in Docker only the key is mandatory.

Interval / offset / enabled are managed on notes.pidiman.sk only.

### Config file (Raspberry Pi / Debian)

| Path                                   | Owner       | Mode  |
|----------------------------------------|-------------|-------|
| `/etc/notes-network-monitor/`          | agent user  | `700` |
| `/etc/notes-network-monitor/agent.env` | agent user  | `600` |
| `/usr/local/bin/network-speedtest`     | root        | `755` |

`agent.env`:

```ini
NETWORK_MONITOR_API_KEY=nm_xxxxxxxxxxxxxxxxxxxxxxxxx
NETWORK_MONITOR_API_BASE_URL=https://notes.pidiman.sk/api/network
```

Only these two keys are read. Plain `KEY=VALUE` lines; `#` comments and
surrounding quotes are allowed. The file is **parsed, never sourced/executed**.

To change the key or URL later, either re-run `sudo ./install.sh` and answer
`n` to *Keep existing configuration?*, or edit the file directly
(`nano /etc/notes-network-monitor/agent.env` as the agent user).

### Docker

Environment variables only — `environment:` in Compose, `-e` / `--env-file`
with `docker run`. No file or volume is needed.

---

## 7. Manual run

Raspberry Pi / Debian, as the agent user (no sudo needed):

```bash
network-speedtest            # full run: config → speedtest → POST result
network-speedtest --check    # only verify API key/URL and show device info
network-speedtest --version
network-speedtest --help
```

Docker: same arguments after the image name, e.g.
`docker run --rm --network host -e NETWORK_MONITOR_API_KEY ghcr.io/pidiman/network-monitor:latest --check`.

Example output:

```
Network Monitor
Device: rpi-npm

Running speedtest...

Download: 925.28 Mbps
Upload:   931.49 Mbps
Ping:     2.713 ms
Jitter:   0.935 ms
Server:   ACS, Bratislava
Result:   https://www.speedtest.net/result/c/...

Sending result to API...

Result stored successfully.
ID: 2
```

What the agent does:

1. Loads the configuration (environment, else config file).
2. Checks `curl`, `jq` and that `speedtest` is the official Ookla CLI.
3. `GET {base}/config` → validates JSON, reads `device_key`, `enabled`.
4. `enabled=false` → prints a message and exits `0` without a speedtest.
5. Runs `speedtest --accept-license --accept-gdpr --format=json`
   (non-interactive, 300 s timeout).
6. Verifies a `"type": "result"` object, converts bandwidth bytes/s → Mbps
   (`× 8 / 1 000 000`, 2 decimals) and builds the payload.
7. `POST {base}/speedtests`, handles the HTTP status, prints the result.

HTTP handling & exit codes (identical for the container):

| Situation                                   | Result                  | Exit |
|---------------------------------------------|-------------------------|------|
| success (`201`), duplicate (`200` + `duplicate:true`), device disabled | OK | `0` |
| missing dependency, wrong `speedtest`       | error                   | `1`  |
| config missing / invalid                    | error                   | `2`  |
| `401` (GET or POST)                         | invalid / revoked key   | `3`  |
| speedtest failed / timed out / bad output   | error                   | `4`  |
| `400` payload rejected, `5xx`, other status, network/curl error, invalid JSON | error | `5` |

Timeouts: connect 10 s; GET 30 s; POST 60 s; speedtest 300 s.

---

## 8. Updating

### Raspberry Pi / Debian

```bash
cd ~/network-monitor
git pull
sudo ./install.sh        # answer Y to "Keep existing configuration?"
```

The installer replaces `/usr/local/bin/network-speedtest` with the version
from the checkout (it reports `old → new` version, or "already up to date"),
keeps the config and API key, and does not reinstall packages that are
already present. There is no automatic update mechanism (by design, for now).

### Docker image

Every push to `main` publishes a new `:latest`. To release a version:

```bash
git tag v1.0.0
git push origin v1.0.0     # → :1.0.0, :1.0, :v1.0.0
```

To pin a version on a host, use e.g. `ghcr.io/pidiman/network-monitor:1.0.0`
instead of `:latest`.

**Synology:** Container Manager → **Image** → `ghcr.io/pidiman/network-monitor`
→ *Update* (shown when a newer `latest` exists), then start the container again.
Alternatively over SSH: `sudo docker pull ghcr.io/pidiman/network-monitor:latest`,
then Container Manager → Project → `network-monitor` → Action → **Build**
(recreates the container with the new image).

**Other hosts:** `docker compose pull && docker compose up` or
`docker pull ghcr.io/pidiman/network-monitor:latest`.

---

## 9. Uninstall

### Raspberry Pi / Debian

```bash
cd ~/network-monitor
sudo ./uninstall.sh
```

- always removes `/usr/local/bin/network-speedtest`
- asks `Remove configuration and API key? [y/N]` (default **No**)
  - No → `/etc/notes-network-monitor/agent.env` is kept (re-install later without a new key)
  - Yes → the whole `/etc/notes-network-monitor` directory is removed
- does **not** remove the Ookla CLI, curl, jq or the Ookla apt repository
  (other software may use them). Remove manually if wanted:
  `sudo apt-get remove speedtest && sudo rm /etc/apt/sources.list.d/ookla_speedtest-cli.list /etc/apt/keyrings/ookla_speedtest-cli-archive-keyring.asc`

### Docker / Synology

Container Manager → Project → `network-monitor` → Action → **Stop**, then
**Delete** (removes the project/container); Image → delete
`ghcr.io/pidiman/network-monitor`; delete the project folder (it contains the
key if you put it into the YAML or `.env`).
Other hosts: `docker compose down && docker image rm ghcr.io/pidiman/network-monitor:latest`.

After removing a device, revoke its API key in the notes.pidiman.sk admin as well.

---

## 10. GHCR

### How `ghcr.io/pidiman/network-monitor:latest` is created

[.github/workflows/docker-publish.yml](.github/workflows/docker-publish.yml):

1. Trigger: push to `main`, push of a tag `v*`, pull request (build only),
   or manual *Run workflow*.
2. Job **test**: `bash -n`, `shellcheck`, `tests/test-agent.sh`,
   `tests/test-docker.sh` (image against a mock API).
3. Job **docker** (only if tests pass):
   QEMU + Docker **Buildx** → `docker/metadata-action` computes tags →
   login to `ghcr.io` with the built-in **`GITHUB_TOKEN`** →
   `docker/build-push-action` builds `linux/amd64,linux/arm64,linux/arm/v7`
   and pushes one multi-arch manifest.
4. Permissions: `contents: read`, `packages: write`. No other secrets.

Progress: GitHub → repository → **Actions** → *Docker image*.

### Make the package public

A new GHCR package is usually **private** after the first publish. For simple
use in Synology Container Manager make it public:

1. GitHub → your profile → **Packages** (or `https://github.com/pidiman?tab=packages`)
2. **network-monitor**
3. **Package settings** (right side)
4. *Danger Zone* → **Change visibility** → **Public** → confirm by typing the name

The image contains no secrets, so public visibility is safe. Check (logged out):
`docker pull ghcr.io/pidiman/network-monitor:latest`.

While there, *Manage Actions access* should list the `network-monitor`
repository with *Write* role (added automatically on first publish by the
workflow; needed for later pushes).

<a id="private-package-credentials"></a>
### Private package

If the package stays private, the NAS needs credentials to pull:

1. GitHub → Settings → Developer settings → Personal access tokens →
   **Tokens (classic)** → *Generate* with only the **`read:packages`** scope.
2. Synology: **Container Manager → Registry → Settings → Add**
   - Registry name: `GHCR`, Registry URL: `https://ghcr.io`
   - Username: `pidiman`, Password: the token

   or over SSH (stores credentials for root's Docker on the NAS):

   ```bash
   sudo docker login ghcr.io -u pidiman     # paste the token at the prompt
   ```

Never put the token into this repository, the compose file or the workflow.

---

## 11. Security

- **One key per device.** The server stores only the SHA-256 hash; the
  plaintext key exists only on the device (config file or container
  environment). A leaked key can be revoked per device in the admin.
- **Never printed / logged.** Neither the installer nor the agent prints the
  key; the installer shows only `API key: <set, hidden>`. Tests assert the key
  never appears in output, curl arguments or the payload.
- **Key input (installer):** read interactively with `read -rs` from the
  terminal — never a command line argument (`install.sh` rejects arguments),
  so it never appears in shell history or `ps`.
- **Key in transit to curl:** passed via stdin (`curl --config -`), not as a
  `-H` argument, so it is not visible in the process list. When read from the
  environment, the agent unsets `NETWORK_MONITOR_API_KEY` before starting
  `curl` / `speedtest`, so child processes do not inherit it.
- **Config file at rest:** directory `700`, file `600`, owned by the agent
  user; written atomically (temp file created with `umask 077`, then `mv`).
  The agent warns if the file is group/world accessible.
- **Config is data, not code:** only `NETWORK_MONITOR_API_KEY` and
  `NETWORK_MONITOR_API_BASE_URL` are parsed line by line; the file is never
  `source`d, so `$(...)`, backticks or `;` are never executed. The key is
  validated to `[A-Za-z0-9_.-]` (also when it comes from the environment).
- **Docker:**
  - the key is **not** in the image, Dockerfile, workflow or repository — only
    runtime environment variables;
  - `.dockerignore` limits the build context to `src/network-speedtest.sh`, so
    no local `.env` / `agent.env` can ever be copied into an image;
  - runs as non-root uid `10001`, no published ports, no inbound traffic;
  - environment variables are visible to NAS administrators
    (`docker inspect`, Container Manager UI) — treat the NAS admin account and
    the project folder as sensitive.
- **CI:** the workflow uses only the automatic `GITHUB_TOKEN`
  (`contents: read`, `packages: write`); pull requests build but never push.
- **Transport:** HTTPS by default. The installer warns on plain `http://`;
  the LAN HTTP URL is a documented exception for the current network.
- **Least privilege:** root is needed only for installation; the agent runs
  as a normal user.
- **Supply chain:** Ookla CLI comes only from the official Ookla packagecloud
  apt repository with a pinned `signed-by` key — in the installer and in the
  image. No unofficial binaries.
- **Git:** `.gitignore` excludes `agent.env`, `*.env`, `.env`, `docker/.env`
  (templates `*.env.example` / `.env.example` are allowed), keys and credentials.

---

## 12. Troubleshooting

**`API authentication failed (HTTP 401)`** (exit 3) — the key is wrong or was
revoked / regenerated. Generate a new one in the admin. RPi: run
`sudo ./install.sh`, answer `n` to *Keep existing configuration?*.
Docker/Synology: update `NETWORK_MONITOR_API_KEY` in the project YAML/`.env`
and rebuild the project.

**`cannot reach API ...`** (exit 5) — check the URL (`--check`), DNS,
firewall. The URL must be the API base, e.g.
`https://notes.pidiman.sk/api/network` (no `/config` suffix). Inside the home
LAN see [LAN variant](#lan-variant-no-hairpin-nat) — without hairpin NAT the
public hostname is unreachable from LAN devices.

**`no configuration: set the NETWORK_MONITOR_API_KEY ...` /
`both ... environment variables must be set`** (exit 2) — Docker: the key
variable is empty or missing (e.g. `${NETWORK_MONITOR_API_KEY}` in the compose
file but no `.env`). RPi: `/etc/notes-network-monitor/agent.env` is missing —
run `sudo ./install.sh`.

**`config file not readable by user ...`** — you are running the agent as a
different user than the config owner. Either run it as that user, or re-run
`sudo ./install.sh` from the right user (ownership is fixed on every run).

**`Device is disabled on the server`** — `enabled=false` in the admin. Not an
error (exit 0).

**`API rejected the payload (HTTP 400)`** — the server message is shown. Check
agent version vs. server expectations; update the agent / image.

**`speedtest failed`** / timeout (exit 4) — run `speedtest` manually to see
Ookla's error (no network, Ookla servers unreachable). `speedtest -L` lists
nearby servers. In Docker:
`docker run --rm --network host --entrypoint speedtest ghcr.io/pidiman/network-monitor:latest --accept-license --accept-gdpr`.

**Docker: `denied` / `unauthorized` when pulling from ghcr.io** — the package
is private. Make it public or configure credentials
([GHCR](#10-ghcr)).

**Docker: `exec format error` / `no matching manifest`** — the host
architecture is not in the image (`amd64`, `arm64`, `arm/v7`). Check with
`uname -m` on the host.

**Synology: container stops immediately** — expected: it is a one-shot job.
Look at the log and the exit code (0 = OK).

**Synology: interface is `ovs_eth0` / `bond0` instead of `eth0`** — that is the
NAS's real interface name with `network_mode: host`; update the device in the
admin if it matters.

<a id="wrong-speedtest-python-speedtest-cli"></a>
**Wrong `speedtest` (Python speedtest-cli)** — `speedtest --version` must say
`Speedtest by Ookla`. If it says `speedtest-cli x.y` / `Python`:

```bash
dpkg -S "$(readlink -f "$(command -v speedtest)")"   # which package owns it?
sudo apt-get remove speedtest-cli                     # if it is the Debian package
pip3 uninstall speedtest-cli  /  pipx uninstall speedtest-cli   # if from pip
hash -r && sudo ./install.sh
```

**Ookla repository: `does not have a Release file`** — remove
`/etc/apt/sources.list.d/ookla_speedtest-cli.list` and re-run the installer;
it probes which suite Ookla publishes and falls back automatically.

**Ookla license prompt** — the agent always passes `--accept-license
--accept-gdpr`, so it never waits for input (also in the container).
Acceptance is stored per user in `~/.config/ookla/`.

---

## Development & tests

Everything can be checked on a laptop (e.g. macOS) without installing
anything or touching `/etc` / `/usr/local/bin`:

```bash
bash -n install.sh uninstall.sh src/network-speedtest.sh
shellcheck -x install.sh uninstall.sh src/network-speedtest.sh tests/*.sh
./tests/test-agent.sh      # offline: fake curl + fake speedtest + temp config
./tests/test-docker.sh     # needs Docker: builds the image, mock API container
```

- `tests/test-agent.sh` — payload transformation (exact match with the API
  spec), 201 / duplicate / disabled / 400 / 401 / 5xx / network error /
  invalid JSON, speedtest failure, Python speedtest-cli detection, `--check`,
  config injection attempts, CRLF config, permission warning, environment
  variable configuration and precedence, and that the API key never appears in
  output, curl arguments, the payload or the speedtest process environment.
- `tests/test-docker.sh` — builds the image for the local architecture and
  runs it on a private Docker network against `tests/fixtures/mock_api.py`
  with `tests/fixtures/fake-speedtest` mounted over the Ookla binary (no real
  speedtest): `--version`, non-root user, Ookla CLI present, no key in the
  image, one-shot GET → speedtest → POST, duplicate, disabled, 401, missing /
  empty key, `--check`, `--env-file`, key not in logs.
  Test another image/arch: `IMAGE=... SKIP_BUILD=1 ./tests/test-docker.sh`.

Build locally:

```bash
docker build -f docker/Dockerfile -t network-monitor:dev .
docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -f docker/Dockerfile .
```
