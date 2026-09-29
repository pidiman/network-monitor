#!/usr/bin/env bash
#
# Network Monitor Agent — interactive installer / updater
#
# Usage (from a checkout of this repository):
#   sudo ./install.sh
#
# Safe to run repeatedly: existing configuration is kept (after asking),
# already installed dependencies are not reinstalled, and the agent script
# is updated to the version in this checkout.
#
# The API key is only ever read interactively (hidden input). It is never
# accepted as a command line argument and never printed.
#
set -euo pipefail

readonly DEFAULT_API_URL="https://notes.pidiman.sk/api/network"
readonly CONFIG_DIR="/etc/notes-network-monitor"
readonly CONFIG_FILE="$CONFIG_DIR/agent.env"
readonly AGENT_TARGET="/usr/local/bin/network-speedtest"
readonly STATE_DIR="/var/lib/notes-network-monitor"
readonly SYSTEMD_UNIT_DIR="/etc/systemd/system"
readonly SERVICE_NAME="network-monitor.service"
readonly TIMER_NAME="network-monitor.timer"

readonly OOKLA_REPO_BASE="https://packagecloud.io/ookla/speedtest-cli/debian"
readonly OOKLA_GPG_URL="https://packagecloud.io/ookla/speedtest-cli/gpgkey"
readonly OOKLA_KEYRING="/etc/apt/keyrings/ookla_speedtest-cli-archive-keyring.asc"
readonly OOKLA_SOURCES="/etc/apt/sources.list.d/ookla_speedtest-cli.list"
# Tried in order when the system codename is not published by Ookla.
# The Ookla CLI is a static binary, so an older suite works fine.
readonly OOKLA_FALLBACK_SUITES="bookworm bullseye buster"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly AGENT_SOURCE="$SCRIPT_DIR/src/network-speedtest.sh"
readonly SYSTEMD_SOURCE_DIR="$SCRIPT_DIR/systemd"

AGENT_USER=""
AGENT_GROUP=""
API_URL=""
API_KEY=""
APT_UPDATED=0

# ----------------------------------------------------------------------------
# output helpers
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

