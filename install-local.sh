#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ln -sfn "$project_dir/plugin" "$HOME/.config/DankMaterialShell/plugins/MihomoVpn"

legacy_helper="$HOME/.local/bin/mihomo-dms"
legacy_target="$project_dir/bin/mihomo-dms"
if [ -L "$legacy_helper" ] && [ "$(readlink "$legacy_helper")" = "$legacy_target" ]; then
    rm -- "$legacy_helper"
fi

mkdir -p "$project_dir/dev-imports"
ln -sfn /usr/share/quickshell/dms "$project_dir/dev-imports/qs"
systemctl --user restart dms.service
