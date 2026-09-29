#!/usr/bin/env bash
#
# network-speedtest — Network Monitor Agent
#
# Runs the official Ookla Speedtest CLI and reports the result to the
# notes.pidiman.sk Network Monitor API.
#
#   1. read config: NETWORK_MONITOR_API_KEY + NETWORK_MONITOR_API_BASE_URL
#      environment variables (Docker), otherwise the config file
#      (safe parser, the file is never sourced/executed)
#   2. GET  <base>/config       -> device info, enabled flag
#   3. run  speedtest --format=json
#   4. POST <base>/speedtests   -> store result
#
# Modes:
#   network-speedtest               manual run: measure now (if enabled)
#   network-speedtest --scheduled   run only in the device's schedule slot
#                                   (called every 5 min by a systemd timer /
#                                   Synology Task Scheduler)
#   network-speedtest --check       API/auth check only, no speedtest
#
# Schedule (from GET /config): interval_minutes = N, offset_minutes = O,
# 0 <= O < N. Slots start at every UTC minute M (minutes since the Unix epoch)
# with (M - O) mod N == 0. A slot may start up to SLOT_TOLERANCE_MINUTES late
# (capped at N); each slot runs at most once (state: last_slot).
#
# Exit codes:
#   0  success (also: duplicate result, or device disabled on the server)
#   1  general / dependency error
#   2  configuration error
#   3  API authentication error (HTTP 401)
#   4  speedtest error
#   5  API / network error
#   6  invalid schedule from the server (--scheduled / --check only)
#   7  another run is already in progress (manual run only; --scheduled exits 0)
#
set -euo pipefail
umask 077

readonly AGENT_VERSION="0.3.0"
readonly DEFAULT_CONFIG_FILE="/etc/notes-network-monitor/agent.env"
CONFIG_FILE="${NETWORK_MONITOR_CONFIG:-$DEFAULT_CONFIG_FILE}"
readonly DEFAULT_STATE_DIR="/var/lib/notes-network-monitor"
STATE_DIR="${NETWORK_MONITOR_STATE_DIR:-$DEFAULT_STATE_DIR}"

# A scheduled slot may start this many minutes late (timer granularity,
# reboot). Capped at the interval. Must be > the wake-up period (5 min).
readonly SLOT_TOLERANCE_MINUTES=10

readonly EXIT_ERROR=1
readonly EXIT_CONFIG=2
readonly EXIT_AUTH=3
readonly EXIT_SPEEDTEST=4
readonly EXIT_API=5
readonly EXIT_SCHEDULE=6
readonly EXIT_BUSY=7

# Timeouts (seconds)
readonly CURL_CONNECT_TIMEOUT=10
readonly CONFIG_MAX_TIME=30
readonly POST_MAX_TIME=60
readonly SPEEDTEST_TIMEOUT=300

API_KEY=""
API_BASE_URL=""
CONFIG_SOURCE=""
TMP_DIR=""
LOCK_DIR_HELD=""

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

log()  { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { local code="$1"; shift; printf 'Error: %s\n' "$*" >&2; exit "$code"; }

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
    if [[ -n "$LOCK_DIR_HELD" ]]; then
        rm -rf -- "$LOCK_DIR_HELD"
    fi
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: network-speedtest [--scheduled | --check] [--help] [--version]

Runs an Ookla speedtest and sends the result to the Network Monitor API.

Without options: manual run — measures immediately if the device is enabled
(interval/offset are ignored).

Options:
  --scheduled Run only if now is inside the device's schedule slot
              (interval_minutes / offset_minutes from the server) and the
              slot was not measured yet; otherwise exit 0. Used by the
              systemd timer / Synology Task Scheduler.
  --check     Only verify config + API authentication, print device info
              and the next scheduled slot. Does not run a speedtest.
  --help      Show this help.
  --version   Show agent version.

Configuration (first match wins):
  1. environment variables NETWORK_MONITOR_API_KEY and
     NETWORK_MONITOR_API_BASE_URL (both must be set; used by Docker)
  2. config file ${DEFAULT_CONFIG_FILE}
     (override the path with the NETWORK_MONITOR_CONFIG environment variable)

State (last measured slot, lock): ${DEFAULT_STATE_DIR}
  (override with NETWORK_MONITOR_STATE_DIR)
EOF
}

