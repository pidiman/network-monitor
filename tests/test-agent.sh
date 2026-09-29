#!/usr/bin/env bash
#
# Offline tests for src/network-speedtest.sh.
#
# Uses fake `curl` and `speedtest` commands placed first in PATH and a
# temporary config file (NETWORK_MONITOR_CONFIG). Nothing is installed and
# no system files are touched; no network access is needed. Requires jq.
#
#   ./tests/test-agent.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="$ROOT/src/network-speedtest.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nm-agent-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MOCKBIN="$WORK/bin"
mkdir -p "$MOCKBIN"
TEST_KEY="nm_TESTKEY_do_not_print_1234567890"

PASS=0
FAIL=0

# ---------------------------------------------------------------- fakes ----

cat >"$MOCKBIN/curl" <<'MOCK'
#!/usr/bin/env bash
# Fake curl: records argv/stdin, answers according to MOCK_* env vars.
out="" data="" url="" method="GET"
printf '%s\n' "$*" >>"$MOCK_DIR/curl.argv"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) [[ "$2" == "-" ]] && cat >>"$MOCK_DIR/curl.stdin"; shift ;;
        --output) out="$2"; shift ;;
        --data-binary) data="${2#@}"; shift ;;
        --request) method="$2"; shift ;;
        --write-out|--connect-timeout|--max-time|--header) shift ;;
        http*) url="$1" ;;
    esac
    shift
done
if [[ -n "${MOCK_CURL_FAIL:-}" ]]; then
    echo "curl: (7) Failed to connect to host port 443: Connection refused" >&2
    printf '000'
    exit 7
fi
default_config_body='{"device_key":"rpi-test","enabled":true,"interval_minutes":60,"offset_minutes":5}'
default_post_body='{"id":2}'
case "$method $url" in
    "GET "*/config)
        printf '%s' "${MOCK_CONFIG_BODY:-$default_config_body}" >"$out"
        printf '%s' "${MOCK_CONFIG_STATUS:-200}"
        ;;
    "POST "*/speedtests)
        cp "$data" "$MOCK_DIR/payload.json"
        printf '%s' "${MOCK_POST_BODY:-$default_post_body}" >"$out"
        printf '%s' "${MOCK_POST_STATUS:-201}"
        ;;
    *)
        printf '{"error":"not found"}' >"$out"; printf '404'
        ;;
esac
MOCK

cp "$ROOT/tests/fixtures/fake-speedtest" "$MOCKBIN/speedtest"
chmod +x "$MOCKBIN/curl" "$MOCKBIN/speedtest"

# -------------------------------------------------------------- helpers ----

write_config() {
    printf '%s\n' "$@" >"$WORK/agent.env"
    chmod 600 "$WORK/agent.env"
}

default_config() {
    write_config \
        "# test config" \
        "NETWORK_MONITOR_API_KEY=$TEST_KEY" \
        "NETWORK_MONITOR_API_BASE_URL=https://api.example.test/api/network/"
}

# run_agent [env assignments...] -- [agent args...]
run_agent() {
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    rm -rf "$WORK/mock"; mkdir -p "$WORK/mock"
    OUTPUT="$(env -i HOME="$WORK" PATH="$MOCKBIN:/usr/bin:/bin" TMPDIR="$WORK" \
        MOCK_DIR="$WORK/mock" NETWORK_MONITOR_CONFIG="$WORK/agent.env" \
        ${envs[@]+"${envs[@]}"} bash "$AGENT" "$@" 2>&1)"
    STATUS=$?
}

check() {
    local name="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$name"
        printf '%s\n' "$OUTPUT" | sed 's/^/        | /'
    fi
}

status_is()   { [[ "$STATUS" -eq "$1" ]]; }
output_has()  { [[ "$OUTPUT" == *"$1"* ]]; }
output_lacks(){ [[ "$OUTPUT" != *"$1"* ]]; }
speedtest_ran() { [[ -f "$WORK/mock/speedtest.args" ]]; }
key_not_leaked() {
    [[ "$OUTPUT" != *"$TEST_KEY"* ]] \
        && ! grep -qs "$TEST_KEY" "$WORK/mock/curl.argv" \
        && ! grep -qs "$TEST_KEY" "$WORK/mock/payload.json"
}

# ---------------------------------------------------------------- tests ----

