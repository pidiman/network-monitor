#!/usr/bin/env bash
#
# Offline tests for the scheduling logic of src/network-speedtest.sh
# (--scheduled, slots, tolerance, state, lock).
#
# Same approach as test-agent.sh: fake curl + fake speedtest in PATH, temp
# config and state dir, the clock is fixed via NETWORK_MONITOR_TEST_NOW.
# Nothing is installed, no network access. Requires jq.
#
#   ./tests/test-scheduler.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="$ROOT/src/network-speedtest.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nm-sched-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MOCKBIN="$WORK/bin"
mkdir -p "$MOCKBIN"
cp "$ROOT/tests/fixtures/fake-curl" "$MOCKBIN/curl"
cp "$ROOT/tests/fixtures/fake-speedtest" "$MOCKBIN/speedtest"
chmod +x "$MOCKBIN/curl" "$MOCKBIN/speedtest"

TEST_KEY="nm_SCHEDKEY_do_not_print_1234567890"
T1300=1790773200            # 2026-09-30 13:00:00 UTC
at() { echo $(( T1300 + $1 )); }   # at SECONDS_AFTER_13:00

PASS=0
FAIL=0

write_config() {
    printf 'NETWORK_MONITOR_API_KEY=%s\nNETWORK_MONITOR_API_BASE_URL=https://api.example.test/api/network\n' \
        "$TEST_KEY" >"$WORK/agent.env"
    chmod 600 "$WORK/agent.env"
}

device() {
    # device ENABLED INTERVAL OFFSET  -> MOCK_CONFIG_BODY
    printf '{"device_key":"sched-test","enabled":%s,"interval_minutes":%s,"offset_minutes":%s}' "$1" "$2" "$3"
}

reset_state() { rm -rf "$WORK/state"; }

