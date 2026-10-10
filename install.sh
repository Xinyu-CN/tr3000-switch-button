#!/bin/sh
set -eu
cd "$(dirname "$0")"

[ "$(id -u)" = 0 ] || { echo 'Run on the router as root.' >&2; exit 1; }
[ -f /etc/openwrt_release ] || { echo 'Requires OpenWrt / ImmortalWrt.' >&2; exit 1; }
board=$(cat /tmp/sysinfo/board_name 2>/dev/null || :)
case "$board" in cudy,tr3000*) ;; *) echo "Unsupported board: $board" >&2; exit 1;; esac
for cmd in uci ubus jsonfilter timeout; do
	command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
if [ -x /etc/init.d/slide-switch ] && /etc/init.d/slide-switch enabled; then
	echo 'Disable the existing slide-switch service before installing.' >&2; exit 1
fi
if [ -e /etc/rc.button/BTN_0 ]; then
	echo '/etc/rc.button/BTN_0 already exists. Review/disable its action first to avoid conflicts.' >&2; exit 1
fi
if [ -x /etc/init.d/tr3000-switch ]; then /etc/init.d/tr3000-switch stop; fi
mkdir -p /usr/lib/tr3000-switch /etc/tr3000-switch /etc/hotplug.d/button
cp files/usr/lib/tr3000-switch/core.sh /usr/lib/tr3000-switch/core.sh
cp files/usr/sbin/tr3000-switch /usr/sbin/tr3000-switch
cp files/etc/init.d/tr3000-switch /etc/init.d/tr3000-switch
cp files/etc/hotplug.d/button/95-tr3000-switch /etc/hotplug.d/button/95-tr3000-switch
chmod 755 /usr/sbin/tr3000-switch /etc/init.d/tr3000-switch /etc/hotplug.d/button/95-tr3000-switch
chmod 644 /usr/lib/tr3000-switch/core.sh
if [ ! -f /etc/config/tr3000-switch ]; then
	cp files/etc/config/tr3000-switch /etc/config/tr3000-switch
	chmod 600 /etc/config/tr3000-switch
fi
if [ ! -f /etc/tr3000-switch/action.sh ]; then
	cp examples/action.sh /etc/tr3000-switch/action.sh
	chmod 700 /etc/tr3000-switch/action.sh
fi
echo 'Installed. Edit /etc/tr3000-switch/action.sh and enable the service (README.md).'
