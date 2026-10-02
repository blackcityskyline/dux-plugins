#!/bin/sh
# Implement the repository tasks exposed by the root Makefile.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
plugin_id=mihomoVpn
dms_config_dir=${DMS_CONFIG_DIR:-"${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell"}
plugin_dir="$dms_config_dir/plugins"
plugin_link="$plugin_dir/$plugin_id"
plugin_source="$project_dir/plugin"
plugin_meta="$plugin_dir/$plugin_id.meta"
legacy_plugin_link="$plugin_dir/MihomoVpn"
dms_bin=${DMS_BIN:-dms}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

read_meta_value() {
    requested_key=$1
    [ -f "$plugin_meta" ] || return 1
    while IFS='=' read -r meta_key meta_value || [ -n "$meta_key" ]; do
        if [ "$meta_key" = "$requested_key" ]; then
            printf '%s\n' "$meta_value"
            return 0
        fi
    done < "$plugin_meta"
    return 1
}

resolve_store_source() {
    store_repodir=$(read_meta_value repodir) || return 1
    store_subpath=$(read_meta_value path) || return 1

    case "$store_repodir" in
        ''|/*|*..*) return 1 ;;
    esac
    case "$store_subpath" in
        /*|*..*) return 1 ;;
    esac

    store_source="$plugin_dir/.repos/$store_repodir"
    if [ -n "$store_subpath" ]; then
        store_source="$store_source/$store_subpath"
    fi
    [ -f "$store_source/plugin.json" ] || return 1
    store_id=$(jq -r '.id // empty' "$store_source/plugin.json")
    [ "$store_id" = "$plugin_id" ] || return 1
    printf '%s\n' "$store_source"
}

ensure_tooling_link() {
    dms_qml_root=${DMS_QML_ROOT:-/usr/share/quickshell/dms}
    if [ -z "${DMS_QML_ROOT:-}" ] && [ ! -d "$dms_qml_root" ] && [ -d "$project_dir/dev-imports/qs" ]; then
        dms_qml_root=$(readlink -f "$project_dir/dev-imports/qs")
    fi
    [ -d "$dms_qml_root" ] || die "DMS QML sources are missing at $dms_qml_root; set DMS_QML_ROOT to the running shell's QML directory"
    mkdir -p "$project_dir/dev-imports"
    ln -sfn "$dms_qml_root" "$project_dir/dev-imports/qs"
    export DMS_QML_ROOT="$dms_qml_root"
}

replace_plugin_link() {
    link_target=$1
    link_label=$2

    mkdir -p "$plugin_dir"
    if [ -e "$plugin_link" ] && [ ! -L "$plugin_link" ]; then
        die "$plugin_link exists and is not a symbolic link"
    fi
    ln -sfn "$link_target" "$plugin_link"
    linked_source=$(readlink -f "$plugin_link" 2>/dev/null || true)
    expected_source=$(readlink -f "$link_target" 2>/dev/null || true)
    [ -n "$linked_source" ] && [ "$linked_source" = "$expected_source" ] \
        || die "Failed to activate $link_label source"
}

clean_legacy_links() {
    if [ -L "$legacy_plugin_link" ] && [ "$(readlink "$legacy_plugin_link")" = "$plugin_source" ]; then
        rm -- "$legacy_plugin_link"
    fi

    legacy_helper="$HOME/.local/bin/mihomo-dms"
    legacy_target="$project_dir/bin/mihomo-dms"
    if [ -L "$legacy_helper" ] && [ "$(readlink "$legacy_helper")" = "$legacy_target" ]; then
        rm -- "$legacy_helper"
    fi
}

switch_to_local() {
    [ -f "$plugin_source/plugin.json" ] || die "Local plugin manifest is missing"
    replace_plugin_link "$plugin_source" local
    clean_legacy_links
}

switch_to_store() {
    store_source=$(resolve_store_source) \
        || die "Registry checkout is unavailable. Run: dms plugins install $plugin_id"
    replace_plugin_link "$store_source" store
}

run_checks() {
    require_command git
    require_command jq
    require_command qmllint
    require_command quickshell
    require_command sh
    require_command timeout
    ensure_tooling_link

    (
        cd "$project_dir"
        qmllint -I dev-imports -I /usr/lib/qt6/qml \
            plugin/MihomoVpnWidget.qml plugin/MihomoVpnSettings.qml
        jq -e --arg id "$plugin_id" '
            .id == $id
            and (.version | type == "string"
                and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[a-zA-Z0-9.-]+)?(\\+[a-zA-Z0-9.-]+)?$"))
            and (.component | type == "string" and length > 0)
        ' plugin/plugin.json >/dev/null
        for shell_script in scripts/plugin-workflow.sh plugin/mihomo-dms tests/*.sh; do
            sh -n "$shell_script"
        done
        git diff --check
        ./tests/run-bridge-selftest.sh
        ./tests/run-component-selftest.sh
    )
    printf 'Checks passed.\n'
}

plugin_is_loaded() {
    plugin_status=$(timeout 3s "$dms_bin" ipc call plugin-scan status "$plugin_id" 2>/dev/null || true)
    case "$plugin_status" in
        loaded*) return 0 ;;
        *) return 1 ;;
    esac
}

wait_for_plugin() {
    wait_attempt=0
    wait_limit=$1
    while [ "$wait_attempt" -lt "$wait_limit" ]; do
        if plugin_is_loaded; then
            return 0
        fi
        wait_attempt=$((wait_attempt + 1))
        sleep 0.1
    done
    return 1
}

reload_plugin() {
    require_command "$dms_bin"
    require_command timeout

    # Reload alone reuses the old manifest (including the settings URL).
    # Rescan only this plugin before busting the widget component cache.
    rescan_output=$(timeout 5s "$dms_bin" ipc call plugin-scan rescan "$plugin_id" 2>&1) \
        || die "Could not rescan $plugin_id: $rescan_output"
    case "$rescan_output" in
        "RESCAN_TRIGGERED: $plugin_id") ;;
        *) die "Could not rescan $plugin_id: $rescan_output" ;;
    esac
    wait_for_plugin 30 || die "Plugin did not load after manifest rescan"

    reload_output=''
    if reload_output=$(timeout 5s "$dms_bin" ipc call plugin-scan reload "$plugin_id" 2>&1); then
        printf '%s\n' "$reload_output"
        if wait_for_plugin 30; then
            printf 'Plugin reloaded without restarting DMS.\n'
            return 0
        fi
    elif [ -n "$reload_output" ]; then
        printf '%s\n' "$reload_output" >&2
    fi

    printf 'Hot reload failed; restarting dms.service once.\n' >&2
    require_command systemctl
    systemctl --user restart dms.service
    if wait_for_plugin 150; then
        printf 'Plugin loaded after the DMS fallback restart.\n'
        return 0
    fi
    die "Plugin did not load after the fallback restart"
}

print_status() {
    active_target=$(readlink "$plugin_link" 2>/dev/null || true)
    active_source=$(readlink -f "$plugin_link" 2>/dev/null || true)
    local_source=$(readlink -f "$plugin_source" 2>/dev/null || true)
    store_source=$(resolve_store_source 2>/dev/null || true)
    resolved_store_source=''
    if [ -n "$store_source" ]; then
        resolved_store_source=$(readlink -f "$store_source" 2>/dev/null || true)
    fi

    if [ -z "$active_source" ]; then
        active_mode=missing
    elif [ "$active_source" = "$local_source" ]; then
        active_mode=local
    elif [ -n "$resolved_store_source" ] && [ "$active_source" = "$resolved_store_source" ]; then
        active_mode=store
    else
        active_mode=custom
    fi

    active_version=unknown
    if [ -f "$active_source/plugin.json" ]; then
        active_version=$(jq -r '.version // "unknown"' "$active_source/plugin.json")
    fi
    source_revision=$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || printf 'unknown')
    if [ -n "$(git -C "$project_dir" status --porcelain 2>/dev/null || true)" ]; then
        source_revision="$source_revision-dirty"
    fi

    printf 'Mode: %s\n' "$active_mode"
    printf 'Link: %s -> %s\n' "$plugin_link" "${active_target:-missing}"
    printf 'Version: %s\n' "$active_version"
    printf 'Project revision: %s\n' "$source_revision"
}

show_usage() {
    cat <<'EOF'
This is an internal workflow helper. Run `make help` from the repository root.
EOF
}

command_name=${1:-help}
case "$command_name" in
    test)
        run_checks
        ;;
    local|reload)
        run_checks
        switch_to_local
        reload_plugin
        print_status
        ;;
    store)
        switch_to_store
        reload_plugin
        print_status
        ;;
    update-store)
        run_checks
        require_command dms
        dms plugins update "$plugin_id"
        switch_to_store
        reload_plugin
        print_status
        ;;
    status)
        require_command git
        require_command jq
        print_status
        ;;
    help|-h|--help)
        show_usage
        ;;
    *)
        show_usage >&2
        exit 2
        ;;
esac
