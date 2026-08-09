#!/bin/sh
# Detect pointer events that pass through the DMS widget to a normal window.
set -eu

duration=${1:-15}
case "$duration" in
    ''|*[!0-9]*)
        printf 'Duration must be a non-negative integer\n' >&2
        exit 2
        ;;
esac

tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$tests_dir/widget-test-helpers.sh"
temp_root=${TMPDIR:-/tmp}
runtime_dir=$(mktemp -d "$temp_root/mihomo-input-shield.XXXXXX")
probe_log="$runtime_dir/probe.log"
probe_pid=

cleanup() {
    if [ -n "$probe_pid" ]; then
        kill "$probe_pid" 2>/dev/null || true
        wait "$probe_pid" 2>/dev/null || true
    fi
    case "$runtime_dir" in
        "$temp_root"/mihomo-input-shield.*)
            rm -rf -- "$runtime_dir"
            ;;
    esac
}
trap cleanup EXIT HUP INT TERM

for required_command in cat cp dms grep kill mktemp quickshell sleep; do
    command -v "$required_command" >/dev/null || {
        printf 'Missing command: %s\n' "$required_command" >&2
        exit 1
    }
done

cp "$tests_dir/InputShieldProbe.qml" "$runtime_dir/InputShieldProbe.qml"
quickshell --no-color -p "$runtime_dir/InputShieldProbe.qml" >"$probe_log" 2>&1 &
probe_pid=$!

ready_attempt=0
while ! grep -q 'MIHOMO_INPUT_PROBE_READY' "$probe_log"; do
    if ! kill -0 "$probe_pid" 2>/dev/null; then
        cat "$probe_log" >&2
        exit 1
    fi
    ready_attempt=$((ready_attempt + 1))
    if [ "$ready_attempt" -ge 50 ]; then
        cat "$probe_log" >&2
        printf 'Input shield probe did not become ready\n' >&2
        exit 1
    fi
    sleep 0.1
done

initial_bar_state=$(dms ipc call bar status index 0 2>/dev/null || printf 'unknown')
restore_bar() {
    if [ "$initial_bar_state" = "hidden" ]; then
        dms ipc call bar hide index 0 >/dev/null 2>&1 || true
    fi
}
trap 'restore_bar; cleanup' EXIT HUP INT TERM

bar_output=$(dms ipc call bar reveal index 0 2>&1) || {
    printf '%s\n' "$bar_output" >&2
    exit 1
}
[ "$bar_output" = "BAR_SHOW_SUCCESS" ] || {
    printf 'Could not reveal DMS bar: %s\n' "$bar_output" >&2
    exit 1
}
widget_test_open_popout mihomoVpn
printf 'Mihomo popout is visible. Interact for %s seconds: click group headers and rows, then scroll long lists.\n' "$duration"
popup_closed=false
poll_count=$((duration * 4))
poll_index=0
while [ "$poll_index" -lt "$poll_count" ]; do
    sleep 0.25
    popup_state=$(dms ipc call widget status mihomoVpn 2>/dev/null || printf 'unknown')
    if [ "$popup_state" != "visible" ] && [ "$popup_closed" = "false" ]; then
        printf 'Input shield test detected that the popout closed early.\n' >&2
        popup_closed=true
    fi
    poll_index=$((poll_index + 1))
done

popup_state=$(dms ipc call widget status mihomoVpn 2>/dev/null || printf 'unknown')
if [ "$popup_state" != "visible" ]; then
    popup_closed=true
fi

kill "$probe_pid" 2>/dev/null || true
wait "$probe_pid" 2>/dev/null || true
probe_pid=

if grep -q 'MIHOMO_INPUT_LEAK' "$probe_log"; then
    printf 'Input shield test failed; events reached the window below DMS:\n' >&2
    grep 'MIHOMO_INPUT_LEAK' "$probe_log" >&2
    exit 1
fi

if [ "$popup_closed" = "true" ]; then
    printf 'Input shield test failed; the Mihomo popout did not remain visible.\n' >&2
    exit 1
fi

printf 'Input shield test passed: no click or wheel event reached the window below DMS.\n'
restore_bar
cleanup
trap - EXIT HUP INT TERM
