#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/mihomo-bridge-selftest.XXXXXX")
trap 'rm -rf "$runtime_dir"' EXIT HUP INT TERM

mkdir -p "$runtime_dir/bin"
ln -s "$project_dir/tests/mock-mihomo-curl" "$runtime_dir/bin/curl"
ln -s "$project_dir/tests/mock-mihomo-pkexec" "$runtime_dir/bin/pkexec"
ln -s "$project_dir/tests/mock-systemctl" "$runtime_dir/bin/systemctl"
ln -s "$project_dir/tests/mock-miho" "$runtime_dir/bin/miho"
export PATH="$runtime_dir/bin:$PATH"
export XDG_STATE_HOME="$runtime_dir/state"
export MIHOMO_TEST_MODE_FILE="$runtime_dir/mode"
export MIHOMO_TEST_REQUEST_LOG="$runtime_dir/requests"
export MIHOMO_TEST_PKEXEC_LOG="$runtime_dir/pkexec-log"
export MIHOMO_TEST_UNIT_STATE="$runtime_dir/unit-state"
export MIHOMO_TEST_TUN_STATE="$runtime_dir/tun-state"
printf '%s\n' active > "$MIHOMO_TEST_UNIT_STATE"
printf '%s\n' false > "$MIHOMO_TEST_TUN_STATE"
helper="$project_dir/plugin/mihomo-dms"
saved_mode="$XDG_STATE_HOME/mihomo-dms/previous-mode"

printf '%s\n' global > "$MIHOMO_TEST_MODE_FILE"
result=$($helper set-vpn off)
printf '%s' "$result" | jq -e '.ok == true and .active == false and .mode == "direct"' >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = direct ]
[ "$(cat "$saved_mode")" = global ]

result=$($helper set-vpn off)
printf '%s' "$result" | jq -e '.ok == true and .active == false and .mode == "direct"' >/dev/null
[ "$(cat "$saved_mode")" = global ]
[ "$(rg -c '^PATCH .*/configs$' "$MIHOMO_TEST_REQUEST_LOG")" = 1 ]

result=$($helper set-vpn on)
printf '%s' "$result" | jq -e '.ok == true and .active == true and .mode == "global"' >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = global ]
result=$($helper set-vpn on)
printf '%s' "$result" | jq -e '.ok and .available and .active and .mode == "global"' >/dev/null
[ "$(rg -c '^PATCH .*/configs$' "$MIHOMO_TEST_REQUEST_LOG")" = 2 ]

$helper set-vpn off >/dev/null
status=$($helper status)
printf '%s' "$status" | jq -e '.active == false and .mode == "direct"' >/dev/null

for action in restart ensure-running; do
    if result=$($helper "$action"); then
        printf 'Obsolete service action still supported: %s\n' "$action" >&2
        exit 1
    fi
    printf '%s' "$result" | jq -e '.ok == false and .error == "Unknown action"' >/dev/null
done
for failure in http-error timeout no-change; do
    if result=$(MIHOMO_TEST_PATCH_RESULT="$failure" "$helper" set-vpn on); then
        printf 'Mode change failure reported success: %s\n' "$failure" >&2
        exit 1
    fi
    printf '%s' "$result" | jq -e '.ok == false and (.error | length > 0)' >/dev/null
    [ "$(cat "$MIHOMO_TEST_MODE_FILE")" = direct ]
done
for failure in unavailable malformed missing-mode unknown-mode; do
    if result=$(MIHOMO_TEST_CONFIG_RESULT="$failure" "$helper" set-vpn on); then
        printf 'Invalid controller state reported success: %s\n' "$failure" >&2
        exit 1
    fi
    printf '%s' "$result" | jq -e '.ok == false and .available == false' >/dev/null
done
# An unreachable API is a normal stopped state, not a broken bridge.
result=$(MIHOMO_TEST_CONFIG_RESULT=unavailable "$helper" status)
printf '%s' "$result" | jq -e '.available == false and .active == false and .serviceRunning == true' >/dev/null
for failure in malformed missing-mode unknown-mode; do
    if MIHOMO_TEST_CONFIG_RESULT="$failure" "$helper" status >/dev/null 2>&1; then
        printf '%s\n' 'Invalid config returned a successful status' >&2
        exit 1
    fi
done
# Confirmation failure must not be presented as success even if PATCH applied.
rm "$MIHOMO_TEST_MODE_FILE.patched"
if result=$(MIHOMO_TEST_CONFIG_RESULT=confirmation-fails "$helper" set-vpn on); then
    printf '%s\n' 'Unconfirmed mode change reported success' >&2
    exit 1
fi
printf '%s' "$result" | jq -e '.ok == false and .available == false' >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = global ]

# Fresh/invalid user state falls back to RULE, and later OFF/ON remembers RULE.
for cached in missing direct invalid; do
    printf '%s\n' direct > "$MIHOMO_TEST_MODE_FILE"
    if [ "$cached" = missing ]; then
        rm "$saved_mode"
    else
        printf '%s\n' "$cached" > "$saved_mode"
    fi
    result=$($helper set-vpn on)
    printf '%s' "$result" | jq -e '.ok and .mode == "rule"' >/dev/null
done
$helper set-vpn off >/dev/null
[ "$(cat "$saved_mode")" = rule ]
$helper set-vpn on >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = rule ]
printf '%s\n' 'not a directory' > "$runtime_dir/blocked-state"
if result=$(XDG_STATE_HOME="$runtime_dir/blocked-state" "$helper" set-vpn off 2>/dev/null); then
    printf '%s\n' 'Mode changed without remembering the previous mode' >&2
    exit 1
