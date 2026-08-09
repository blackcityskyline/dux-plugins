#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf 'Usage: %s <relative-x> <relative-y>\n' "$0" >&2
    exit 2
fi

tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
relative_x=$1
relative_y=$2
temp_root=${TMPDIR:-/tmp}
runtime_dir=$(mktemp -d "$temp_root/mihomo-pointer-probe.XXXXXX")
probe_pid=

cleanup() {
    if [ -n "$probe_pid" ]; then
        kill "$probe_pid" 2>/dev/null || true
    fi
    case "$runtime_dir" in
        "$temp_root"/mihomo-pointer-probe.*)
            rm -rf -- "$runtime_dir"
            ;;
    esac
}
trap cleanup EXIT HUP INT TERM

for required_command in cp quickshell sleep ydotool; do
    command -v "$required_command" >/dev/null || {
        printf 'Missing command: %s\n' "$required_command" >&2
        exit 1
    }
done

cp "$tests_dir/PointerProbe.qml" "$runtime_dir/PointerProbe.qml"
ydotool mousemove --absolute 0 0
sleep 0.2
quickshell --no-color -p "$runtime_dir/PointerProbe.qml" &
probe_pid=$!
sleep 1.3
printf 'Relative input: %s %s\n' "$relative_x" "$relative_y"
ydotool mousemove "$relative_x" "$relative_y"
wait "$probe_pid"
probe_pid=
cleanup
trap - EXIT HUP INT TERM
