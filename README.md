# Network Monitor Agent

Client agent + installer for **Network Monitor** on Raspberry Pi / Debian
devices in a home LAN.

The agent runs the **official Ookla Speedtest CLI** and reports the result to
the Network Monitor API at **[notes.pidiman.sk](https://notes.pidiman.sk)**,
where results are stored in PostgreSQL and shown on a dashboard.

> This repository contains **only the client side** (agent + installer).
> The server application and database live in the separate `notes-by-chatgpt`
> project.

```
Ookla Speedtest CLI
        ↓
Network Monitor Agent   (/usr/local/bin/network-speedtest)
        ↓
HTTP API                (X-API-Key, JSON)
        ↓
notes.pidiman.sk
        ↓
PostgreSQL / Dashboard
```

Scheduling (systemd timer) is **not implemented yet** — the agent is run
manually for now. See [systemd/README.md](systemd/README.md).

---

## Contents

- [Repository layout](#repository-layout)
- [Supported systems](#supported-systems)
- [Prerequisites](#prerequisites)
- [API key setup](#api-key-setup)
- [Installation](#installation)
- [Configuration](#configuration)
- [Running the agent manually](#running-the-agent-manually)
- [Update](#update)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Security model](#security-model)
- [Development & tests](#development--tests)

---

## Repository layout

```
network-monitor/
├── README.md
├── install.sh                 # interactive installer / updater
├── uninstall.sh               # removes agent, optionally config
├── src/
│   └── network-speedtest.sh   # the agent (installed as /usr/local/bin/network-speedtest)
├── config/
│   └── agent.env.example      # config template (no secrets)
├── systemd/
│   └── README.md              # placeholder, scheduling comes later
└── tests/
    └── test-agent.sh          # offline agent tests with fake curl/speedtest
```

## Supported systems

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

## Prerequisites

- Debian-based system with `apt-get`, `bash`
- `sudo` rights (or a root shell)
- Internet access to `packagecloud.io` (Ookla repository) and to the API
- A **device API key** from notes.pidiman.sk (see below)

Installed automatically when missing: `curl`, `jq`, `ca-certificates`,
official **Ookla Speedtest CLI** (package `speedtest`).

> ⚠️ The Python package `speedtest-cli` (`apt install speedtest-cli` /
> `pip install speedtest-cli`) is a **different program** with a different JSON
> format and is **not supported**. The installer detects it — see
> [Troubleshooting](#wrong-speedtest-python-speedtest-cli).

## API key setup

1. Open the Network Monitor admin on **notes.pidiman.sk**.
2. Create a device (e.g. `rpi-npm`) and set interval / offset / enabled there.
3. Generate an API key for the device. It looks like `nm_xxxxxxxxxxxxxxxx`.
4. Copy it — the server stores only its SHA-256 hash, so the plaintext key
   exists only on the device afterwards.

The device name, interval and offset are **never** entered on the device —
the server identifies the device by its API key.

## Installation

On a new Raspberry Pi / Debian device:

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
✓ Installed /usr/local/bin/network-speedtest (version 0.1.0)

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

## Configuration

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

Interval / offset / enabled are managed on notes.pidiman.sk only.

## Running the agent manually

As the agent user (no sudo needed):

```bash
network-speedtest            # full run: config → speedtest → POST result
network-speedtest --check    # only verify API key/URL and show device info
network-speedtest --version
network-speedtest --help
```

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

1. Parses `/etc/notes-network-monitor/agent.env` (override path with
   `NETWORK_MONITOR_CONFIG=/path` for testing).
2. Checks `curl`, `jq` and that `speedtest` is the official Ookla CLI.
3. `GET {base}/config` → validates JSON, reads `device_key`, `enabled`.
4. `enabled=false` → prints a message and exits `0` without a speedtest.
5. Runs `speedtest --accept-license --accept-gdpr --format=json`
   (non-interactive, 300 s timeout).
6. Verifies a `"type": "result"` object, converts bandwidth bytes/s → Mbps
   (`× 8 / 1 000 000`, 2 decimals) and builds the payload.
7. `POST {base}/speedtests`, handles the HTTP status, prints the result.

HTTP handling & exit codes:

| Situation                                   | Result                  | Exit |
|---------------------------------------------|-------------------------|------|
| success (`201`), duplicate (`200` + `duplicate:true`), device disabled | OK | `0` |
| missing dependency, wrong `speedtest`       | error                   | `1`  |
| config missing / invalid                    | error                   | `2`  |
| `401` (GET or POST)                         | invalid / revoked key   | `3`  |
| speedtest failed / timed out / bad output   | error                   | `4`  |
| `400` payload rejected, `5xx`, other status, network/curl error, invalid JSON | error | `5` |

Timeouts: connect 10 s; GET 30 s; POST 60 s; speedtest 300 s.

## Update

```bash
cd ~/network-monitor
git pull
sudo ./install.sh        # answer Y to "Keep existing configuration?"
```

The installer replaces `/usr/local/bin/network-speedtest` with the version
from the checkout (it reports `old → new` version, or "already up to date"),
keeps the config and API key, and does not reinstall packages that are
already present. There is no automatic update mechanism (by design, for now).

## Uninstall

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

After removing the config, consider revoking the device key in the
notes.pidiman.sk admin as well.

## Troubleshooting

**`API authentication failed (HTTP 401)`** — the key is wrong or was revoked /
regenerated. Generate a new one in the admin and run `sudo ./install.sh`,
answer `n` to *Keep existing configuration?*.

**`cannot reach API ...`** — check the URL (`network-speedtest --check`),
DNS, firewall, `curl -I https://notes.pidiman.sk`. The URL must be the API
base, e.g. `https://notes.pidiman.sk/api/network` (no `/config` suffix).

**`config file not readable by user ...`** — you are running the agent as a
different user than the config owner. Either run it as that user, or re-run
`sudo ./install.sh` from the right user (ownership is fixed on every run).

**`Device is disabled on the server`** — `enabled=false` in the admin. Not an
error (exit 0).

**`API rejected the payload (HTTP 400)`** — the server message is shown. Check
agent version vs. server expectations; update via `git pull && sudo ./install.sh`.

**`speedtest failed`** / timeout — run `speedtest` manually to see Ookla's
error (no network, Ookla servers unreachable). To test a specific server:
`speedtest -L` lists nearby servers.

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
--accept-gdpr`, so it never waits for input. Acceptance is stored per user in
`~/.config/ookla/`.

## Security model

- **One key per device.** The server stores only the SHA-256 hash; the
  plaintext key exists only in `/etc/notes-network-monitor/agent.env` on the
  device. A leaked key can be revoked per device in the admin.
- **Key input:** read interactively with `read -rs` from the terminal — never a
  command line argument (`install.sh` rejects arguments), so it never appears
  in shell history or `ps`. It is never printed or logged; the installer shows
  only `API key: <set, hidden>`.
- **Key in transit to curl:** passed via stdin (`curl --config -`), not as a
  `-H` argument, so other local users cannot see it in the process list.
- **Config at rest:** directory `700`, file `600`, owned by the agent user;
  written atomically (temp file created with `umask 077`, then `mv`). The agent
  warns if the file is group/world accessible.
- **Config is data, not code:** the agent and the installer parse only
  `NETWORK_MONITOR_API_KEY` and `NETWORK_MONITOR_API_BASE_URL` line by line.
  The file is never `source`d, so `$(...)`, backticks or `;` in it are never
  executed. The key is also validated to `[A-Za-z0-9_.-]`.
- **Transport:** HTTPS by default. The installer warns when a plain `http://`
  URL is used (intended only for LAN testing).
- **Least privilege:** root is needed only for installation; the agent runs
  as a normal user.
- **Supply chain:** Ookla CLI comes only from the official Ookla packagecloud
  apt repository with a pinned `signed-by` key — no random binaries.
- **Git:** `.gitignore` excludes `agent.env`, `*.env` (except `*.env.example`),
  keys and credentials. Only `config/agent.env.example` (empty key) is committed.

## Development & tests

Everything can be checked on a laptop (e.g. macOS) without installing
anything or touching `/etc` / `/usr/local/bin`:

```bash
bash -n install.sh uninstall.sh src/network-speedtest.sh
./tests/test-agent.sh      # offline: fake curl + fake speedtest + temp config
```

`tests/test-agent.sh` covers: payload transformation (exact match with the API
spec), 201 / duplicate / disabled / 400 / 401 / 5xx / network error / invalid
JSON, speedtest failure, Python speedtest-cli detection, `--check`, config
injection attempts (`$(...)`, backticks), CRLF config, permission warning and
that the API key never appears in output, curl arguments or payload.