file_mode() {
    # GNU stat (Linux) first, BSD stat (macOS) as fallback.
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

# Strip one level of matching surrounding quotes.
unquote() {
    local v="$1"
    if [[ ${#v} -ge 2 ]]; then
        if [[ "$v" == \"*\" || "$v" == \'*\' ]]; then
            v="${v:1:${#v}-2}"
        fi
    fi
    printf '%s' "$v"
}

# Environment variables (Docker) take precedence over the config file
# (Raspberry Pi / Debian installer). Both variables must be set.
load_config() {
    if [[ -n "${NETWORK_MONITOR_API_KEY:-}" && -n "${NETWORK_MONITOR_API_BASE_URL:-}" ]]; then
        API_KEY="$NETWORK_MONITOR_API_KEY"
        API_BASE_URL="$NETWORK_MONITOR_API_BASE_URL"
        CONFIG_SOURCE="environment"
        # Do not pass the key on to child processes (curl, speedtest).
        unset NETWORK_MONITOR_API_KEY
    elif [[ ! -e "$CONFIG_FILE" && -n "${NETWORK_MONITOR_API_KEY:-}${NETWORK_MONITOR_API_BASE_URL:-}" ]]; then
        die "$EXIT_CONFIG" "both NETWORK_MONITOR_API_KEY and NETWORK_MONITOR_API_BASE_URL environment variables must be set"
    else
        load_config_file
        CONFIG_SOURCE="$CONFIG_FILE"
    fi
    validate_config
}

# Parse only the known KEY=VALUE lines. The file is never sourced, so
# nothing in it is ever executed ($(...), backticks, ; etc. stay literal).
load_config_file() {
    [[ -e "$CONFIG_FILE" ]] || die "$EXIT_CONFIG" "no configuration: set the NETWORK_MONITOR_API_KEY and NETWORK_MONITOR_API_BASE_URL environment variables, or create $CONFIG_FILE (run install.sh)"
    [[ -r "$CONFIG_FILE" ]] || die "$EXIT_CONFIG" "config file not readable by user '$(id -un)': $CONFIG_FILE"

    local mode
    mode="$(file_mode "$CONFIG_FILE")"
    if [[ -n "$mode" && "${mode: -2}" != "00" ]]; then
        warn "config file $CONFIG_FILE has permissions $mode; expected 600"
    fi

    local line key value re='^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)[[:space:]]*=(.*)$'
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ "$line" =~ $re ]]; then
            key="${BASH_REMATCH[2]}"
            value="${BASH_REMATCH[3]}"
            # trim surrounding whitespace
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            value="$(unquote "$value")"
            case "$key" in
                NETWORK_MONITOR_API_KEY)      API_KEY="$value" ;;
                NETWORK_MONITOR_API_BASE_URL) API_BASE_URL="$value" ;;
                *) warn "ignoring unknown config key: $key" ;;
            esac
        else
            warn "ignoring malformed config line"
        fi
    done < "$CONFIG_FILE"
}

validate_config() {
    [[ -n "$API_KEY" ]] || die "$EXIT_CONFIG" "NETWORK_MONITOR_API_KEY is empty in $CONFIG_SOURCE"
    [[ "$API_KEY" =~ ^[A-Za-z0-9_.-]+$ ]] \
        || die "$EXIT_CONFIG" "NETWORK_MONITOR_API_KEY contains invalid characters"
    [[ -n "$API_BASE_URL" ]] || die "$EXIT_CONFIG" "NETWORK_MONITOR_API_BASE_URL is empty in $CONFIG_SOURCE"
    [[ "$API_BASE_URL" =~ ^https?://[^[:space:]\"\\]+$ ]] \
        || die "$EXIT_CONFIG" "NETWORK_MONITOR_API_BASE_URL is not a valid http(s) URL: $API_BASE_URL"
    API_BASE_URL="${API_BASE_URL%/}"
}

require_commands() {
    command -v curl >/dev/null 2>&1 || die "$EXIT_ERROR" "curl is not installed (sudo apt install curl)"
    command -v jq   >/dev/null 2>&1 || die "$EXIT_ERROR" "jq is not installed (sudo apt install jq)"
}

require_ookla() {
    command -v speedtest >/dev/null 2>&1 \
        || die "$EXIT_ERROR" "Ookla Speedtest CLI ('speedtest') not found (run install.sh)"
    local version
    version="$(speedtest --version 2>/dev/null | head -n 1 || true)"
    if [[ "$version" != *"Speedtest by Ookla"* ]]; then
        die "$EXIT_ERROR" "'$(command -v speedtest)' is not the official Ookla Speedtest CLI" \
            "(found: ${version:-unknown}). The Python 'speedtest-cli' is not supported."
    fi
}

# api_request METHOD URL BODY_OUT [DATA_FILE]
# Sets HTTP_STATUS (000 on network error) and CURL_ERROR.
# The API key is passed to curl via stdin (--config -), so it never
# appears in the process list (ps) or in shell history.
api_request() {
    local method="$1" url="$2" out="$3" data="${4:-}"
    local max_time="$CONFIG_MAX_TIME" rc=0
    local err_file="$TMP_DIR/curl.err"
    local -a extra=()

    if [[ -n "$data" ]]; then
        max_time="$POST_MAX_TIME"
        extra=(--header 'Content-Type: application/json' --data-binary "@$data")
    fi

    HTTP_STATUS=""
    CURL_ERROR=""
    : >"$out"
    HTTP_STATUS="$(printf 'header = "X-API-Key: %s"\n' "$API_KEY" \
        | curl --config - --silent --show-error \
            --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$max_time" \
            --request "$method" \
            --header 'Accept: application/json' \
            ${extra[@]+"${extra[@]}"} \
            --output "$out" --write-out '%{http_code}' \
            "$url" 2>"$err_file")" || rc=$?

    if [[ $rc -ne 0 ]]; then
        CURL_ERROR="$(head -c 500 "$err_file" 2>/dev/null || true)"
        HTTP_STATUS="000"
    fi
    [[ -n "$HTTP_STATUS" ]] || HTTP_STATUS="000"
}

# Extract a human readable error message from an API response body.
api_error_message() {
    jq -r 'if type == "object" then (.error // .message // empty)
           else empty end | if type == "string" then . else tojson end' "$1" 2>/dev/null \
        | head -c 500 || true
}

# ----------------------------------------------------------------------------
# steps
# ----------------------------------------------------------------------------

DEVICE_KEY=""
DEVICE_ENABLED=""
DEVICE_INTERVAL=""
DEVICE_OFFSET=""
HTTP_STATUS=""
CURL_ERROR=""

fetch_config() {
    local body="$TMP_DIR/config.json" msg
    api_request GET "$API_BASE_URL/config" "$body"

    case "$HTTP_STATUS" in
        200) ;;
        000) die "$EXIT_API" "cannot reach API at $API_BASE_URL/config: ${CURL_ERROR:-network error}" ;;
        401) die "$EXIT_AUTH" "API authentication failed (HTTP 401): invalid or revoked API key" ;;
        *)
            msg="$(api_error_message "$body")"
            die "$EXIT_API" "GET /config failed with HTTP $HTTP_STATUS${msg:+: $msg}"
            ;;
    esac

    jq -e 'type == "object"' "$body" >/dev/null 2>&1 \
        || die "$EXIT_API" "GET /config returned invalid JSON"

    DEVICE_KEY="$(jq -r '.device_key // empty | tostring' "$body")"
    DEVICE_ENABLED="$(jq -r 'if (.enabled | type) == "boolean" then .enabled | tostring else "invalid" end' "$body")"
    DEVICE_INTERVAL="$(jq -r '.interval_minutes // "?" | tostring' "$body")"
    DEVICE_OFFSET="$(jq -r '.offset_minutes // "?" | tostring' "$body")"

    [[ -n "$DEVICE_KEY" ]] || die "$EXIT_API" "GET /config response has no device_key"
    [[ "$DEVICE_ENABLED" != "invalid" ]] || die "$EXIT_API" "GET /config response has no boolean 'enabled'"

    # Empty when interval/offset form a valid schedule, otherwise the reason.
    # Invalid combinations are reported, never silently normalised.
    SCHEDULE_ERROR="$(jq -r '
        def int: type == "number" and . == floor;
        if (.interval_minutes | int | not) or .interval_minutes < 1 then
            "interval_minutes must be a positive integer (got \(.interval_minutes | tojson))"
        elif (.offset_minutes | int | not) or .offset_minutes < 0 then
            "offset_minutes must be a non-negative integer (got \(.offset_minutes | tojson))"
        elif .offset_minutes >= .interval_minutes then
            "offset_minutes (\(.offset_minutes)) must be less than interval_minutes (\(.interval_minutes))"
        else "" end' "$body")"
}

