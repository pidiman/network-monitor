#!/usr/bin/env bash
#
# Network Monitor Agent — uninstaller
#
# Removes the agent script. Optionally removes the configuration (API key).
# Does NOT remove the Ookla Speedtest CLI, curl or jq — other software may
# depend on them.
#
set -euo pipefail

readonly CONFIG_DIR="/etc/notes-network-monitor"
readonly AGENT_TARGET="/usr/local/bin/network-speedtest"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

say()  { printf '%s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

confirm_no_default() {
    local reply=""
    IFS= read -r -p "$1 [y/N]: " reply </dev/tty || true
    reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"
    [[ "$reply" == "y" || "$reply" == "yes" ]]
}

case "${1:-}" in
    -h|--help)
        say "Usage: sudo ./uninstall.sh"
        say "Removes $AGENT_TARGET and optionally $CONFIG_DIR."
        exit 0
        ;;
    "") ;;
    *) die "Unknown argument: $1" ;;
esac

if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Root privileges required. Run as root or install sudo."
    say "Root privileges are required; re-running with sudo..."
    exec sudo -- bash "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@"
fi

say "Network Monitor Agent Uninstaller"
say ""

if [[ -e "$AGENT_TARGET" ]]; then
    rm -f -- "$AGENT_TARGET"
    ok "Removed $AGENT_TARGET"
else
    say "Agent not installed ($AGENT_TARGET not found)."
fi

if [[ -d "$CONFIG_DIR" ]]; then
    say ""
    if confirm_no_default "Remove configuration and API key?"; then
        rm -rf -- "$CONFIG_DIR"
        ok "Removed $CONFIG_DIR"
    else
        say "Configuration kept: $CONFIG_DIR/agent.env"
    fi
fi

say ""
say "Not removed (may be used by other software): Ookla Speedtest CLI, curl, jq,"
say "and the Ookla apt repository (/etc/apt/sources.list.d/ookla_speedtest-cli.list)."
say "Remove them manually if no longer needed, e.g.: sudo apt-get remove speedtest"
say ""
say "Uninstall complete."