say()     { printf '%s\n' "$*"; }
ok()      { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail()    { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
die()     { fail "$*"; exit 1; }
section() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Prompts always read from the terminal, never from a pipe.
ask() {
    # ask VAR "Prompt" [default]
    local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
    IFS= read -r -p "$__prompt" __reply </dev/tty || true
    [[ -n "$__reply" ]] || __reply="$__default"
    printf -v "$__var" '%s' "$__reply"
}

confirm() {
    # confirm "Question" Y|N  -> returns 0 for yes
    local prompt="$1" default="$2" reply=""
    local hint="[y/N]"
    [[ "$default" == "Y" ]] && hint="[Y/n]"
    IFS= read -r -p "$prompt $hint: " reply </dev/tty || true
    reply="$(printf '%s' "${reply:-$default}" | tr '[:upper:]' '[:lower:]')"
    [[ "$reply" == "y" || "$reply" == "yes" ]]
}

usage() {
    cat <<EOF
Usage: sudo ./install.sh

Interactive installer for the Network Monitor Agent.
Installs dependencies (curl, jq, official Ookla Speedtest CLI), the agent
($AGENT_TARGET), its configuration ($CONFIG_FILE)
and the systemd timer for scheduled speedtests ($TIMER_NAME).

The API key is requested interactively with hidden input. It cannot be
passed as an argument.
EOF
}

# ----------------------------------------------------------------------------
# preflight
# ----------------------------------------------------------------------------

ensure_root() {
    if [[ $EUID -eq 0 ]]; then
        return
    fi
    command -v sudo >/dev/null 2>&1 \
        || die "This installer needs root privileges. Run it as root or install sudo."
    say "Root privileges are required; re-running with sudo..."
    exec sudo -- bash "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@"
}

ensure_tty() {
    if ! { : </dev/tty; } 2>/dev/null; then
        die "No terminal available. This installer is interactive; run it from a terminal session."
    fi
}

check_os() {
    [[ -r /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing). Debian / Raspberry Pi OS required."

    local id="" id_like="" pretty="" codename=""
    # Parse (not source) os-release; only a few fields are needed.
    id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
    id_like="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')"
    pretty="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"
    codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')"

    local is_rpi=0
    if [[ -e /etc/rpi-issue ]] || grep -qs 'Raspberry Pi' /proc/device-tree/model 2>/dev/null; then
        is_rpi=1
    fi

    case "$id" in
        debian|raspbian) ;;
        *)
            if [[ " $id_like " == *" debian "* ]]; then
                warn "Detected Debian derivative '$id'. Not officially supported, continuing anyway."
            else
                die "Unsupported OS: ${pretty:-$id}. Debian / Raspberry Pi OS required."
            fi
            ;;
    esac

    command -v apt-get >/dev/null 2>&1 || die "apt-get not found."
    command -v dpkg    >/dev/null 2>&1 || die "dpkg not found."

    OS_CODENAME="$codename"
    if [[ $is_rpi -eq 1 ]]; then
        say "Detected OS: ${pretty:-$id} (Raspberry Pi)"
    else
        say "Detected OS: ${pretty:-$id}"
    fi
}

check_arch() {
    local machine dpkg_arch
    machine="$(uname -m)"
    dpkg_arch="$(dpkg --print-architecture)"
    say "Architecture: $machine (dpkg: $dpkg_arch)"

    # Package architecture is what matters (64-bit kernel + 32-bit userland
    # on Raspberry Pi OS reports aarch64 but installs armhf packages).
    case "$dpkg_arch" in
        arm64|amd64|i386) ;;
        armhf)
            if [[ "$machine" == armv6* ]]; then
                warn "ARMv6 (Pi Zero / Pi 1) detected. The Ookla armhf build may not run on ARMv6."
            fi
            ;;
        armel)
            warn "armel architecture: Ookla CLI availability is limited, installation may fail."
            ;;
        *)
            die "Unsupported architecture: $dpkg_arch. Supported: arm64, armhf, amd64."
            ;;
    esac
}

resolve_agent_user() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        AGENT_USER="$SUDO_USER"
    else
        # Run directly as root: default to the owner of an existing config.
        local reply default="root"
        if [[ -f "$CONFIG_FILE" ]]; then
            default="$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null || echo root)"
        fi
        ask reply "User that will run the agent [$default]: " "$default"
        AGENT_USER="$reply"
    fi
    id -u "$AGENT_USER" >/dev/null 2>&1 || die "User '$AGENT_USER' does not exist."
    AGENT_GROUP="$(id -gn "$AGENT_USER")"
    say "Agent user: $AGENT_USER"
}

# ----------------------------------------------------------------------------
# dependencies
# ----------------------------------------------------------------------------

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

apt_update_once() {
    if [[ $APT_UPDATED -eq 0 ]]; then
        say "Updating package lists (apt-get update)..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null
        APT_UPDATED=1
    fi
}

apt_install() {
    apt_update_once
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" </dev/null
}

install_dependencies() {
    section "Installing dependencies..."
    local missing=() pkg
    for pkg in curl jq ca-certificates; do
        if pkg_installed "$pkg"; then
            ok "$pkg already installed"
        else
            missing+=("$pkg")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        say "Installing: ${missing[*]}"
        apt_install "${missing[@]}"
        ok "Installed: ${missing[*]}"
    fi
}

# Prints: ookla | python | unknown | missing
speedtest_kind() {
    local bin version
    bin="$(command -v speedtest 2>/dev/null || true)"
    if [[ -z "$bin" ]]; then
        echo missing
        return
    fi
    version="$(timeout 15 "$bin" --version 2>&1 </dev/null | head -n 3 || true)"
    if [[ "$version" == *"Speedtest by Ookla"* ]]; then
        echo ookla
    elif [[ "$version" == *"speedtest-cli"* || "$version" == *"Python"* ]] \
        || head -c 200 "$(readlink -f "$bin")" 2>/dev/null | grep -q 'python'; then
        echo python
    else
        echo unknown
    fi
}