# ----------------------------------------------------------------------------
# schedule
# ----------------------------------------------------------------------------

SCHEDULE_ERROR=""
SLOT_START=""       # current slot start, epoch minutes
SLOT_LATE=""        # minutes since SLOT_START
SLOT_WINDOW=""      # minutes after SLOT_START in which the slot may still run

now_epoch() {
    # NETWORK_MONITOR_TEST_NOW (epoch seconds) is for tests only.
    if [[ -n "${NETWORK_MONITOR_TEST_NOW:-}" ]]; then
        printf '%s' "$NETWORK_MONITOR_TEST_NOW"
    else
        date +%s
    fi
}

# fmt_time EPOCH_SECONDS -> local time, GNU date first, BSD date fallback
fmt_time() {
    date -d "@$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M %Z'
}

# Slot of "now": (M - O) mod N == 0, M = epoch minutes (UTC based).
compute_slot() {
    local now_min interval="$DEVICE_INTERVAL" offset="$DEVICE_OFFSET"
    now_min=$(( $(now_epoch) / 60 ))
    SLOT_LATE=$(( ((now_min - offset) % interval + interval) % interval ))
    SLOT_START=$(( now_min - SLOT_LATE ))
    SLOT_WINDOW=$SLOT_TOLERANCE_MINUTES
    (( interval < SLOT_WINDOW )) && SLOT_WINDOW=$interval
    return 0
}

