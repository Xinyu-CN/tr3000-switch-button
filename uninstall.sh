#!/bin/sh
set -eu
[ "$(id -u)" = 0 ] && [ -f /etc/openwrt_release ] || { echo 'Run on OpenWrt as root.' >&2; exit 1; }
# This intentionally does not blindly restore entire network/firewall snapshots.
# They may contain changes made since installation.
if [ -x /etc/init.d/tr3000-switch ]; then
	/etc/init.d/tr3000-switch disable
	/etc/init.d/tr3000-switch stop
	/usr/sbin/tr3000-switch run off
fi
if [ -f /etc/config/tr3000-switch-wireguard ]; then
	echo 'VPN setup is present. Restore the saved configuration first (README.md), then rerun uninstall.sh.' >&2
	exit 1
fi
rm -f /usr/sbin/tr3000-switch /usr/lib/tr3000-switch/core.sh
rm -f /etc/init.d/tr3000-switch /etc/hotplug.d/button/95-tr3000-switch
echo 'Program removed. /etc/config/tr3000-switch and custom scripts are retained.'
