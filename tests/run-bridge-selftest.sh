#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/mihomo-bridge-selftest.XXXXXX")
trap 'rm -rf "$runtime_dir"' EXIT HUP INT TERM

mkdir -p "$runtime_dir/bin"
ln -s "$project_dir/tests/mock-mihomo-curl" "$runtime_dir/bin/curl"
export PATH="$runtime_dir/bin:$PATH"
export XDG_STATE_HOME="$runtime_dir/state"
export MIHOMO_TEST_MODE_FILE="$runtime_dir/mode"
helper="$project_dir/plugin/mihomo-dms"

printf '%s\n' global > "$MIHOMO_TEST_MODE_FILE"
result=$($helper set-vpn off)
printf '%s' "$result" | jq -e '.ok == true and .active == false and .mode == "direct"' >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = direct ]
[ "$(cat "$XDG_STATE_HOME/mihomo-dms/previous-mode")" = global ]

result=$($helper set-vpn off)
printf '%s' "$result" | jq -e '.ok == true and .active == false and .mode == "direct"' >/dev/null
[ "$(cat "$XDG_STATE_HOME/mihomo-dms/previous-mode")" = global ]

result=$($helper set-vpn on)
printf '%s' "$result" | jq -e '.ok == true and .active == true and .mode == "global"' >/dev/null
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = global ]

$helper set-vpn off >/dev/null
status=$($helper status)
printf '%s' "$status" | jq -e '.active == false and .mode == "direct"' >/dev/null

printf '%s\n' 'Bridge self-test passed.'