# run_agent NOW CONFIG_BODY [env...] -- [args...]
run_agent() {
    local now="$1" body="$2"; shift 2
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    rm -rf "$WORK/mock"; mkdir -p "$WORK/mock"
    OUTPUT="$(env -i HOME="$WORK" PATH="$MOCKBIN:/usr/bin:/bin" TMPDIR="$WORK" TZ=UTC \
        MOCK_DIR="$WORK/mock" NETWORK_MONITOR_CONFIG="$WORK/agent.env" \
        NETWORK_MONITOR_STATE_DIR="$WORK/state" NETWORK_MONITOR_TEST_NOW="$now" \
        MOCK_CONFIG_BODY="$body" \
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
status_is()     { [[ "$STATUS" -eq "$1" ]]; }
output_has()    { [[ "$OUTPUT" == *"$1"* ]]; }
ran()           { [[ -f "$WORK/mock/speedtest.args" ]]; }
not_ran()       { [[ ! -f "$WORK/mock/speedtest.args" ]]; }
posted()        { [[ -f "$WORK/mock/payload.json" ]]; }
last_slot_is()  { grep -qx "last_slot=$(( $1 / 60 ))" "$WORK/state/last_slot"; }
no_state()      { [[ ! -f "$WORK/state/last_slot" ]]; }

write_config

echo "1. interval 60 / offset 0, exactly in slot (13:00:00)"
reset_state
run_agent "$(at 0)" "$(device true 60 0)" -- --scheduled
check "exit 0" status_is 0
check "speedtest ran" ran
check "result posted" posted
check "slot shown" output_has "Slot:   2026-09-30 13:00 UTC"
check "last_slot = 13:00" last_slot_is "$(at 0)"

echo "2. interval 60 / offset 5, in slot (13:05:30)"
reset_state
run_agent "$(at 330)" "$(device true 60 5)" -- --scheduled
check "exit 0" status_is 0
check "speedtest ran" ran
check "last_slot = 13:05" last_slot_is "$(at 300)"

echo "3. outside the slot (13:30, offset 5) -> nothing"
reset_state
run_agent "$(at 1800)" "$(device true 60 5)" -- --scheduled
check "exit 0" status_is 0
check "no speedtest" not_ran
check "nothing posted" bash -c "! test -f '$WORK/mock/payload.json'"
check "next slot shown" output_has "next: 2026-09-30 14:05 UTC"
check "no state written" no_state

echo "4. enabled=false in slot -> nothing"
reset_state
run_agent "$(at 300)" "$(device false 60 5)" -- --scheduled
check "exit 0" status_is 0
check "no speedtest" not_ran
check "message" output_has "disabled on the server"

echo "5. invalid schedule -> explicit error, no speedtest"
# INTERVAL|OFFSET as raw JSON values ("60" = a string, not a number)
for combo in '60|90' '60|60' '60|-5' '0|0' '"60"|5' '60|null' '60.5|0' 'null|0'; do
    interval="${combo%%|*}" offset="${combo#*|}"
    reset_state
    run_agent "$(at 0)" "$(device true "$interval" "$offset")" -- --scheduled
    check "interval=$interval offset=$offset -> exit 6" status_is 6
    check "interval=$interval offset=$offset -> no speedtest" not_ran
done
run_agent "$(at 0)" "$(device true 60 90)" -- --scheduled
check "message names the problem" output_has "offset_minutes (90) must be less than interval_minutes (60)"
run_agent "$(at 0)" "$(device false 60 90)" -- --scheduled
check "disabled + invalid -> exit 0 (nothing would run anyway)" status_is 0

echo "6. slot tolerance (offset 5, tolerance 10 min)"
reset_state
run_agent "$(at $(( 300 + 9*60 + 59 )))" "$(device true 60 5)" -- --scheduled
check "13:14:59 (9 min late) -> runs" ran
reset_state
run_agent "$(at $(( 300 + 10*60 )))" "$(device true 60 5)" -- --scheduled
check "13:15:00 (10 min late) -> nothing" not_ran
reset_state
run_agent "$(at 299)" "$(device true 60 5)" -- --scheduled
check "13:04:59 (before slot) -> nothing" not_ran

echo "7. reboot: previous slot measured, boot 13:04, timer 13:06 -> runs"
reset_state
run_agent "$(at $(( 300 - 3600 )))" "$(device true 60 5)" -- --scheduled   # 12:05 slot
check "12:05 measured" last_slot_is "$(at $(( 300 - 3600 )))"
run_agent "$(at 360)" "$(device true 60 5)" -- --scheduled
check "13:06 -> runs" ran
check "last_slot = 13:05" last_slot_is "$(at 300)"
check "started 1 min ago" output_has "started 1 min ago"

echo "8. boot at 13:45 -> old 13:05 slot is not caught up"
reset_state
run_agent "$(at 2700)" "$(device true 60 5)" -- --scheduled
check "exit 0" status_is 0
check "no speedtest" not_ran

echo "9. same slot a second time -> nothing"
reset_state
run_agent "$(at 300)" "$(device true 60 5)" -- --scheduled
check "13:05 runs" ran
run_agent "$(at 600)" "$(device true 60 5)" -- --scheduled
check "13:10 same slot -> exit 0" status_is 0
check "13:10 same slot -> no speedtest" not_ran
check "message" output_has "already measured"
run_agent "$(at 300)" "$(device true 60 5)" -- --scheduled
check "13:05 again (timer fired twice) -> no speedtest" not_ran
run_agent "$(at 3900)" "$(device true 60 5)" -- --scheduled
check "14:05 next slot -> runs" ran

echo "9b. offset moved to an earlier, already covered time -> no double test"
reset_state
run_agent "$(at 600)" "$(device true 60 10)" -- --scheduled
check "13:10 (offset 10) runs" ran
run_agent "$(at 720)" "$(device true 60 5)" -- --scheduled
check "13:12 after change to offset 5 -> no speedtest" not_ran

echo "10. concurrent invocation"
reset_state
mkdir -p "$WORK/mock-bg"
env -i HOME="$WORK" PATH="$MOCKBIN:/usr/bin:/bin" TMPDIR="$WORK" TZ=UTC \
    MOCK_DIR="$WORK/mock-bg" NETWORK_MONITOR_CONFIG="$WORK/agent.env" \
    NETWORK_MONITOR_STATE_DIR="$WORK/state" NETWORK_MONITOR_TEST_NOW="$(at 300)" \
    MOCK_CONFIG_BODY="$(device true 60 5)" MOCK_SPEEDTEST_SLEEP=3 \
    bash "$AGENT" --scheduled >"$WORK/bg.out" 2>&1 &
BG=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "$WORK/mock-bg/speedtest.args" ]] && break
    sleep 0.3
done
run_agent "$(at 300)" "$(device true 60 5)" -- --scheduled
check "2nd scheduled while 1st runs -> exit 0" status_is 0
check "2nd scheduled -> skipped" output_has "in progress"
check "2nd scheduled -> no speedtest" not_ran
run_agent "$(at 300)" "$(device true 60 5)" --
check "manual while scheduled runs -> exit 7" status_is 7
check "manual -> no speedtest" not_ran
wait "$BG"; BG_STATUS=$?
OUTPUT="$(cat "$WORK/bg.out")"
check "1st run completed" [ "$BG_STATUS" -eq 0 ]
check "exactly one speedtest" [ "$(wc -l <"$WORK/mock-bg/speedtest.args")" -eq 1 ]
run_agent "$(at 300)" "$(device true 60 5)" -- --scheduled
check "after 1st finished: slot already measured" output_has "already measured"

echo "10b. stale lock (crashed run) does not block forever"
reset_state
mkdir -p "$WORK/state/agent.lock.d" && echo 999999 >"$WORK/state/agent.lock.d/pid"
run_agent "$(at 300)" "$(device true 60 5)" -- --scheduled
check "runs" ran

