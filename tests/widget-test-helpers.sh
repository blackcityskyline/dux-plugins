#!/bin/sh
# Shared helpers for opening and verifying the Mihomo widget popout.

widget_test_wait_for_state() {
    widget_test_id=$1
    widget_test_expected_state=$2
    widget_test_attempt=0

    while [ "$widget_test_attempt" -lt 50 ]; do
        widget_test_state=$(dms ipc call widget status "$widget_test_id" 2>/dev/null || true)
        if [ "$widget_test_state" = "$widget_test_expected_state" ]; then
            return 0
        fi
        widget_test_attempt=$((widget_test_attempt + 1))
        sleep 0.1
    done

    printf 'Widget %s did not reach state %s; last state: %s\n' \
        "$widget_test_id" "$widget_test_expected_state" "${widget_test_state:-unknown}" >&2
    return 1
}

widget_test_toggle_popout() {
    widget_test_id=$1
    widget_test_toggle_output=$(dms ipc call widget toggle "$widget_test_id" 2>&1) || {
        printf '%s\n' "$widget_test_toggle_output" >&2
        return 1
    }
    case "$widget_test_toggle_output" in
        "WIDGET_TOGGLE_SUCCESS: $widget_test_id") return 0 ;;
        *)
            printf 'Could not toggle widget %s: %s\n' \
                "$widget_test_id" "$widget_test_toggle_output" >&2
            return 1
            ;;
    esac
}

widget_test_open_popout() {
    widget_test_id=$1
    widget_test_state=$(dms ipc call widget status "$widget_test_id" 2>/dev/null || true)

    case "$widget_test_state" in
        visible)
            widget_test_toggle_popout "$widget_test_id"
            widget_test_wait_for_state "$widget_test_id" hidden
            ;;
        hidden) ;;
        *)
            printf 'Could not read widget %s state: %s\n' \
                "$widget_test_id" "${widget_test_state:-unknown}" >&2
            return 1
            ;;
    esac

    widget_test_toggle_popout "$widget_test_id"
    widget_test_wait_for_state "$widget_test_id" visible
}
