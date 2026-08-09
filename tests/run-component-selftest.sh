#!/bin/sh
set -eu

tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$tests_dir/.." && pwd)
dms_qml_root=${DMS_QML_ROOT:-/usr/share/quickshell/dms}
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

cp -a "$dms_qml_root/." "$runtime_dir/"
cp "$tests_dir/WidgetSelfTest.qml" "$runtime_dir/WidgetSelfTest.qml"
ln -s "$project_dir/plugin" "$runtime_dir/plugin"

if test_output=$(env QT_QPA_PLATFORM=wayland timeout 20s \
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