handle_python_speedtest() {
    local bin real owner
    bin="$(command -v speedtest)"
    real="$(readlink -f "$bin")"
    owner="$(dpkg-query -S "$real" 2>/dev/null | cut -d: -f1 || true)"
    [[ -n "$owner" ]] || owner="$(dpkg-query -S "$bin" 2>/dev/null | cut -d: -f1 || true)"

    fail "Found the Python 'speedtest-cli' at $bin — it is NOT the official Ookla CLI."
    say  "  The agent requires the official Ookla Speedtest CLI (JSON format differs)."

    if [[ "$owner" == "speedtest-cli" ]]; then
        say "  It belongs to the Debian package 'speedtest-cli'."
        if confirm "Remove package 'speedtest-cli' (apt-get remove speedtest-cli)?" N; then
            DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq speedtest-cli </dev/null
            hash -r
            ok "Removed package speedtest-cli"
            return 0
        fi
        die "Cannot continue while the Python speedtest-cli is installed. Remove it with: sudo apt-get remove speedtest-cli"
    fi

    if [[ -n "$owner" ]]; then
        die "It belongs to the package '$owner'. Remove it manually if appropriate, then re-run the installer."
    fi

    say "  It is not managed by apt (probably installed via pip/pipx), so it will not be removed automatically."
    say "  Remove it manually, e.g.:  sudo pip3 uninstall speedtest-cli   or   pipx uninstall speedtest-cli"
    die "Remove '$bin' and re-run the installer."
}

ookla_repo_configured() {
    grep -rqs 'packagecloud.io/ookla/speedtest-cli' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
}

ookla_suite_available() {
    curl -fsS -o /dev/null --connect-timeout 10 --max-time 30 \
        "$OOKLA_REPO_BASE/dists/$1/Release" 2>/dev/null
}

setup_ookla_repo() {
    if ookla_repo_configured; then
        ok "Ookla apt repository already configured"
        return
    fi

    say "Adding official Ookla apt repository (packagecloud.io/ookla/speedtest-cli)..."

    local suite="" candidate
    for candidate in $OS_CODENAME $OOKLA_FALLBACK_SUITES; do
        [[ -n "$candidate" ]] || continue
        if ookla_suite_available "$candidate"; then
            suite="$candidate"
            break
        fi
    done
    [[ -n "$suite" ]] || die "Could not find a usable Ookla repository suite (tried: $OS_CODENAME $OOKLA_FALLBACK_SUITES)."
    if [[ "$suite" != "$OS_CODENAME" ]]; then
        warn "Ookla does not publish '$OS_CODENAME'; using the '$suite' suite (static binary, compatible)."
    fi

    local tmp_key
    tmp_key="$(mktemp)"
    curl -fsSL --connect-timeout 10 --max-time 60 "$OOKLA_GPG_URL" -o "$tmp_key" \
        || { rm -f "$tmp_key"; die "Failed to download the Ookla repository key."; }
    if ! grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$tmp_key"; then
        rm -f "$tmp_key"
        die "Downloaded Ookla repository key is not a PGP public key."
    fi
    install -d -m 0755 /etc/apt/keyrings
    install -m 0644 -o root -g root "$tmp_key" "$OOKLA_KEYRING"
    rm -f "$tmp_key"

    printf 'deb [signed-by=%s] %s/ %s main\n' "$OOKLA_KEYRING" "$OOKLA_REPO_BASE" "$suite" >"$OOKLA_SOURCES"
    chmod 0644 "$OOKLA_SOURCES"
    APT_UPDATED=0
    ok "Repository added: $OOKLA_SOURCES"
}