echo "1. happy path (201)"
default_config
run_agent --
check "exit 0" status_is 0
check "device shown" output_has "Device: rpi-test"
check "download 907.94" output_has "Download: 907.94 Mbps"
check "upload 931.19" output_has "Upload:   931.19 Mbps"
check "ping / jitter" output_has "Ping:     2.846 ms"
check "server" output_has "Server:   ACS, Bratislava"
check "stored + id" output_has "ID: 2"
check "license flags passed" grep -q -- '--accept-license --accept-gdpr --format=json' "$WORK/mock/speedtest.args"
check "key sent via curl stdin config" grep -q "X-API-Key: $TEST_KEY" "$WORK/mock/curl.stdin"
check "key not in argv/output/payload" key_not_leaked
check "trailing slash stripped from URL" grep -q 'https://api.example.test/api/network/speedtests' "$WORK/mock/curl.argv"
EXPECTED='{"measured_at":"2026-09-29T10:44:05Z","download_mbps":907.94,"upload_mbps":931.19,"ping_ms":2.846,"jitter_ms":0.209,"download_latency_ms":2.505,"upload_latency_ms":7.313,"packet_loss_percent":null,"isp":"Slovak Telekom","interface_name":"eth0","internal_ip":"192.168.1.27","server_name":"ACS","server_location":"Bratislava","server_country":"Slovakia","server_id":34925,"result_id":"45ff5e54-7260-4bb3-acd2-93b3e7a80f49","result_url":"https://www.speedtest.net/result/c/45ff5e54-7260-4bb3-acd2-93b3e7a80f49"}'
payload_matches() { [[ "$(jq -cS . "$WORK/mock/payload.json")" == "$(printf '%s' "$EXPECTED" | jq -cS .)" ]]; }
check "payload matches spec exactly" payload_matches

echo "2. duplicate (200 + duplicate=true)"
run_agent 'MOCK_POST_STATUS=200' 'MOCK_POST_BODY={"duplicate":true,"id":2}' --
check "exit 0" status_is 0
check "duplicate reported" output_has "duplicate"

echo "3. device disabled"
run_agent 'MOCK_CONFIG_BODY={"device_key":"rpi-test","enabled":false,"interval_minutes":60,"offset_minutes":0}' --
check "exit 0" status_is 0
check "skip message" output_has "disabled"
check "speedtest NOT run" bash -c "! test -f '$WORK/mock/speedtest.args'"

echo "4. invalid API key (401 on config)"
run_agent 'MOCK_CONFIG_STATUS=401' 'MOCK_CONFIG_BODY={"error":"unauthorized"}' --
check "exit 3" status_is 3
check "message" output_has "invalid or revoked API key"
check "speedtest NOT run" bash -c "! test -f '$WORK/mock/speedtest.args'"
check "key not leaked" key_not_leaked

echo "5. payload rejected (400)"
run_agent 'MOCK_POST_STATUS=400' 'MOCK_POST_BODY={"error":"download_mbps must be a number"}' --
check "exit 5" status_is 5
check "server message shown" output_has "download_mbps must be a number"

echo "6. server error (500)"
run_agent 'MOCK_POST_STATUS=500' 'MOCK_POST_BODY={"error":"internal"}' --
check "exit 5" status_is 5
check "message" output_has "server error (HTTP 500)"

echo "7. 401 on POST"
run_agent 'MOCK_POST_STATUS=401' --
check "exit 3" status_is 3

echo "8. network error"
run_agent 'MOCK_CURL_FAIL=1' --
check "exit 5" status_is 5
check "curl error shown" output_has "Connection refused"

echo "9. invalid JSON from /config"
run_agent 'MOCK_CONFIG_BODY=<html>oops</html>' --
check "exit 5" status_is 5
check "message" output_has "invalid JSON"

echo "10. speedtest failure"
run_agent 'MOCK_SPEEDTEST_FAIL=1' --
check "exit 4" status_is 4
check "ookla error shown" output_has "Timeout occurred in connect"

echo "11. Python speedtest-cli detected"
run_agent 'MOCK_SPEEDTEST_KIND=python' --
check "exit 1" status_is 1
check "message" output_has "not the official Ookla"

echo "12. --check"
run_agent -- --check
check "exit 0" status_is 0
check "auth ok" output_has "✓ Authentication successful"
check "interval/offset" output_has "Offset:   5 min"
check "speedtest NOT run" bash -c "! test -f '$WORK/mock/speedtest.args'"

echo "13. config is parsed, never executed"
rm -f "$WORK/pwned"
write_config \
    "NETWORK_MONITOR_API_KEY=\"$TEST_KEY\"" \
    "NETWORK_MONITOR_API_BASE_URL='https://api.example.test/api/network'" \
    "EVIL=\$(touch $WORK/pwned)" \
    "touch $WORK/pwned" \
    "\`touch $WORK/pwned\`"