# Start of the next slot strictly after the current one.
next_slot_epoch() {
    compute_slot
    printf '%s' $(( (SLOT_START + DEVICE_INTERVAL) * 60 ))
}

# State dir holds only last_slot + the lock file (never the API key).
ensure_state_dir() {
    if [[ ! -d "$STATE_DIR" ]]; then
        (umask 077 && mkdir -p -- "$STATE_DIR") 2>/dev/null || return 1
    fi
    [[ -w "$STATE_DIR" ]]
}

# Returns 0 = lock acquired, 1 = another run holds it.
acquire_lock() {
    local lock="$STATE_DIR/agent.lock"
    if command -v flock >/dev/null 2>&1; then
        # Kernel lock, released automatically when the process exits.
        exec 9>>"$lock"
        flock -n 9 || return 1
        return 0
    fi
    # Fallback without flock (e.g. macOS dev machines): atomic mkdir + pid.
    local dir="$lock.d" pid
    if ! mkdir -- "$dir" 2>/dev/null; then
        pid="$(cat "$dir/pid" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        rm -rf -- "$dir"
        mkdir -- "$dir" 2>/dev/null || return 1
    fi
    printf '%s\n' "$$" >"$dir/pid"
    LOCK_DIR_HELD="$dir"
    return 0
}

read_last_slot() {
    local line value=""
    if [[ -f "$STATE_DIR/last_slot" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^last_slot=([0-9]+)$ ]] && value="${BASH_REMATCH[1]}"
        done <"$STATE_DIR/last_slot"
    fi
    printf '%s' "${value:-0}"
}

write_last_slot() {
    local tmp
    tmp="$(mktemp "$STATE_DIR/.last_slot.XXXXXX")"
    {
        printf 'last_slot=%s\n' "$1"
        printf 'slot_time=%s\n' "$(fmt_time $(( $1 * 60 )))"
        printf 'device_key=%s\n' "$DEVICE_KEY"
    } >"$tmp"
    mv -f -- "$tmp" "$STATE_DIR/last_slot"
}

# Runs the Ookla CLI; writes the raw result JSON object to $1.
run_speedtest() {
    local result="$1" raw="$TMP_DIR/speedtest.out" err="$TMP_DIR/speedtest.err" rc=0
    local -a cmd=(speedtest --accept-license --accept-gdpr --format=json)

    # Never block forever: use coreutils timeout when available.
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=10 "$SPEEDTEST_TIMEOUT" "${cmd[@]}" >"$raw" 2>"$err" </dev/null || rc=$?
    else
        "${cmd[@]}" >"$raw" 2>"$err" </dev/null || rc=$?
    fi

    if [[ $rc -eq 124 ]]; then
        die "$EXIT_SPEEDTEST" "speedtest timed out after ${SPEEDTEST_TIMEOUT}s"
    fi

    # Output may contain log lines / license text; keep the last "result" object.
    jq -R -c 'fromjson? | select(type == "object" and .type == "result")' "$raw" 2>/dev/null \
        | tail -n 1 >"$result" || true

    if [[ ! -s "$result" ]]; then
        local detail
        detail="$(cat "$raw" "$err" 2>/dev/null \
            | jq -R -r 'fromjson? | select(type == "object") | .message // .error // empty' 2>/dev/null \
            | tail -n 1 || true)"
        [[ -n "$detail" ]] || detail="$(tail -n 3 "$err" 2>/dev/null | tr '\n' ' ' || true)"
        die "$EXIT_SPEEDTEST" "speedtest failed (exit $rc)${detail:+: $detail}"
    fi
}