echo "11. manual run still works (ignores interval/offset, no state)"
reset_state
run_agent "$(at 1800)" "$(device true 60 5)" --
check "exit 0" status_is 0
check "speedtest ran at 13:30" ran
check "stored" output_has "Result stored successfully."
check "manual run does not record a slot" no_state
run_agent "$(at 1800)" "$(device false 60 5)" --
check "manual + disabled -> no speedtest" not_ran
run_agent "$(at 1800)" "$(device true 60 90)" --
check "manual ignores invalid schedule" ran

echo "12. --check still works"
run_agent "$(at 1800)" "$(device true 60 5)" -- --check
check "exit 0" status_is 0
check "auth" output_has "Authentication successful"
check "next slot" output_has "Next slot: 2026-09-30 14:05 UTC"
check "no speedtest" not_ran
run_agent "$(at 1800)" "$(device true 60 90)" -- --check
check "invalid schedule reported" output_has "Schedule: INVALID"
run_agent "$(at 300)" "$(device true 60 5)" -- --check
check "--check exactly at slot start -> next is the following slot" output_has "Next slot: 2026-09-30 14:05 UTC"
check "invalid schedule: --check still exit 0" status_is 0
run_agent "$(at 300)" "$(device true 60 5)" -- --check --scheduled
check "--check + --scheduled rejected" status_is 1

echo "13. env config (Docker) + --scheduled"
reset_state
mv "$WORK/agent.env" "$WORK/agent.env.off"
run_agent "$(at 300)" "$(device true 60 5)" \
    "NETWORK_MONITOR_API_KEY=$TEST_KEY" "NETWORK_MONITOR_API_BASE_URL=https://env.example.test/api/network" -- --scheduled
check "exit 0" status_is 0
check "ran" ran
check "env URL used" grep -q 'https://env.example.test/api/network/speedtests' "$WORK/mock/curl.argv"
mv "$WORK/agent.env.off" "$WORK/agent.env"

echo "14. agent.env (Linux) + --scheduled"
reset_state
run_agent "$(at 300)" "$(device true 60 5)" -- --scheduled
check "exit 0" status_is 0
check "file URL used" grep -q 'https://api.example.test/api/network/speedtests' "$WORK/mock/curl.argv"

echo "15. failures"
reset_state
run_agent "$(at 300)" "$(device true 60 5)" MOCK_SPEEDTEST_FAIL=1 -- --scheduled
check "speedtest failure -> exit 4" status_is 4
check "speedtest failure -> slot not recorded (retry at next wake)" no_state
run_agent "$(at 600)" "$(device true 60 5)" -- --scheduled
check "retry 5 min later in the window -> runs" ran
reset_state
run_agent "$(at 300)" "$(device true 60 5)" MOCK_POST_STATUS=500 -- --scheduled
check "POST failure -> exit 5" status_is 5
check "POST failure -> slot recorded (no 2nd speedtest)" last_slot_is "$(at 300)"
reset_state
mkdir -p "$WORK/state" && chmod 500 "$WORK/state"
run_agent "$(at 300)" "$(device true 60 5)" -- --scheduled
check "state dir not writable -> exit 2" status_is 2
check "state dir not writable -> no speedtest" not_ran
chmod 700 "$WORK/state"

echo "16. other intervals"
reset_state
run_agent "$(at 3600)" "$(device true 120 0)" -- --scheduled     # 14:00 UTC: 14*60 % 120 = 0
check "interval 120: 14:00 UTC -> runs" ran
run_agent "$(at 0)" "$(device true 120 0)" -- --scheduled        # 13:00 UTC: odd hour
check "interval 120: 13:00 UTC -> nothing" not_ran
reset_state
run_agent "$(at 420)" "$(device true 5 2)" -- --scheduled        # 13:07 slot
check "interval 5 / offset 2 at 13:07 -> runs" ran
run_agent "$(at 600)" "$(device true 5 2)" -- --scheduled        # 13:10, slot 13:07, window 5
check "interval 5: 13:10 is 3 min into slot 13:07 (already measured)" output_has "already measured"
run_agent "$(at 720)" "$(device true 5 2)" -- --scheduled        # 13:12 new slot
check "interval 5: 13:12 new slot -> runs" ran
reset_state
run_agent "$(at 0)" "$(device true 1440 0)" -- --scheduled       # 13:00 UTC, daily at 00:00 UTC
check "interval 1440: 13:00 UTC -> nothing" not_ran

echo "17. state file never contains the API key"
reset_state
run_agent "$(at 300)" "$(device true 60 5)" -- --scheduled
check "state written" test -f "$WORK/state/last_slot"
check "no key in state" bash -c "! grep -rq '$TEST_KEY' '$WORK/state'"
check "state files not group/world readable" bash -c "[ -z \"\$(find '$WORK/state' -perm -004 -o -perm -040 | head -1)\" ]"
check "state dir mode 700" bash -c "[ \"\$(stat -c %a '$WORK/state' 2>/dev/null || stat -f %Lp '$WORK/state')\" = 700 ]"

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