run_agent -- --check
check "quoted values accepted" status_is 0
check "no code executed" bash -c "! test -e '$WORK/pwned'"
check "unknown key ignored with warning" output_has "ignoring unknown config key: EVIL"

echo "14. injection via key value rejected"
write_config \
    "NETWORK_MONITOR_API_KEY=abc\$(touch $WORK/pwned)" \
    "NETWORK_MONITOR_API_BASE_URL=https://api.example.test/api/network"
run_agent -- --check
check "exit 2" status_is 2
check "no code executed" bash -c "! test -e '$WORK/pwned'"

echo "15. missing config"
rm -f "$WORK/agent.env"
run_agent --
check "exit 2" status_is 2
check "message" output_has "no configuration"

echo "16. world-readable config warns"
default_config
chmod 644 "$WORK/agent.env"
run_agent -- --check
check "warning" output_has "expected 600"

echo "17. CRLF config"
printf 'NETWORK_MONITOR_API_KEY=%s\r\nNETWORK_MONITOR_API_BASE_URL=https://api.example.test/api/network\r\n' "$TEST_KEY" >"$WORK/agent.env"
chmod 600 "$WORK/agent.env"
run_agent -- --check
check "exit 0" status_is 0

echo "18. config from environment variables (Docker)"
rm -f "$WORK/agent.env"
run_agent "NETWORK_MONITOR_API_KEY=$TEST_KEY" "NETWORK_MONITOR_API_BASE_URL=https://env.example.test/api/network" --
check "exit 0 without config file" status_is 0
check "stored" output_has "Result stored successfully."
check "env URL used" grep -q 'https://env.example.test/api/network/speedtests' "$WORK/mock/curl.argv"
check "key via curl stdin" grep -q "X-API-Key: $TEST_KEY" "$WORK/mock/curl.stdin"
check "key not leaked" key_not_leaked

echo "19. environment variables take precedence over config file"
default_config
run_agent "NETWORK_MONITOR_API_KEY=nm_ENVKEY_1234567890" "NETWORK_MONITOR_API_BASE_URL=https://env.example.test/api/network" -- --check
check "exit 0" status_is 0
check "env key used" grep -q "X-API-Key: nm_ENVKEY_1234567890" "$WORK/mock/curl.stdin"
check "file key not used" bash -c "! grep -q '$TEST_KEY' '$WORK/mock/curl.stdin'"
check "env URL used" grep -q 'https://env.example.test/api/network/config' "$WORK/mock/curl.argv"

echo "20. only one env variable set, no config file"
rm -f "$WORK/agent.env"
run_agent "NETWORK_MONITOR_API_KEY=$TEST_KEY" -- --check
check "exit 2" status_is 2
check "message" output_has "both NETWORK_MONITOR_API_KEY and NETWORK_MONITOR_API_BASE_URL"
check "key not leaked" key_not_leaked

echo "21. only one env variable set, config file present -> file used"
default_config
run_agent "NETWORK_MONITOR_API_BASE_URL=https://env.example.test/api/network" -- --check
check "exit 0" status_is 0
check "file URL used" grep -q 'https://api.example.test/api/network/config' "$WORK/mock/curl.argv"

echo "22. invalid key in environment rejected"
rm -f "$WORK/agent.env"
# shellcheck disable=SC2016  # literal $(id) is the point of this test
run_agent 'NETWORK_MONITOR_API_KEY=abc$(id)' "NETWORK_MONITOR_API_BASE_URL=https://env.example.test/api/network" -- --check
check "exit 2" status_is 2
check "message" output_has "invalid characters"

echo "23. key not exported to speedtest process"
cat >"$MOCKBIN/speedtest-env-probe" <<'MOCK'
#!/usr/bin/env bash
env >"$MOCK_DIR/speedtest.env"
exec "$(dirname "$0")/speedtest.real" "$@"
MOCK
mv "$MOCKBIN/speedtest" "$MOCKBIN/speedtest.real"
mv "$MOCKBIN/speedtest-env-probe" "$MOCKBIN/speedtest"
chmod +x "$MOCKBIN/speedtest"
run_agent "NETWORK_MONITOR_API_KEY=$TEST_KEY" "NETWORK_MONITOR_API_BASE_URL=https://env.example.test/api/network" --
check "exit 0" status_is 0
check "key absent from speedtest env" bash -c "! grep -q '$TEST_KEY' '$WORK/mock/speedtest.env'"
mv "$MOCKBIN/speedtest.real" "$MOCKBIN/speedtest"

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