# Transform Ookla JSON ($1) into the API payload ($2).
build_payload() {
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -c --arg now "$now" '
        # Ookla bandwidth is bytes/s -> Mbps, rounded to 2 decimals
        def mbps: if type == "number" then ((. * 8 / 10000) + 0.5 | floor) / 100 else null end;
        def num:  if type == "number" then . else null end;
        def str:  if type == "string" and length > 0 then . else null end;
        {
          measured_at:         (.timestamp | str // $now),
          download_mbps:       (.download.bandwidth | mbps),
          upload_mbps:         (.upload.bandwidth | mbps),
          ping_ms:             (.ping.latency | num),
          jitter_ms:           (.ping.jitter | num),
          download_latency_ms: (.download.latency.iqm | num),
          upload_latency_ms:   (.upload.latency.iqm | num),
          packet_loss_percent: (.packetLoss | num),
          isp:                 (.isp | str),
          interface_name:      (.interface.name | str),
          internal_ip:         (.interface.internalIp | str),
          server_name:         (.server.name | str),
          server_location:     (.server.location | str),
          server_country:      (.server.country | str),
          server_id:           (.server.id | num),
          result_id:           (.result.id | str),
          result_url:          (.result.url | str)
        }' "$1" >"$2" || die "$EXIT_SPEEDTEST" "cannot transform speedtest result"

    jq -e '.download_mbps != null and .upload_mbps != null and .ping_ms != null' "$2" >/dev/null \
        || die "$EXIT_SPEEDTEST" "speedtest result is missing download/upload/ping values"
}

print_result() {
    jq -r '
        def f(n): if n == null then "n/a" else (n | tostring) end;
        "Download: \(f(.download_mbps)) Mbps",
        "Upload:   \(f(.upload_mbps)) Mbps",
        "Ping:     \(f(.ping_ms)) ms",
        "Jitter:   \(f(.jitter_ms)) ms",
        "Server:   \([.server_name, .server_location] | map(select(. != null)) | join(", ") | if . == "" then "n/a" else . end)",
        (if .result_url then "Result:   \(.result_url)" else empty end)
    ' "$1"
}

post_result() {
    local payload="$1" body="$TMP_DIR/post.json" msg id
    api_request POST "$API_BASE_URL/speedtests" "$body" "$payload"

    case "$HTTP_STATUS" in
        201)
            id="$(jq -r '(.id // .speedtest.id // .result.id // empty) | tostring' "$body" 2>/dev/null || true)"
            log "Result stored successfully."
            [[ -n "$id" ]] && log "ID: $id"
            ;;
        200)
            if jq -e '.duplicate == true' "$body" >/dev/null 2>&1; then
                id="$(jq -r '(.id // .speedtest.id // empty) | tostring' "$body" 2>/dev/null || true)"
                log "Result already stored (duplicate result_id) — OK."
                [[ -n "$id" ]] && log "ID: $id"
            else
                log "Result accepted (HTTP 200)."
            fi
            ;;
        000) die "$EXIT_API" "cannot reach API at $API_BASE_URL/speedtests: ${CURL_ERROR:-network error}" ;;
        400)
            msg="$(api_error_message "$body")"
            die "$EXIT_API" "API rejected the payload (HTTP 400)${msg:+: $msg}"
            ;;
        401) die "$EXIT_AUTH" "API authentication failed (HTTP 401): invalid or revoked API key" ;;
        5??)
            msg="$(api_error_message "$body")"
            die "$EXIT_API" "API server error (HTTP $HTTP_STATUS)${msg:+: $msg}"
            ;;
        *)
            msg="$(api_error_message "$body")"
            die "$EXIT_API" "POST /speedtests failed with HTTP $HTTP_STATUS${msg:+: $msg}"
            ;;
    esac
}

