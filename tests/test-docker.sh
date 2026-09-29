#!/usr/bin/env bash
#
# Docker image tests (local architecture).
#
# Builds the image, then runs it against a mock API container on a private
# Docker network with a fake speedtest mounted over the Ookla binary, so no
# real speedtest and no real API are used.
#
#   ./tests/test-docker.sh                 # build + test
#   IMAGE=ghcr.io/pidiman/network-monitor:latest SKIP_BUILD=1 ./tests/test-docker.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-network-monitor:test}"
MOCK_IMAGE="${MOCK_IMAGE:-python:3-alpine}"
SUFFIX="$$"
NET="nm-test-net-$SUFFIX"
MOCK="nm-test-api-$SUFFIX"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nm-docker-test.XXXXXX")"
KEY="nm_docker_test_key_1234567890"
DISABLED_KEY="nm_docker_disabled_key_12345"
URL="http://$MOCK:3077/api/network"

PASS=0
FAIL=0

cleanup() {
    docker rm -f "$MOCK" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

check() {
    local name="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$name"
        printf '%s\n' "$OUTPUT" | sed 's/^/        | /'
    fi
}
status_is()  { [[ "$STATUS" -eq "$1" ]]; }
output_has() { [[ "$OUTPUT" == *"$1"* ]]; }
no_key()     { [[ "$OUTPUT" != *"$KEY"* && "$OUTPUT" != *"$DISABLED_KEY"* ]]; }

# run_agent [docker run args...] -- [agent args...]
run_agent() {
    local -a dargs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do dargs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    OUTPUT="$(docker run --rm --network "$NET" \
        -v "$ROOT/tests/fixtures/fake-speedtest:/usr/bin/speedtest:ro" \
        ${dargs[@]+"${dargs[@]}"} "$IMAGE" "$@" 2>&1)"
    STATUS=$?
}

if [[ -z "${SKIP_BUILD:-}" ]]; then
    echo "Building $IMAGE ..."
    docker build -q -f "$ROOT/docker/Dockerfile" -t "$IMAGE" "$ROOT" >/dev/null || exit 1
fi

docker network create "$NET" >/dev/null
chmod 777 "$WORK"
docker run -d --name "$MOCK" --network "$NET" -e MOCK_DATA_DIR=/data \
    -v "$ROOT/tests/fixtures/mock_api.py:/mock_api.py:ro" -v "$WORK:/data" \
    "$MOCK_IMAGE" python /mock_api.py >/dev/null || exit 1
sleep 2

echo "1. image basics"
OUTPUT="$(docker run --rm "$IMAGE" --version 2>&1)"; STATUS=$?
check "--version" output_has "network-speedtest "
OUTPUT="$(docker run --rm --entrypoint id "$IMAGE" -u 2>&1)"
check "runs as non-root" [ "$OUTPUT" != "0" ]
OUTPUT="$(docker run --rm --entrypoint speedtest "$IMAGE" --version 2>&1)"
check "official Ookla CLI in image" output_has "Speedtest by Ookla"
OUTPUT="$(docker image inspect "$IMAGE" --format '{{json .Config.Env}}')"
check "no API key baked into image" bash -c "! grep -q NETWORK_MONITOR_API_KEY <<<'$OUTPUT'"

echo "2. one-shot run: GET config -> speedtest -> POST"
run_agent -e "NETWORK_MONITOR_API_KEY=$KEY" -e "NETWORK_MONITOR_API_BASE_URL=$URL" --
check "exit 0" status_is 0
check "device" output_has "Device: docker-test"
check "download" output_has "Download: 907.94 Mbps"
check "stored" output_has "Result stored successfully."
check "id" output_has "ID: 7"
check "key not in log" no_key
check "payload received" test -s "$WORK/received.json"
check "payload download_mbps" bash -c "[ \"\$(jq -r .download_mbps '$WORK/received.json')\" = 907.94 ]"
check "payload result_id" bash -c "[ \"\$(jq -r .result_id '$WORK/received.json')\" = 45ff5e54-7260-4bb3-acd2-93b3e7a80f49 ]"

echo "3. same result again -> duplicate = success"
run_agent -e "NETWORK_MONITOR_API_KEY=$KEY" -e "NETWORK_MONITOR_API_BASE_URL=$URL" --
check "exit 0" status_is 0
check "duplicate" output_has "duplicate"

echo "4. device disabled"
rm -f "$WORK/received.json"
run_agent -e "NETWORK_MONITOR_API_KEY=$DISABLED_KEY" -e "NETWORK_MONITOR_API_BASE_URL=$URL" --
check "exit 0" status_is 0
check "skipped" output_has "disabled"
check "nothing posted" test ! -e "$WORK/received.json"

echo "5. invalid API key"
run_agent -e "NETWORK_MONITOR_API_KEY=nm_wrong_key_1234567890" -e "NETWORK_MONITOR_API_BASE_URL=$URL" --
check "exit 3" status_is 3
check "message" output_has "HTTP 401"

echo "6. no API key"
run_agent --
check "exit 2" status_is 2
check "message" output_has "NETWORK_MONITOR_API_KEY"

echo "7. empty API key (unset compose variable)"
run_agent -e "NETWORK_MONITOR_API_KEY=" --
check "exit 2" status_is 2

echo "8. --check"
run_agent -e "NETWORK_MONITOR_API_KEY=$KEY" -e "NETWORK_MONITOR_API_BASE_URL=$URL" -- --check
check "exit 0" status_is 0
check "auth ok" output_has "Authentication successful"

echo "9. env file (like compose env_file)"
printf 'NETWORK_MONITOR_API_KEY=%s\nNETWORK_MONITOR_API_BASE_URL=%s\n' "$KEY" "$URL" >"$WORK/test.env"
run_agent --env-file "$WORK/test.env" -- --check
check "exit 0" status_is 0
check "key not in log" no_key

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
