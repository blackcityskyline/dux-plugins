#!/bin/sh
set -eu

tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$tests_dir/.." && pwd)
dms_qml_root=${DMS_QML_ROOT:-/usr/share/quickshell/dms}
if [ -z "${DMS_QML_ROOT:-}" ] && [ ! -d "$dms_qml_root" ]; then
    dms_qml_root="$project_dir/dev-imports/qs"
fi
temp_root=${TMPDIR:-/tmp}
runtime_dir=$(mktemp -d "$temp_root/mihomo-widget-selftest.XXXXXX")

cleanup() {
    case "$runtime_dir" in
        "$temp_root"/mihomo-widget-selftest.*)
            rm -rf -- "$runtime_dir"
            ;;
    esac
}
trap cleanup EXIT HUP INT TERM

for required_command in cp grep ln quickshell timeout; do
    command -v "$required_command" >/dev/null || {
        printf 'Missing command: %s\n' "$required_command" >&2
        exit 1
    }
done

[ -d "$dms_qml_root" ] || {
    printf 'DMS QML root not found: %s\n' "$dms_qml_root" >&2
    exit 1
}

[ -x "$project_dir/plugin/mihomo-dms" ] || {
    printf 'Bundled Mihomo bridge is missing or not executable\n' >&2
    exit 1
}

# Embedded DMS resources are read-only; the test copy must accept our harness.
cp -a --no-preserve=mode "$dms_qml_root/." "$runtime_dir/"
cp "$tests_dir/WidgetSelfTest.qml" "$runtime_dir/WidgetSelfTest.qml"
cp "$tests_dir/SettingsSelfTest.qml" "$runtime_dir/SettingsSelfTest.qml"
ln -s "$project_dir/plugin" "$runtime_dir/plugin"

# Exercise the real bridge/Proc path without touching the user's subscription
# or privileged service controller.
mkdir -p "$runtime_dir/bin"
ln -s "$tests_dir/mock-mihomo-curl" "$runtime_dir/bin/curl"
ln -s "$tests_dir/mock-mihomo-pkexec" "$runtime_dir/bin/pkexec"
export PATH="$runtime_dir/bin:$PATH"
export MIHOMO_TEST_MODE_FILE="$runtime_dir/mode"
export XDG_STATE_HOME="$runtime_dir/state"
export MIHOMO_TEST_REQUEST_LOG="$runtime_dir/requests"
export MIHOMO_TEST_PROVIDER_RESULT=first-fails
printf '%s\n' rule > "$MIHOMO_TEST_MODE_FILE"

# Keep test animation timers independent of the host GPU frame clock, which
# can stall the windowless widget harness. Only the test processes use this
# renderer; the live DMS shell keeps its own rendering configuration.
if test_output=$(env QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software QSG_RENDER_LOOP=basic timeout 20s \
        quickshell --no-color -p "$runtime_dir/WidgetSelfTest.qml" 2>&1); then
    test_status=0
else
    test_status=$?
fi
printf '%s\n' "$test_output"

if [ "$test_status" -ne 0 ] || ! printf '%s\n' "$test_output" | grep -q 'MIHOMO_SELFTEST_PASS'; then
    printf 'Mihomo widget self-test failed\n' >&2
    exit 1
fi
[ "$(grep -c '^PUT .*providers/proxies/Alpha$' "$MIHOMO_TEST_REQUEST_LOG")" = 2 ]
[ "$(grep -c '^PUT .*providers/proxies/%D0%A0%D0%BE%D1%81%D1%81%D0%B8%D1%8F%20%2F%20beta%3F$' "$MIHOMO_TEST_REQUEST_LOG")" = 2 ]
[ "$(grep -c '^PATCH .*/configs$' "$MIHOMO_TEST_REQUEST_LOG")" = 2 ]
[ "$(cat "$MIHOMO_TEST_MODE_FILE")" = rule ]
[ ! -f "$MIHOMO_TEST_MODE_FILE.pkexec-called" ]

if settings_output=$(env QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software QSG_RENDER_LOOP=basic timeout 20s \
        quickshell --no-color -p "$runtime_dir/SettingsSelfTest.qml" 2>&1); then
    settings_status=0
else
    settings_status=$?
fi
printf '%s\n' "$settings_output"
if [ "$settings_status" -ne 0 ] || ! printf '%s\n' "$settings_output" | grep -q 'MIHOMO_SETTINGS_SELFTEST_PASS'; then
    printf 'Mihomo settings interaction test failed\n' >&2
    exit 1
fi