install_ookla() {
    section "Checking Ookla Speedtest..."
    local kind
    kind="$(speedtest_kind)"

    case "$kind" in
        ookla)
            ok "Official Ookla Speedtest CLI already installed: $(speedtest --version 2>/dev/null | head -n 1)"
            return
            ;;
        python)
            handle_python_speedtest
            kind="$(speedtest_kind)"
            [[ "$kind" == "ookla" ]] && { ok "Official Ookla Speedtest CLI found"; return; }
            ;;
        unknown)
            die "'$(command -v speedtest)' exists but is not recognised as the Ookla CLI. Not touching it; please investigate manually."
            ;;
        missing) ;;
    esac

    setup_ookla_repo
    say "Installing package 'speedtest'..."
    apt_install speedtest
    hash -r

    [[ "$(speedtest_kind)" == "ookla" ]] \
        || die "Ookla Speedtest CLI installation could not be verified. Check '$(command -v speedtest || echo speedtest)'."
    ok "Installed: $(speedtest --version 2>/dev/null | head -n 1)"
}

# ----------------------------------------------------------------------------
# agent
# ----------------------------------------------------------------------------

agent_version_of() {
    sed -n 's/^readonly AGENT_VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n 1
}

install_agent() {
    section "Installing agent..."
    [[ -f "$AGENT_SOURCE" ]] || die "Agent source not found: $AGENT_SOURCE"
    bash -n "$AGENT_SOURCE" || die "Agent source has syntax errors: $AGENT_SOURCE"

    local new_version old_version
    new_version="$(agent_version_of "$AGENT_SOURCE")"

    if [[ -f "$AGENT_TARGET" ]]; then
        if cmp -s "$AGENT_SOURCE" "$AGENT_TARGET"; then
            ok "Agent already up to date ($AGENT_TARGET, version ${new_version:-?})"
            return
        fi
        old_version="$(agent_version_of "$AGENT_TARGET")"
        say "Updating agent ${old_version:-?} -> ${new_version:-?}"
    fi

    install -d -m 0755 "$(dirname "$AGENT_TARGET")"
    install -m 0755 -o root -g root "$AGENT_SOURCE" "$AGENT_TARGET"
    ok "Installed $AGENT_TARGET (version ${new_version:-?})"
}

# ----------------------------------------------------------------------------
# configuration
# ----------------------------------------------------------------------------

