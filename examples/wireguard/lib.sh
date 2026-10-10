#!/bin/sh
# Optional WireGuard adapter, independent of the switch daemon.
. /usr/lib/tr3000-switch/core.sh
RUN_DIR=/tmp/tr3000-switch-wireguard
AUTO_RESOLV=/tmp/resolv.conf.d/resolv.conf.auto
NFT_TABLE=tr3000_switch
WG_MARK=0x3000
cfg() { uci -q get "tr3000-switch-wireguard.main.$1" 2>/dev/null || printf '%s\n' "${2-}"; }
valid_device() {
	case "$1" in ''|*[!a-zA-Z0-9_.-]*) return 1;; esac
	[ "${#1}" -le 15 ]
}
wg_load_settings() {
    WG_IF=$(cfg wg_interface trwg)
    LAN_DEV=$(cfg lan_device br-lan)
    VPN_DNS=$(cfg vpn_dns '1.1.1.1 9.9.9.9')
    HANDSHAKE_TIMEOUT=$(cfg handshake_timeout 20)
    valid_device "$WG_IF" && valid_device "$LAN_DEV" || return 1
    [ "$WG_IF" != "$LAN_DEV" ] && [ "$LAN_DEV" != lo ] || return 1
    case "$HANDSHAKE_TIMEOUT" in ''|*[!0-9]*) return 1;; esac
    [ "$HANDSHAKE_TIMEOUT" -ge 1 ] && [ "$HANDSHAKE_TIMEOUT" -le 120 ] || return 1
    [ -n "$VPN_DNS" ] || return 1
    local dns
    for dns in $VPN_DNS; do valid_ip_literal "$dns" || return 1; done
}

valid_ip_literal() {
	# IPv4 only here; numeric endpoints avoid DNS bootstrap outside the VPN.
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{ for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i+0>255) exit 1 }
	'
}

guard_rules() {
	# One nft transaction: replacing rules never opens an intermediate gap.
	# WG_MARK is applied by the kernel WireGuard socket, not to client traffic.
	cat <<EOF
add table inet $NFT_TABLE
flush table inet $NFT_TABLE
add chain inet $NFT_TABLE forward { type filter hook forward priority -10; policy drop; }
add rule inet $NFT_TABLE forward oifname { "$WG_IF", "$LAN_DEV" } accept
add chain inet $NFT_TABLE output { type filter hook output priority -10; policy drop; }
add rule inet $NFT_TABLE output oifname { "lo", "$WG_IF", "$LAN_DEV" } accept
add rule inet $NFT_TABLE output meta mark $WG_MARK meta l4proto udp accept
add rule inet $NFT_TABLE output meta nfproto ipv4 udp sport 68 udp dport 67 accept
add rule inet $NFT_TABLE output ip6 daddr { fe80::/10, ff02::/16 } udp sport 546 udp dport 547 accept
add rule inet $NFT_TABLE output ip6 daddr { fe80::/10, ff02::/16 } icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
EOF
}

guard_on() { guard_rules | nft -f -; }
guard_exists() { nft list table inet "$NFT_TABLE" >/dev/null 2>&1; }
guard_off() {
	if guard_exists; then nft delete table inet "$NFT_TABLE"; fi
}

sync_dns() {
	local state="$1" tmp dns
	tmp=$(mktemp "$RUN_DIR/.dns.XXXXXX") || return 1
	if [ "$state" = on ]; then
		for dns in $VPN_DNS; do printf 'nameserver %s\n' "$dns"; done > "$tmp"
	elif [ -r "$AUTO_RESOLV" ]; then
		cat "$AUTO_RESOLV" > "$tmp"
	else
		printf '# Waiting for uplink DNS\n' > "$tmp"
	fi
	chmod 644 "$tmp"
	if cmp -s "$tmp" "$RUN_DIR/resolv.conf"; then
		rm -f "$tmp"
	else
		mv -f "$tmp" "$RUN_DIR/resolv.conf"
	fi
}

interface_up() {
	[ "$(ubus call "network.interface.$WG_IF" status 2>/dev/null | jsonfilter -e '@.up')" = true ]
}

handshake_ok() {
	local now
	now=$(date +%s)
	wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v now="$now" '
		$2>0 && now-$2>=0 && now-$2<180 { ok=1 }
		END { exit !ok }
	'
}

vpn_preflight() {
	[ "$(cfg wg_ready 0)" = 1 ] || { fail 'run the WireGuard example setup.sh first'; return 1; }
	[ "$(uci -q get "network.$WG_IF.proto")" = wireguard ] || return 1
	[ "$(uci -q get "network.$WG_IF.fwmark")" = "$WG_MARK" ] || { fail 'WireGuard fwmark changed'; return 1; }
	[ "$(uci -q get 'firewall.@defaults[0].flow_offloading')" != 1 ] || { fail 'disable software flow offloading'; return 1; }
	[ "$(uci -q get 'firewall.@defaults[0].flow_offloading_hw')" != 1 ] || { fail 'disable hardware flow offloading'; return 1; }
}

vpn_on() {
	local waited=0
	vpn_preflight || return 1
	guard_on || { fail 'could not install VPN traffic guard'; return 1; }
	write_value vpn_owned 1
	sync_dns on || return 1
	if ! interface_up; then ifup "$WG_IF" || return 1; fi
	while [ "$waited" -lt "$HANDSHAKE_TIMEOUT" ]; do
		if interface_up && handshake_ok; then return 0; fi
		sleep 1
		waited=$((waited + 1))
	done
	fail 'WireGuard has no recent handshake; WAN remains blocked, will retry'
}

vpn_off() {
	local waited=0
	# Do not interfere with an unconfigured interface when only custom mode is used.
	if [ "$(cfg wg_ready 0)" = 1 ] || [ -f "$RUN_DIR/vpn_owned" ]; then
		ifdown "$WG_IF" || return 1
		while ip link show dev "$WG_IF" >/dev/null 2>&1; do
			[ "$waited" -lt 10 ] || { fail 'WireGuard interface still exists; guard retained'; return 1; }
			sleep 1
			waited=$((waited + 1))
		done
		sync_dns off || return 1
	fi
	guard_off || return 1
	rm -f "$RUN_DIR/vpn_owned"
}
