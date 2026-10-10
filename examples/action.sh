#!/bin/sh
# Adapter contract: $1 = on/off. Must be safe to repeat. Exit 0 on success.
case "$1" in
	on)
		logger -t tr3000-switch-action 'ON: replace this with your own action'
		# Example: /etc/init.d/adblock start
		;;
	off)
		logger -t tr3000-switch-action 'OFF: replace this with your own action'
		# Example: /etc/init.d/adblock stop
		;;
	*) exit 2;;
esac