strip_quotes() {
    local v="$1"
    if [[ ${#v} -ge 2 && ( "$v" == \"*\" || "$v" == \'*\' ) ]]; then
        v="${v:1:${#v}-2}"
    fi
    printf '%s' "$v"
}

# Safe parser: reads only the two known keys, never executes the file.
read_existing_config() {
    local line
    API_KEY=""; API_URL=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        case "$line" in
            NETWORK_MONITOR_API_KEY=*)      API_KEY="$(strip_quotes "${line#*=}")" ;;
            NETWORK_MONITOR_API_BASE_URL=*) API_URL="$(strip_quotes "${line#*=}")" ;;
        esac
    done <"$CONFIG_FILE"
}

valid_url() { [[ "$1" =~ ^https?://[^[:space:]\"\\]+$ ]]; }
valid_key() { [[ "$1" =~ ^[A-Za-z0-9_.-]{8,256}$ ]]; }

prompt_api_url() {
    local reply default="${API_URL:-$DEFAULT_API_URL}"
    while true; do
        say ""
        say "API URL:"
        ask reply "[$default] (Enter for default): " "$default"
        reply="${reply%/}"
        if valid_url "$reply"; then
            API_URL="$reply"
            break
        fi
        fail "Invalid URL. It must start with http:// or https:// and contain no spaces."
    done
    if [[ "$API_URL" == http://* ]]; then
        warn "Plain HTTP: the API key will be sent unencrypted. Use only on a trusted LAN for testing."
    fi
}

prompt_api_key() {
    local key="" attempt
    for attempt in 1 2 3; do
        say ""
        IFS= read -r -s -p "Device API key (hidden input): " key </dev/tty || true
        printf '\n'
        # tolerate accidental surrounding whitespace from copy/paste
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        if valid_key "$key"; then
            [[ "$key" == nm_* ]] || warn "Key does not start with 'nm_' — make sure it is a Network Monitor device key."
            API_KEY="$key"
            return
        fi
        fail "Invalid API key format (expected 8-256 characters: letters, digits, _ . -). Attempt $attempt/3."
    done
    die "No valid API key entered."
}

write_config() {
    install -d -m 0700 -o "$AGENT_USER" -g "$AGENT_GROUP" "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
    chown "$AGENT_USER:$AGENT_GROUP" "$CONFIG_DIR"

    local tmp
    tmp="$(umask 077 && mktemp "$CONFIG_DIR/.agent.env.XXXXXX")"
    {
        printf '# Network Monitor Agent configuration\n'
        printf '# Managed by install.sh. Plain KEY=VALUE only; this file is parsed, never executed.\n'
        printf 'NETWORK_MONITOR_API_KEY=%s\n' "$API_KEY"
        printf 'NETWORK_MONITOR_API_BASE_URL=%s\n' "$API_URL"
    } >"$tmp"
    chmod 0600 "$tmp"
    chown "$AGENT_USER:$AGENT_GROUP" "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
    ok "Configuration written: $CONFIG_FILE (owner $AGENT_USER, mode 600)"
}

fix_config_permissions() {
    chown "$AGENT_USER:$AGENT_GROUP" "$CONFIG_DIR" "$CONFIG_FILE"
    chmod 0700 "$CONFIG_DIR"
    chmod 0600 "$CONFIG_FILE"
}

configure() {
    section "Configuration"
    if [[ -f "$CONFIG_FILE" ]]; then
        read_existing_config
        say "Existing configuration found: $CONFIG_FILE"
        say "  API URL: ${API_URL:-<not set>}"
        if [[ -n "$API_KEY" ]]; then say "  API key: <set, hidden>"; else say "  API key: <not set>"; fi
        say ""
        if confirm "Keep existing configuration?" Y; then
            local changed=0
            if [[ -z "$API_URL" ]] || ! valid_url "$API_URL"; then
                warn "Existing API URL is missing or invalid."
                prompt_api_url
                changed=1
            fi
            if [[ -z "$API_KEY" ]] || ! valid_key "$API_KEY"; then
                warn "Existing API key is missing or invalid."
                prompt_api_key
                changed=1
            fi
            if [[ $changed -eq 1 ]]; then
                write_config
            else
                fix_config_permissions
                ok "Keeping existing configuration (owner $AGENT_USER, mode 600)"
            fi
            return
        fi
        warn "The existing API key will be replaced."
    fi
    prompt_api_url
    prompt_api_key
    write_config
}

# ----------------------------------------------------------------------------
# verification
# ----------------------------------------------------------------------------

run_as_agent_user() {
    if [[ "$AGENT_USER" == "root" ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -H -u "$AGENT_USER" -- "$@"
    else
        local home
        home="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
        runuser -u "$AGENT_USER" -- env HOME="$home" "$@"
    fi
}

test_api() {
    local attempt rc
    for attempt in 1 2 3; do
        section "Testing API connection..."
        say ""
        rc=0
        run_as_agent_user "$AGENT_TARGET" --check || rc=$?
        case "$rc" in
            0) return 0 ;;
            3)
                if [[ $attempt -lt 3 ]] && confirm "Enter a different API key?" Y; then
                    prompt_api_key
                    write_config
                    continue
                fi
                ;;
            5)
                if [[ $attempt -lt 3 ]] && confirm "Change the API URL?" Y; then
                    prompt_api_url
                    write_config
                    continue
                fi
                ;;
        esac
        return "$rc"
    done
    return 1
}

# ----------------------------------------------------------------------------
# scheduling (systemd timer)
# ----------------------------------------------------------------------------

install_state_dir() {
    # last measured slot + lock file; never contains the API key
    install -d -m 0700 -o "$AGENT_USER" -g "$AGENT_GROUP" "$STATE_DIR"
    chown "$AGENT_USER:$AGENT_GROUP" "$STATE_DIR"
    chmod 0700 "$STATE_DIR"
}

systemd_available() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

# render_unit SOURCE TARGET -> returns 0 if TARGET changed
render_unit() {
    local src="$1" dst="$2" tmp
    tmp="$(mktemp)"
    sed -e "s|@AGENT_USER@|$AGENT_USER|g" -e "s|@AGENT_GROUP@|$AGENT_GROUP|g" "$src" >"$tmp"
    if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        return 1
    fi
    install -m 0644 -o root -g root "$tmp" "$dst"
    rm -f "$tmp"
    return 0
}

install_scheduler() {
    section "Scheduling (systemd timer)..."
    install_state_dir
    ok "State directory: $STATE_DIR (owner $AGENT_USER, mode 700)"

    if ! systemd_available; then
        warn "systemd is not running on this system; automatic scheduling is not installed."
        warn "Run 'network-speedtest --scheduled' every 5 minutes with another scheduler instead."
        return 0
    fi
    local src
    for src in "$SYSTEMD_SOURCE_DIR/$SERVICE_NAME" "$SYSTEMD_SOURCE_DIR/$TIMER_NAME"; do
        [[ -f "$src" ]] || die "Missing unit file: $src"
    done

    local changed=0
    render_unit "$SYSTEMD_SOURCE_DIR/$SERVICE_NAME" "$SYSTEMD_UNIT_DIR/$SERVICE_NAME" && changed=1
    render_unit "$SYSTEMD_SOURCE_DIR/$TIMER_NAME" "$SYSTEMD_UNIT_DIR/$TIMER_NAME" && changed=1
    if [[ $changed -eq 1 ]]; then
        systemctl daemon-reload
        ok "Installed/updated $SERVICE_NAME and $TIMER_NAME (runs as $AGENT_USER)"
    else
        ok "systemd units already up to date"
    fi

    if systemctl is-enabled --quiet "$TIMER_NAME" 2>/dev/null; then
        # already enabled: keep it, pick up changes
        [[ $changed -eq 1 ]] && systemctl restart "$TIMER_NAME"
        ok "Timer enabled (kept)"
    elif confirm "Enable automatic speedtests (schedule managed on notes.pidiman.sk)?" Y; then
        systemctl enable --now "$TIMER_NAME" >/dev/null 2>&1 \
            || die "Could not enable $TIMER_NAME (see: systemctl status $TIMER_NAME)"
        ok "Timer enabled"
    else
        say "Timer installed but not enabled. Enable later with:"
        say "  sudo systemctl enable --now $TIMER_NAME"
    fi
}

show_scheduler_status() {
    systemd_available || return 0
    [[ -f "$SYSTEMD_UNIT_DIR/$TIMER_NAME" ]] || return 0
    section "Scheduler status"
    say "Timer: $(systemctl is-enabled "$TIMER_NAME" 2>/dev/null || true), $(systemctl is-active "$TIMER_NAME" 2>/dev/null || true)"
    systemctl list-timers "$TIMER_NAME" --all --no-pager 2>/dev/null | sed -n '1,2p' || true
    say ""
    say "The timer wakes the agent every 5 minutes; a speedtest runs only in the"
    say "device's slot (see 'Next slot' above). Useful commands:"
    say "  systemctl status $TIMER_NAME"
    say "  systemctl list-timers | grep network-monitor"
    say "  journalctl -u $SERVICE_NAME"
}

offer_first_run() {
    say ""
    if confirm "Run first speedtest now?" N; then
        say ""
        run_as_agent_user "$AGENT_TARGET" || warn "First speedtest failed (see the message above)."
    fi
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        "") ;;
        *) usage >&2; die "This installer takes no arguments (the API key is entered interactively)." ;;
    esac

    ensure_root "$@"
    ensure_tty

    section "Network Monitor Agent Installer"
    say ""
    OS_CODENAME=""
    check_os
    check_arch
    resolve_agent_user

    install_dependencies
    install_ookla
    install_agent
    configure

    local api_ok=1
    if test_api; then
        api_ok=0
    else
        warn "API check failed. Configuration is kept in $CONFIG_FILE."
        warn "Fix the issue and verify with: network-speedtest --check"
    fi

    install_scheduler

    section "Installation complete."
    say "Agent:  $AGENT_TARGET"
    say "Config: $CONFIG_FILE"
    say "State:  $STATE_DIR"
    say "Run manually as '$AGENT_USER':  network-speedtest"

    show_scheduler_status

    if [[ $api_ok -eq 0 ]]; then
        offer_first_run
    fi
}

main "$@"
