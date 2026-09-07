#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/mihomo-bridge-selftest.XXXXXX")
trap 'rm -rf "$runtime_dir"' EXIT HUP INT TERM

mkdir -p "$runtime_dir/bin"
ln -s "$project_dir/tests/mock-mihomo-curl" "$runtime_dir/bin/curl"
ln -s "$project_dir/tests/mock-mihomo-pkexec" "$runtime_dir/bin/pkexec"
export PATH="$runtime_dir/bin:$PATH"
export XDG_STATE_HOME="$runtime_dir/state"
export MIHOMO_TEST_MODE_FILE="$runtime_dir/mode"
helper="$project_dir/plugin/mihomo-dms"

printf '%s\n' global > "$MIHOMO_TEST_MODE_FILE"
result=$($helper set-vpn off)
printf '%s' "$result" | jq -e '.ok == true and .active == false and .mode == "direct"' >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = direct ]
[ "$(cat "$MIHOMO_TEST_MODE_FILE.saved")" = global ]

result=$($helper set-vpn off)
printf '%s' "$result" | jq -e '.ok == true and .active == false and .mode == "direct"' >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE.saved")" = global ]

result=$($helper set-vpn on)
printf '%s' "$result" | jq -e '.ok == true and .active == true and .mode == "global"' >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = global ]

$helper set-vpn off >/dev/null
status=$($helper status)
printf '%s' "$status" | jq -e '.active == false and .mode == "direct"' >/dev/null

for action in restart ensure-running; do
    result=$($helper "$action")
    printf '%s' "$result" | jq -e '.ok == true and .active == false and .mode == "direct"' >/dev/null
done
if result=$(MIHOMO_TEST_CONTROL_FAIL=1 "$helper" set-vpn on); then
    printf '%s\n' 'Control failure was reported as success' >&2
    exit 1
fi
printf '%s' "$result" | jq -e '.ok == false and .error == "Test control failure"' >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = direct ]

result=$($helper subscription-status)
printf '%s' "$result" | jq -e '.phase == "error" and .code == "device_limit"' >/dev/null
if result=$($helper refresh-subscription); then
    printf '%s\n' 'Subscription failure was reported as success' >&2
    exit 1
fi
printf '%s' "$result" | jq -e '.phase == "error" and .error != ""' >/dev/null

printf '%s\n' 'Bridge self-test passed.'
