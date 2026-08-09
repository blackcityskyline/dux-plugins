#!/bin/sh
set -eu

wait_seconds=${1:-15}
output_path=${2:-"/tmp/mihomo-widget-interaction-$(date +%Y%m%d-%H%M%S).png"}

case "$wait_seconds" in
    ''|*[!0-9]*)
        printf 'Wait time must be a non-negative integer\n' >&2
        exit 2
        ;;
esac

case "$output_path" in
    /*) ;;
    *) output_path="$(pwd)/$output_path" ;;
esac
mkdir -p "$(dirname -- "$output_path")"

for required_command in dms niri sleep; do
    command -v "$required_command" >/dev/null || {
        printf 'Missing command: %s\n' "$required_command" >&2
        exit 1
    }
done

initial_bar_state=$(dms ipc call bar status index 0 2>/dev/null || printf 'unknown')
restore_bar() {
    if [ "$initial_bar_state" = "hidden" ]; then
        dms ipc call bar hide index 0 >/dev/null 2>&1 || true
    fi
}
trap restore_bar EXIT HUP INT TERM

dms ipc call bar reveal index 0 >/dev/null
dms ipc call widget toggle mihomoVpn >/dev/null
printf 'Widget opened. Interact with both groups; capture in %s seconds.\n' "$wait_seconds"
sleep "$wait_seconds"

# DMS' screenshot service dismisses popouts. Niri captures the layer directly.
niri msg action screenshot-screen \
    --show-pointer false \
    --path "$output_path" >/dev/null
printf 'Captured: %s\n' "$output_path"
