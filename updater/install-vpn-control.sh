#!/bin/sh
# Run once via the normal administrator authentication dialog.
set -eu
[ "$(id -u)" = 0 ] || { printf 'Administrator privileges required\n' >&2; exit 1; }
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -x "$project_dir/target/release/mihomo-vpn-control" ]
[ -f /etc/mihomo/config.yaml ]
install -d -m 0755 /usr/local/libexec
if [ -f /usr/local/libexec/mihomo-vpn-control ]; then
    install -m 0755 /usr/local/libexec/mihomo-vpn-control /usr/local/libexec/mihomo-vpn-control.previous
fi
install -m 0755 "$project_dir/target/release/mihomo-vpn-control" /usr/local/libexec/mihomo-vpn-control.new
mv /usr/local/libexec/mihomo-vpn-control.new /usr/local/libexec/mihomo-vpn-control
install -m 0644 "$project_dir/system/org.korbash.mihomo.control.policy" /usr/share/polkit-1/actions/org.korbash.mihomo.control.policy
install -m 0644 "$project_dir/system/49-mihomo-widget.rules" /etc/polkit-1/rules.d/49-mihomo-widget.rules
# The configured mode remains unchanged. OFF means DIRECT, not a dead controller.
/usr/bin/systemctl enable mihomo.service
/usr/local/libexec/mihomo-vpn-control ensure