# Speedtest + POST. Optional $1: slot to record once the measurement exists.
measure_and_report() {
    local slot="${1:-}"
    log ""
    log "Running speedtest..."
    run_speedtest "$TMP_DIR/result.json"
    # Record the slot as soon as a measurement exists, so a failed POST never
    # triggers a second speedtest in the same slot.
    [[ -n "$slot" ]] && write_last_slot "$slot"
    build_payload "$TMP_DIR/result.json" "$TMP_DIR/payload.json"
    log ""
    print_result "$TMP_DIR/payload.json"

    log ""
    log "Sending result to API..."
    log ""
    post_result "$TMP_DIR/payload.json"
}

run_scheduled() {
    fetch_config
    local sched="interval $DEVICE_INTERVAL min, offset $DEVICE_OFFSET min"

    if [[ "$DEVICE_ENABLED" != "true" ]]; then
        log "[$DEVICE_KEY] disabled on the server (enabled=false). Nothing to do."
        exit 0
    fi
    [[ -z "$SCHEDULE_ERROR" ]] \
        || die "$EXIT_SCHEDULE" "[$DEVICE_KEY] invalid schedule from the server: $SCHEDULE_ERROR. No speedtest."

    compute_slot
    if (( SLOT_LATE >= SLOT_WINDOW )); then
        log "[$DEVICE_KEY] not in a slot; next: $(fmt_time $(( (SLOT_START + DEVICE_INTERVAL) * 60 ))) ($sched). Nothing to do."
        exit 0
    fi

    ensure_state_dir || die "$EXIT_CONFIG" "state directory $STATE_DIR is not writable by user '$(id -un)' (run install.sh)"
    if ! acquire_lock; then
        log "[$DEVICE_KEY] another network-speedtest run is in progress. Skipping."
        exit 0
    fi
    local last
    last="$(read_last_slot)"
    if (( last >= SLOT_START )); then
        log "[$DEVICE_KEY] slot $(fmt_time $(( SLOT_START * 60 ))) already measured. Nothing to do."
        exit 0
    fi

    require_ookla
    log "Network Monitor"
    log "Device: $DEVICE_KEY"
    log "Slot:   $(fmt_time $(( SLOT_START * 60 ))) ($sched, started ${SLOT_LATE} min ago)"
    measure_and_report "$SLOT_START"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    local check_only=0 scheduled=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)   check_only=1 ;;
            --scheduled) scheduled=1 ;;
            --help|-h) usage; exit 0 ;;
            --version) log "network-speedtest $AGENT_VERSION"; exit 0 ;;
            *) usage >&2; exit "$EXIT_ERROR" ;;
        esac
        shift
    done
    if [[ $check_only -eq 1 && $scheduled -eq 1 ]]; then
        usage >&2; exit "$EXIT_ERROR"
    fi

    require_commands
    load_config
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/network-speedtest.XXXXXX")"
    chmod 700 "$TMP_DIR"

    if [[ $check_only -eq 1 ]]; then
        fetch_config
        log "✓ Authentication successful"
        log ""
        log "Device:   $DEVICE_KEY"
        log "Enabled:  $DEVICE_ENABLED"
        log "Interval: $DEVICE_INTERVAL min"
        log "Offset:   $DEVICE_OFFSET min"
        if [[ -n "$SCHEDULE_ERROR" ]]; then
            log "Schedule: INVALID — $SCHEDULE_ERROR (scheduled runs will fail, no speedtest)"
        elif [[ "$DEVICE_ENABLED" == "true" ]]; then
            log "Next slot: $(fmt_time "$(next_slot_epoch)")"
        fi
        exit 0
    fi

    if [[ $scheduled -eq 1 ]]; then
        run_scheduled
        exit 0
    fi

    require_ookla

    log "Network Monitor"
    fetch_config
    log "Device: $DEVICE_KEY"

    if [[ "$DEVICE_ENABLED" != "true" ]]; then
        log ""
        log "Device is disabled on the server (enabled=false). Skipping speedtest."
        exit 0
    fi

    # Never run two speedtests in parallel (manual vs. scheduled).
    if ensure_state_dir; then
        acquire_lock || die "$EXIT_BUSY" "another network-speedtest run is in progress; try again later"
    else
        warn "state directory $STATE_DIR not writable; running without the concurrency lock"
    fi

    measure_and_report
}

main "$@"
