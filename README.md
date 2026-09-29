# Network Monitor Agent

Client agent for **Network Monitor**: measures internet connectivity with the
**official Ookla Speedtest CLI** and reports results to the Network Monitor API
at **[notes.pidiman.sk](https://notes.pidiman.sk)**.

Two ways to run the same agent:

- **Raspberry Pi / Debian** — interactive installer (`install.sh`)
- **Docker** — image `ghcr.io/pidiman/network-monitor`, primarily for
  **Synology NAS + Container Manager**, usable on any Docker host

Measurements run **automatically** on a schedule managed centrally on
notes.pidiman.sk (`enabled`, `interval_minutes`, `offset_minutes`): a systemd
timer (Linux) or Synology Task Scheduler (Docker) wakes the agent every
5 minutes and it measures only in the device's slot — see
[Scheduling](#8-scheduling).

---

## Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Raspberry Pi / Debian installation](#3-raspberry-pi--debian-installation)
4. [Docker](#4-docker)
5. [Synology Container Manager](#5-synology-container-manager)
6. [Configuration](#6-configuration)
7. [Manual run](#7-manual-run)
8. [Scheduling](#8-scheduling)
9. [Updating](#9-updating)
10. [Uninstall](#10-uninstall)
11. [GHCR](#11-ghcr)
12. [Security](#12-security)
13. [Troubleshooting](#13-troubleshooting)

Appendix: [Development & tests](#development--tests)

---

## 1. Overview

One run of the agent (manual mode, `network-speedtest`):

1. loads the API key + API URL (environment variables or config file),
2. `GET {base}/config` — the server identifies the device by its API key and
   returns `device_key`, `enabled`, interval, offset,
3. `enabled=false` → exits `0` without measuring,
4. runs `speedtest --accept-license --accept-gdpr --format=json`,
5. converts the Ookla JSON into the API payload,
6. `POST {base}/speedtests`, prints the result, exits.

Scheduled mode (`network-speedtest --scheduled`) does the same, but only when
the current time is inside the device's slot and that slot was not measured
yet — see [Scheduling](#8-scheduling).

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
network-monitor.timer (every 5 min)       Synology Container Manager (env vars)
                                              ↓
                                          DSM Task Scheduler (every 5 min:
                                          docker start -a network-monitor)
```

Repository layout:

```
network-monitor/
├── README.md
├── install.sh                      # RPi/Debian interactive installer / updater
├── uninstall.sh                    # removes timer, state, agent, optionally config
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
│   ├── network-monitor.service     # oneshot: network-speedtest --scheduled
│   ├── network-monitor.timer       # wakes the service every 5 minutes
│   └── README.md
└── tests/
    ├── test-agent.sh               # offline agent tests (fake curl/speedtest)
    ├── test-scheduler.sh           # offline slot/tolerance/state/lock tests
    ├── test-docker.sh              # image tests against a mock API container
    └── fixtures/
        ├── fake-curl               # fake API client for offline tests
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
✓ Installed /usr/local/bin/network-speedtest (version 0.3.0)

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
Next slot: 2026-09-30 14:05 CEST

Scheduling (systemd timer)...
✓ State directory: /var/lib/notes-network-monitor (owner pi, mode 700)
✓ Installed/updated network-monitor.service and network-monitor.timer (runs as pi)
Enable automatic speedtests (schedule managed on notes.pidiman.sk)? [Y/n]:
✓ Timer enabled

Installation complete.
...
Scheduler status
Timer: enabled, active
NEXT                        LEFT     LAST PASSED UNIT                  ACTIVATES
Wed 2026-09-30 14:05:00 CEST 4min 31s -   -      network-monitor.timer network-monitor.service
...
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
9. Scheduling: creates `/var/lib/notes-network-monitor` (agent user, `700`),
   installs/updates `network-monitor.service` + `network-monitor.timer`
   (only if systemd is running), asks to enable the timer on the first run and
   keeps it enabled on later runs; prints the scheduler status.
10. Optionally runs the first real speedtest.

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
docker run --rm IMAGE                     docker run --rm IMAGE --scheduled
      ↓                                         ↓
GET config → speedtest → POST result      GET config → in slot & not measured?
      ↓                                     yes: speedtest → POST · no: log line
exit (container stops)                    exit (container stops)
```

The container's exit code is the agent's exit code (see [Manual run](#7-manual-run)).
`enabled=false` → exit `0` without a speedtest. There is no loop, daemon or
healthcheck inside the image. Periodic runs come from outside
(Synology Task Scheduler) — see [Scheduling](#8-scheduling). `--scheduled`
keeps its slot state in `/var/lib/notes-network-monitor`; mount a volume
there so it survives container re-creation.

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
    command: ["--scheduled"]          # remove for a manual speedtest on every start
    network_mode: host
    environment:
      NETWORK_MONITOR_API_KEY: "${NETWORK_MONITOR_API_KEY}"
      NETWORK_MONITOR_API_BASE_URL: "${NETWORK_MONITOR_API_BASE_URL:-https://notes.pidiman.sk/api/network}"
    volumes:
      - state:/var/lib/notes-network-monitor
    restart: "no"

volumes:
  state:
```

```bash
cd docker
cp .env.example .env && chmod 600 .env   # fill in the key; .env is git-ignored
docker compose -f docker-compose.example.yml up       # one scheduled check, then exits
docker start -a network-monitor                       # next check (e.g. from cron every 5 min)
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

The GHCR package should be **public** (see [GHCR](#11-ghcr)). If it is
private, set up credentials first ([private package](#private-package-credentials)).

### Step 3 — create the project

1. **File Station**: create a folder, e.g. `docker/network-monitor`
   (on the `docker` shared folder).
2. **Container Manager → Project → Create**
   - **Project name:** `network-monitor`
   - **Path:** `/docker/network-monitor`
   - **Source:** *Create docker-compose.yml*
3. Paste the YAML and fill in the two values (this is the scheduled variant;
   for a first manual test you may temporarily remove the `command` line):

   ```yaml
   services:
     network-monitor:
       image: ghcr.io/pidiman/network-monitor:latest
       container_name: network-monitor
       command: ["--scheduled"]
       network_mode: host
       environment:
         NETWORK_MONITOR_API_KEY: "nm_PASTE_YOUR_DEVICE_KEY_HERE"
         NETWORK_MONITOR_API_BASE_URL: "http://192.168.1.27:3077/api/network"
       volumes:
         - state:/var/lib/notes-network-monitor
       restart: "no"

   volumes:
     state:
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

**Another run:** Container → `network-monitor` → **Start** (runs once again,
then stops). **Automatic runs:** create the DSM Task Scheduler task described
in [Scheduling → Synology](#synology--container-manager--task-scheduler).

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
with `docker run`. No config file is needed. For `--scheduled`, mount a volume
at `/var/lib/notes-network-monitor` (slot state, no secrets).

### State (scheduling)

| Path                                        | Content                          | Mode |
|---------------------------------------------|----------------------------------|------|
| `/var/lib/notes-network-monitor/last_slot`  | last measured slot (no secrets)  | `600` |
| `/var/lib/notes-network-monitor/agent.lock` | `flock` lock file                | `600` |

Override for tests: `NETWORK_MONITOR_STATE_DIR=/path`.

---

## 7. Manual run

Raspberry Pi / Debian, as the agent user (no sudo needed):

```bash
network-speedtest              # manual run now: config → speedtest → POST result
network-speedtest --scheduled  # measure only if inside the device's slot (used by the timer)
network-speedtest --check      # only verify API key/URL, show device info + next slot
network-speedtest --version
network-speedtest --help
```

A manual run ignores interval/offset, but still respects `enabled=false`
and does not run in parallel with a scheduled run.

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
| invalid schedule from the server (`--scheduled`) | error, no speedtest | `6` |
| another run in progress (manual run; `--scheduled` exits `0`) | error | `7` |

`--scheduled` also exits `0` when not in a slot, the slot was already
measured, or the device is disabled.

Timeouts: connect 10 s; GET 30 s; POST 60 s; speedtest 300 s.

---

## 8. Scheduling

Automatic measurements are planned **centrally** on notes.pidiman.sk: every
device has `enabled`, `interval_minutes` and `offset_minutes`. Nothing about
the schedule is configured on the device.

```
every 5 minutes: systemd timer (Linux)  /  Synology Task Scheduler (Docker)
        ↓
network-speedtest --scheduled          (short-lived process, < 1 s when idle)
        ↓
GET /config → enabled? valid schedule? inside a slot? slot not measured yet?
        ↓ all yes                                  ↓ otherwise
Ookla speedtest → POST result → exit        one log line → exit 0
```

No daemon, no loop, no process between wake-ups. The same agent logic is used
on Linux and in Docker; only the thing that wakes it up differs.

| Mode                            | interval/offset | enabled=false | slot state |
|---------------------------------|-----------------|---------------|------------|
| `network-speedtest`             | ignored — measures now | no test (exit 0) | not touched |
| `network-speedtest --scheduled` | respected       | no test (exit 0) | read + written |
| `network-speedtest --check`     | shows next slot | shown         | not touched |

### Slots: interval + offset

- `M` = minutes since the Unix epoch (`floor(unix_time / 60)`, UTC based).
- A **slot** starts at every minute `M` where
  **`(M − offset_minutes) mod interval_minutes == 0`**.
- Slots are fixed wall-clock times — they do **not** drift with the speedtest
  duration, reboots or late wake-ups ("every 60 minutes after the last test"
  is *not* the semantics).

| interval | offset | slots                                                         |
|----------|--------|---------------------------------------------------------------|
| 60       | 0      | XX:00 every hour (rpi4-webserver)                             |
| 60       | 5      | XX:05 every hour (npm-new)                                    |
| 60       | 10     | XX:10 every hour (ds220)                                      |
| 30       | 5      | XX:05 and XX:35                                               |
| 120      | 0      | even **UTC** hours (00:00, 02:00 … UTC = 02:00, 04:00 … CEST) |
| 1440     | 0      | once a day at 00:00 **UTC**                                   |

Intervals that divide 60 behave identically in local time (Slovakia has
whole-hour UTC offsets). Longer intervals are anchored to UTC, so they never
jump on DST changes, but their local time shifts by one hour between summer
and winter.

**Validity.** `interval_minutes` must be an integer ≥ 1 and
`0 ≤ offset_minutes < interval_minutes` (integer).
An invalid combination (e.g. interval 60 / offset 90) is **not normalised**:
`--scheduled` exits with code `6` and a clear error, and **no speedtest runs**
(the systemd service shows as *failed*, Synology Task Scheduler reports an
abnormal end); `--check` prints `Schedule: INVALID — …`. The admin value is
never silently reinterpreted — fix it on notes.pidiman.sk. Manual runs ignore
interval/offset and still work.

**Practical granularity.** The agent is woken every 5 minutes
(:00, :05, :10 … local time), so:

- use offsets that are multiples of 5 (0, 5, 10, …) — they run on time;
- other offsets run at the next wake-up (offset 7 → runs at XX:10);
- the effective minimum interval is 5 minutes.

### Tolerance (late start)

A slot may start **at most 10 minutes late** (window = `min(10, interval)`
minutes after the slot start). Later it is skipped — missed slots are **never
caught up**.

Example `interval 60 / offset 5`:

| Wake-up time             | Result                                         |
|--------------------------|------------------------------------------------|
| 13:05                    | measures (slot 13:05)                          |
| 13:06 (reboot at 13:04)  | measures (1 min late)                          |
| 13:14                    | measures if 13:05 not measured yet             |
| 13:15 or later           | nothing — next slot 14:05                      |
| boot at 13:45            | nothing — 13:05 is not caught up; next 14:05   |

10 minutes = two wake-up periods, so one lost wake-up (reboot, busy system)
does not lose the slot, but a measurement never runs "half an hour late".

### At most one speedtest per slot; no parallel runs

- **Slot state**: after a successful speedtest the slot is recorded in
  `last_slot` (Linux: `/var/lib/notes-network-monitor/`, Docker: the state
  volume). `--scheduled` measures only if the current slot is newer. So a timer
  firing twice, a reboot inside the slot, or an offset change to an already
  covered time never produce a second test. The server's `result_id`
  deduplication alone could not prevent this (a new test has a new `result_id`).
- The slot is recorded **as soon as the speedtest produced a result**, before
  the POST:
  - speedtest failed (no result) → not recorded → retried at the next wake-up
    if still inside the 10-minute window (max. 2 attempts);
  - POST failed → recorded → no second speedtest in that slot (the error is
    logged; that measurement is lost).
- **Lock**: every speedtest (manual or scheduled) takes an exclusive `flock`
  on `agent.lock`. A second instance does not wait: `--scheduled` skips
  (exit 0), a manual run exits with code `7` ("already in progress").
  Additionally systemd never starts a running oneshot service twice, and
  `docker start` on a running container does nothing.
- A manual run does not record a slot — a manual test at 13:03 does not
  cancel the scheduled 13:05 test.
- State contains only the slot number, its time and the `device_key` —
  never the API key. Directory mode `700`.

### `enabled` and changes made on the web

Every wake-up fetches `GET /config` (one small request every 5 minutes per
device; no speedtest unless a slot is due). Therefore:

| Change on notes.pidiman.sk      | Takes effect                                          |
|---------------------------------|-------------------------------------------------------|
| enabled → disabled              | from the next wake-up (≤ 5 min); a running test finishes |
| disabled → enabled              | detected at the next wake-up (≤ 5 min), measures at the next slot — no SSH needed |
| interval / offset changed       | next wake-up (≤ 5 min); the next measurement follows the new slots |

**Maximum delay** until a change is seen: **5 minutes**. The first measurement
with new settings happens at the next new slot (if that slot started less than
10 minutes before the wake-up, it runs right away).

### Linux / Raspberry Pi — systemd timer

`sudo ./install.sh` installs (and on re-runs updates) the timer — see
[systemd/](systemd/):

| Unit                        | Role                                                          |
|-----------------------------|---------------------------------------------------------------|
| `network-monitor.timer`     | `OnCalendar=*:0/5`, `Persistent=true` — wakes every 5 minutes; after downtime fires once at boot |
| `network-monitor.service`   | `Type=oneshot`, `User=<agent user>`, `ExecStart=network-speedtest --scheduled`, `StateDirectory=notes-network-monitor`, hardened (`ProtectSystem=strict`, `NoNewPrivileges`, …) |

The installer asks *Enable automatic speedtests? [Y/n]* on the first run,
keeps the timer enabled on later runs, and prints the scheduler status at the
end.

```bash
systemctl status network-monitor.timer              # enabled / active, next trigger
systemctl list-timers | grep network-monitor         # NEXT / LAST run
journalctl -u network-monitor.service                # all runs
journalctl -u network-monitor.service --since today -o cat
journalctl -u network-monitor.service -f             # follow live
network-speedtest --check                            # device, schedule, next slot

sudo systemctl start network-monitor.service         # one scheduled check now (measures only in a slot)
network-speedtest                                    # forced manual speedtest now
```

Typical journal:

```
[rpi4-webserver] not in a slot; next: 2026-09-30 14:00 CEST (interval 60 min, offset 0 min). Nothing to do.
Network Monitor
Device: rpi4-webserver
Slot:   2026-09-30 14:00 CEST (interval 60 min, offset 0 min, started 0 min ago)
...
Result stored successfully.
```

**Enable / disable.** Preferred: toggle *Enabled* on notes.pidiman.sk
(central, no SSH). Locally, if the device should stop checking at all:

```bash
sudo systemctl disable --now network-monitor.timer   # stop scheduling on this device
sudo systemctl enable --now network-monitor.timer    # resume
```

**Update.** `git pull && sudo ./install.sh` re-renders the units, runs
`daemon-reload`, keeps the timer enabled and keeps `agent.env`.

### Synology — Container Manager + Task Scheduler

Options considered:

| Option | Verdict |
|--------|---------|
| **DSM Task Scheduler runs `docker start -a network-monitor` every 5 min** (existing Compose container with `--scheduled`) | **chosen** — native DSM, no extra container, no permanent process, image stays one-shot, the key stays in the Compose project, `docker start` is naturally single-instance, exit code → Task Scheduler notifications |
| Scheduler container (ofelia, cron image) | extra permanent process + needs the Docker socket (root-equivalent) |
| Loop / cron inside the image | permanent process, breaks the one-shot design |
| Task Scheduler runs `docker run --rm …` | key must be in the task command or a separate env file; new container each run |

**1. Change the project** (Container Manager → Project → `network-monitor` →
Action → **Stop**; *YAML configurations* → **Edit**). Add `command` and the
state volume:

```yaml
services:
  network-monitor:
    image: ghcr.io/pidiman/network-monitor:latest
    container_name: network-monitor
    command: ["--scheduled"]
    network_mode: host
    environment:
      NETWORK_MONITOR_API_KEY: "nm_PASTE_YOUR_DEVICE_KEY_HERE"
      NETWORK_MONITOR_API_BASE_URL: "http://192.168.1.27:3077/api/network"
    volumes:
      - state:/var/lib/notes-network-monitor
    restart: "no"

volumes:
  state:
```

Save, then Action → **Build** (pulls the image if needed and recreates the
container; it runs one check and stops).

**2. Create the task** — **Control Panel → Task Scheduler → Create →
Scheduled Task → User-defined script**:

| Tab           | Setting                                                         |
|---------------|-----------------------------------------------------------------|
| General       | Task: `Network Monitor` · User: **root** · Enabled ✓            |
| Schedule      | Run on the following days: **Daily** · First run time: **00:00** · Frequency: **Every 5 minutes** · Last run time: **23:55** |
| Task Settings | User-defined script: `/usr/local/bin/docker start -a network-monitor` · optional: *Send run details by email* → *only when the script terminates abnormally* |

`docker start -a` starts the **existing** container, waits for it and returns
its exit code: `0` for a measurement, "not in a slot", disabled or "already
measured"; non-zero only for real problems (401, invalid schedule, API
unreachable). If the container is still running, it does not start a second
run.

**3. Test it:** Task Scheduler → select *Network Monitor* → **Run**, then
Container Manager → Container → `network-monitor` → **Log**:

```
[ds220] not in a slot; next: 2026-09-30 14:10 UTC (interval 60 min, offset 10 min). Nothing to do.
```

At the next XX:10 the log shows a full measurement. Times in the container
log are **UTC** (the image has no time zone data).

**Manual measurement on Synology** (ignores the schedule) over SSH:

```bash
read -rs NETWORK_MONITOR_API_KEY && export NETWORK_MONITOR_API_KEY
sudo --preserve-env=NETWORK_MONITOR_API_KEY docker run --rm --network host \
  -e NETWORK_MONITOR_API_KEY \
  -e NETWORK_MONITOR_API_BASE_URL=http://192.168.1.27:3077/api/network \
  ghcr.io/pidiman/network-monitor:latest
```

Useful checks (SSH):

```bash
sudo docker logs --tail 20 network-monitor
sudo docker inspect -f '{{.State.ExitCode}} {{.State.FinishedAt}}' network-monitor
sudo docker run --rm -v network-monitor_state:/s debian:trixie-slim cat /s/last_slot
```

(The volume name is `<project name>_state`.)

---

## 9. Updating

### Raspberry Pi / Debian

```bash
cd ~/network-monitor
git pull
sudo ./install.sh        # answer Y to "Keep existing configuration?"
```

The installer replaces `/usr/local/bin/network-speedtest` with the version
from the checkout (it reports `old → new` version, or "already up to date"),
keeps the config and API key, and does not reinstall packages that are
already present. It also installs/updates the systemd timer and service
(timer stays enabled). There is no automatic update mechanism (by design, for now).

After updating:

```bash
network-speedtest --version                  # 0.3.0 or newer
systemctl list-timers | grep network-monitor
```

### Docker image

Every push to `main` publishes a new `:latest`. To release a version:

```bash
git tag v1.0.0
git push origin v1.0.0     # → :1.0.0, :1.0, :v1.0.0
```

To pin a version on a host, use e.g. `ghcr.io/pidiman/network-monitor:1.0.0`
instead of `:latest`.

**Synology:** Container Manager → **Image** → `ghcr.io/pidiman/network-monitor`
→ *Update* (shown when a newer `latest` exists).
Alternatively over SSH: `sudo docker pull ghcr.io/pidiman/network-monitor:latest`,
then Container Manager → Project → `network-monitor` → Action → **Build**
(recreates the container with the new image). The Task Scheduler task keeps
working (it starts the container by name); slot state survives in the volume.

**Other hosts:** `docker compose pull && docker compose up` or
`docker pull ghcr.io/pidiman/network-monitor:latest`.

---

## 10. Uninstall

### Raspberry Pi / Debian

```bash
cd ~/network-monitor
sudo ./uninstall.sh
```

- stops, disables and removes `network-monitor.timer` / `.service`
- removes the state directory `/var/lib/notes-network-monitor` (no secrets)
- always removes `/usr/local/bin/network-speedtest`
- asks `Remove configuration and API key? [y/N]` (default **No**)
  - No → `/etc/notes-network-monitor/agent.env` is kept (re-install later without a new key)
  - Yes → the whole `/etc/notes-network-monitor` directory is removed
- does **not** remove the Ookla CLI, curl, jq or the Ookla apt repository
  (other software may use them). Remove manually if wanted:
  `sudo apt-get remove speedtest && sudo rm /etc/apt/sources.list.d/ookla_speedtest-cli.list /etc/apt/keyrings/ookla_speedtest-cli-archive-keyring.asc`

### Docker / Synology

Control Panel → Task Scheduler → delete the *Network Monitor* task.
Container Manager → Project → `network-monitor` → Action → **Stop**, then
**Delete** (removes the project/container; delete the `…_state` volume under
Container Manager → Volume if wanted); Image → delete
`ghcr.io/pidiman/network-monitor`; delete the project folder (it contains the
key if you put it into the YAML or `.env`).
Other hosts: `docker compose down && docker image rm ghcr.io/pidiman/network-monitor:latest`.

After removing a device, revoke its API key in the notes.pidiman.sk admin as well.

---

## 11. GHCR

### How `ghcr.io/pidiman/network-monitor:latest` is created

[.github/workflows/docker-publish.yml](.github/workflows/docker-publish.yml):

1. Trigger: push to `main`, push of a tag `v*`, pull request (build only),
   or manual *Run workflow*.
2. Job **test**: `bash -n`, `shellcheck`, `systemd-analyze verify` of the
   units, `tests/test-agent.sh`, `tests/test-scheduler.sh`,
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

## 12. Security

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
  as a normal user — also from systemd (`User=`, `NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`; writable is only the
  state directory).
- **State** (`/var/lib/notes-network-monitor`, mode `700`, files `600`)
  holds only the last slot number and a lock file — never the API key.
- **Synology Task Scheduler** runs `docker start` as root (required for the
  Docker CLI on DSM); the container itself still runs as uid `10001`.
- **Supply chain:** Ookla CLI comes only from the official Ookla packagecloud
  apt repository with a pinned `signed-by` key — in the installer and in the
  image. No unofficial binaries.
- **Git:** `.gitignore` excludes `agent.env`, `*.env`, `.env`, `docker/.env`
  (templates `*.env.example` / `.env.example` are allowed), keys and credentials.

---

## 13. Troubleshooting

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
([GHCR](#11-ghcr)).

**Docker: `exec format error` / `no matching manifest`** — the host
architecture is not in the image (`amd64`, `arm64`, `arm/v7`). Check with
`uname -m` on the host.

**Synology: container stops immediately** — expected: it is a one-shot job.
Look at the log and the exit code (0 = OK).

**Scheduled runs never measure** — check `network-speedtest --check`
(`Enabled: true`? `Next slot`?), then the log/journal lines:
`not in a slot; next: …` (waiting for the slot — expected),
`disabled on the server` (enable it on the web),
`already measured` (slot done). Is the timer running?
`systemctl list-timers | grep network-monitor` / Synology task enabled?

**`invalid schedule from the server`** (exit 6) — `offset_minutes` must be
smaller than `interval_minutes` (both integers, interval ≥ 1). Fix the device
on notes.pidiman.sk; the next wake-up picks it up.

**`another network-speedtest run is in progress`** (exit 7) — a scheduled or
manual speedtest is running right now; try again in a minute.

**`state directory … is not writable`** (exit 2, `--scheduled`) — RPi: re-run
`sudo ./install.sh` (fixes ownership). Docker: the volume must be writable by
uid `10001` (a new named volume is initialised correctly from the image).

**Measurements at unexpected local times** — slots are computed from UTC
(epoch minutes). Intervals dividing 60 match local time; e.g. interval 120 /
1440 are anchored to UTC — see [Slots](#slots-interval--offset).

**RPi without RTC after a power cut** — until NTP synchronises the clock, the
time can be wrong; a slot may then be skipped. It self-corrects at the next
wake-up after time sync.

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
./tests/test-scheduler.sh  # offline: slots, tolerance, state, lock (fixed clock)
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
  Also `--scheduled`: in/out of slot, disabled, state volume across
  containers, Synology-style `docker start` of one container, two containers
  on one state volume (`flock`).
  Test another image/arch: `IMAGE=... SKIP_BUILD=1 ./tests/test-docker.sh`.
- `tests/test-scheduler.sh` — clock fixed via `NETWORK_MONITOR_TEST_NOW`:
  slots for 60/0, 60/5, 120/0, 5/2, 1440/0; outside the slot; disabled;
  invalid schedules (offset ≥ interval, negative, non-integer, null); tolerance
  edges (9:59 vs 10:00 late); reboot/missed slot; no catch-up; same slot twice;
  offset change; concurrent scheduled + manual runs; stale lock; failed
  speedtest retry vs. failed POST; unwritable state; manual run and `--check`
  unchanged; env (Docker) and `agent.env` (Linux) config; no key in state.

Build locally:

```bash
docker build -f docker/Dockerfile -t network-monitor:dev .
docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -f docker/Dockerfile .
```
