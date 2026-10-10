#!/bin/sh
# Optional adapter implementing the same contract as examples/action.sh.
. /usr/lib/tr3000-switch-wireguard/lib.sh
wg_load_settings && runtime_init || exit 1
case "$1" in
	on) vpn_on;;
	off) vpn_off;;
	check)
		case "$2" in
			on) guard_exists && interface_up && handshake_ok;;
			off) sync_dns off && ! guard_exists;;
			*) exit 2;;
		esac
		;;
	*) exit 2;;
esac