fi
printf '%s' "$result" | jq -e '.ok == false' >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = rule ]
$helper set-vpn off >/dev/null
request_count=$(wc -l < "$MIHOMO_TEST_REQUEST_LOG")
if result=$($helper set-vpn invalid); then exit 1; fi
printf '%s' "$result" | jq -e '.ok == false' >/dev/null
[ "$(wc -l < "$MIHOMO_TEST_REQUEST_LOG")" = "$request_count" ]
[ ! -f "$MIHOMO_TEST_PKEXEC_LOG" ]

result=$($helper status)
printf '%s' "$result" | jq -e '.httpProviders == ["Alpha", "Россия / beta?"]' >/dev/null
for providers in none empty malformed unavailable; do
    result=$(MIHOMO_TEST_PROVIDERS="$providers" "$helper" status)
    printf '%s' "$result" | jq -e '.httpProviders == [] and .mode == "direct"' >/dev/null
done

for provider in Alpha 'Россия / beta?'; do
    result=$("$helper" update-provider "$provider")
    printf '%s' "$result" | jq -e '.ok == true' >/dev/null
done
rg -F 'PUT http://127.0.0.1:9090/providers/proxies/%D0%A0%D0%BE%D1%81%D1%81%D0%B8%D1%8F%20%2F%20beta%3F' "$MIHOMO_TEST_REQUEST_LOG" >/dev/null
for provider in local default missing; do
    if result=$("$helper" update-provider "$provider"); then
        printf 'Non-HTTP provider updated: %s\n' "$provider" >&2
        exit 1
    fi
    printf '%s' "$result" | jq -e '.ok == false' >/dev/null
done
if rg 'PUT .*/(local|default|missing)$' "$MIHOMO_TEST_REQUEST_LOG"; then
    printf '%s\n' 'Rejected provider received a PUT' >&2
    exit 1
fi
for failure in http-error timeout; do
    if result=$(MIHOMO_TEST_PROVIDER_RESULT="$failure" "$helper" update-provider Alpha); then
        printf '%s\n' 'Provider failure was reported as success' >&2
        exit 1
    fi
    printf '%s' "$result" | jq -e '.ok == false and (.error | length > 0) and (tostring | contains("SECRET_SUBSCRIPTION_TOKEN") | not)' >/dev/null
done
if result=$(MIHOMO_TEST_PROVIDERS=unavailable "$helper" update-provider Alpha); then
    printf '%s\n' 'Unavailable API was reported as a successful update' >&2
    exit 1
fi
printf '%s' "$result" | jq -e '.ok == false' >/dev/null

# Service and TUN control. State files stand in for systemd and miho.
status=$($helper status)
printf '%s' "$status" | jq -e '.available == true and .serviceRunning == true and .tunEnabled == false' >/dev/null

result=$($helper service-stop)
printf '%s' "$result" | jq -e '.ok == true and .serviceRunning == false and .available == false' >/dev/null
[ "$(cat "$MIHOMO_TEST_UNIT_STATE")" = inactive ]
result=$($helper status)
printf '%s' "$result" | jq -e '.available == false and .serviceRunning == false and .active == false' >/dev/null

result=$($helper service-start)
printf '%s' "$result" | jq -e '.ok == true and .serviceRunning == true' >/dev/null
[ "$(cat "$MIHOMO_TEST_UNIT_STATE")" = active ]

result=$($helper tun-on)
printf '%s' "$result" | jq -e '.ok == true and .tunEnabled == true and .serviceRunning == true' >/dev/null
[ "$(cat "$MIHOMO_TEST_TUN_STATE")" = true ]
rg -q 'tun on$' "$MIHOMO_TEST_PKEXEC_LOG"
result=$($helper status)
printf '%s' "$result" | jq -e '.available == true and .tunEnabled == true' >/dev/null

result=$($helper tun-off)
printf '%s' "$result" | jq -e '.ok == true and .tunEnabled == false and .available == true' >/dev/null
[ "$(cat "$MIHOMO_TEST_TUN_STATE")" = false ]
[ "$(cat "$MIHOMO_TEST_UNIT_STATE")" = active ]
rg -q ' stop$' "$MIHOMO_TEST_PKEXEC_LOG"

# A root TUN daemon is outside systemd; the stop button must ask polkit once.
$helper tun-on >/dev/null
result=$($helper service-stop)
printf '%s' "$result" | jq -e '.ok == true and .serviceRunning == false' >/dev/null
[ "$(cat "$MIHOMO_TEST_TUN_STATE")" = false ]
$helper service-start >/dev/null

if result=$(MIHOMO_TEST_PKEXEC_RESULT=cancelled "$helper" tun-on); then
    printf '%s\n' 'A cancelled polkit prompt was reported as success' >&2
    exit 1
fi
printf '%s' "$result" | jq -e '.ok == false and (.error | contains("authentication"))' >/dev/null
[ "$(cat "$MIHOMO_TEST_TUN_STATE")" = false ]

printf '%s\n' inactive > "$MIHOMO_TEST_UNIT_STATE"
if result=$(MIHOMO_TEST_START_RESULT=failure "$helper" service-start); then
    printf '%s\n' 'A failed systemd start was reported as success' >&2
    exit 1
fi
printf '%s' "$result" | jq -e '.ok == false and (.error | length > 0)' >/dev/null
[ "$(cat "$MIHOMO_TEST_UNIT_STATE")" = inactive ]

printf '%s\n' 'Bridge self-test passed.'
