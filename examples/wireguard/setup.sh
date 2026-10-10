#!/bin/sh
# Run on the router. Accepts a UCI data file, never executes its contents.
set -eu
[ "$(id -u)" = 0 ] && [ -f /etc/openwrt_release ] || { echo 'Run on OpenWrt as root.' >&2; exit 1; }
[ "$#" = 1 ] && [ -f "$1" ] || { echo 'Usage: sh examples/wireguard/setup.sh /root/tr3000-switch-wg' >&2; exit 1; }
example_dir=$(cd "$(dirname "$0")" && pwd)
. "$example_dir/lib.sh"
die() { printf '%s\n' "$*" >&2; exit 1; }
for cmd in uci ubus jsonfilter nft fw4 wg ip; do command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"; done
[ -f /lib/netifd/proto/wireguard.sh ] || die 'WireGuard netifd protocol handler is missing.'
[ -f /etc/config/tr3000-switch ] || die 'Run install.sh first.'
[ "$(uci -q get tr3000-switch.main.enabled)" = 0 ] || die 'Disable/stop the switch service before setup.'
[ ! -e /etc/config/tr3000-switch-wireguard ] || die 'WireGuard example is already configured; restore it first (README).'
for package in network firewall dhcp tr3000-switch; do
	[ -z "$(uci -q changes "$package")" ] || die "Commit/revert existing UCI changes in $package first."
done
for item in network.trwg network.trswitch_peer network.trswitch_v4a network.trswitch_v4b network.trswitch_v6a network.trswitch_v6b firewall.trswitch_zone firewall.trswitch_forward; do
	if uci -q get "$item" >/dev/null; then die "$item already exists. Restore the previous setup first (README)."; fi
done
[ -z "$(uci -q get 'dhcp.@dnsmasq[0].server' || :)" ] || die 'Existing dnsmasq server rules found; standard single-dnsmasq setup is required. See README.'
[ "$(uci -q show dhcp | awk '/=dnsmasq$/ {n++} END {print n+0}')" = 1 ] || die 'Exactly one dnsmasq instance is required.'
[ "$(uci -q get 'firewall.@defaults[0]' || :)" = defaults ] || die 'Firewall defaults section is missing.'

settings_dir=$(cd "$(dirname "$1")" && pwd)
settings_name=$(basename "$1")
case "$settings_name" in *[!a-zA-Z0-9_-]*|'') die 'Use a UCI filename with letters/digits/_/- only (no .conf suffix).';; esac
get_setting() { uci -c "$settings_dir" -q get "$settings_name.client.$1" 2>/dev/null || printf '%s\n' "${2-}"; }
private_key=$(get_setting private_key)
public_key=$(get_setting public_key)
preshared_key=$(get_setting preshared_key)
addresses=$(get_setting addresses)
endpoint=$(get_setting endpoint_host)
port=$(get_setting endpoint_port 51820)
mtu=$(get_setting mtu 1420)
lan_device=$(get_setting lan_device br-lan)
lan_zone=$(get_setting lan_zone lan)
tunlink=$(get_setting tunlink wan)
dns_list=$(get_setting dns '1.1.1.1 9.9.9.9')
valid_key() { printf '%s\n' "$1" | awk 'length($0)==44 && /^[A-Za-z0-9+\/]+=$/ {ok=1} END {exit !ok}'; }
valid_key "$private_key" && valid_key "$public_key" || die 'Replace the private/public key placeholders with WireGuard keys.'
printf '%s\n' "$private_key" | wg pubkey >/dev/null || die 'Invalid private key.'
[ -z "$preshared_key" ] || valid_key "$preshared_key" || die 'Invalid preshared key.'
valid_ip_literal "$endpoint" || die 'endpoint_host must be a numeric IPv4 address (resolve the VPN hostname beforehand).'
[ "$endpoint" != 203.0.113.10 ] || die 'Replace the documentation-only endpoint 203.0.113.10.'
case "$port:$mtu" in *[!0-9:]*) die 'port/mtu must be numeric';; esac
[ -n "$port" ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die 'Invalid port.'
[ -n "$mtu" ] && [ "$mtu" -ge 576 ] && [ "$mtu" -le 1500 ] || die 'Invalid MTU.'
valid_device "$lan_device" && [ "$lan_device" != lo ] && [ "$lan_device" != trwg ] || die 'Invalid LAN device.'
ip link show dev "$lan_device" >/dev/null 2>&1 || die "LAN device does not exist: $lan_device"
case "$lan_zone:$tunlink" in *[!a-zA-Z0-9_:-]*|'') die 'Invalid LAN zone/uplink name';; esac
[ -n "$lan_zone" ] && [ -n "$tunlink" ] || die 'LAN zone and uplink cannot be empty.'
[ "$(uci -q get "network.$tunlink" || :)" = interface ] || die "Unknown logical uplink: $tunlink"
uci -q show firewall | awk -F= -v wanted="'$lan_zone'" '/\.name=/ && $2==wanted {found=1} END {exit !found}' || die "Unknown firewall LAN zone: $lan_zone"
has4=0; has6=0
for address in $addresses; do
	case "$address" in */*) ;; *) die 'Each tunnel address must include its prefix, e.g. 10.0.0.2/32';; esac
	ip_part=${address%/*}; prefix=${address##*/}
	case "$prefix" in ''|*[!0-9]*) die 'Invalid address prefix';; esac
	case "$ip_part" in
		*:*)
			case "$ip_part" in *[!a-fA-F0-9:]*) die 'Invalid IPv6 tunnel address';; esac
			[ "$prefix" -le 128 ] || die 'Invalid IPv6 prefix'
			has6=1;;
		*) valid_ip_literal "$ip_part" && [ "$prefix" -le 32 ] || die 'Invalid IPv4 tunnel address'; has4=1;;
	esac
done
[ "$has4" = 1 ] || die 'At least one IPv4 tunnel address is required.'
[ "$has6" = 0 ] || [ "$mtu" -ge 1280 ] || die 'IPv6 requires MTU >= 1280.'
[ -n "$dns_list" ] || die 'At least one VPN DNS server is required.'
for dns in $dns_list; do valid_ip_literal "$dns" || die 'DNS servers must be IPv4 addresses.'; done

# Back up committed files, including any unrelated user configuration, before editing.
umask 077
backup=$(mktemp -d /root/tr3000-switch-backup.XXXXXX)
for package in network firewall dhcp tr3000-switch; do cp "/etc/config/$package" "$backup/$package"; done
printf '%s\n' "$backup" > /etc/tr3000-switch/backup-path
rollback() {
	trap - EXIT HUP INT TERM
	uci -q revert tr3000-switch-wireguard || :
	rm -f /etc/config/tr3000-switch-wireguard
	for package in network firewall dhcp tr3000-switch; do
		uci -q revert "$package" || :
		cp "$backup/$package" "/etc/config/$package"
	done
	ubus call network reload >/dev/null 2>&1 || :
	/etc/init.d/firewall restart >/dev/null 2>&1 || :
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || :
	echo "Setup failed; original configuration restored. Backup: $backup" >&2
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM

uci set network.trwg=interface
uci set network.trwg.proto=wireguard
uci set network.trwg.auto=0
uci set "network.trwg.private_key=$private_key"
uci set "network.trwg.mtu=$mtu"
uci set "network.trwg.fwmark=$WG_MARK"
uci set "network.trwg.tunlink=$tunlink"
uci set network.trwg.nohostroute=0
uci set network.trwg.peerdns=0
for address in $addresses; do uci add_list "network.trwg.addresses=$address"; done
uci set network.trswitch_peer=wireguard_trwg
uci set "network.trswitch_peer.public_key=$public_key"
[ -z "$preshared_key" ] || uci set "network.trswitch_peer.preshared_key=$preshared_key"
uci set "network.trswitch_peer.endpoint_host=$endpoint"
uci set "network.trswitch_peer.endpoint_port=$port"
uci set network.trswitch_peer.persistent_keepalive=25
uci set network.trswitch_peer.route_allowed_ips=0
uci add_list network.trswitch_peer.allowed_ips=0.0.0.0/0
add_route() {
	uci set "network.$1=$2"
	uci set "network.$1.interface=trwg"
	uci set "network.$1.target=$3"
}
# /1 routes win over WAN's /0 regardless of its metric. LAN and the endpoint's
# host route remain more specific. netifd removes these when trwg goes down.
add_route trswitch_v4a route 0.0.0.0/1
add_route trswitch_v4b route 128.0.0.0/1
if [ "$has6" = 1 ]; then
	uci add_list network.trswitch_peer.allowed_ips=::/0
	add_route trswitch_v6a route6 ::/1
	add_route trswitch_v6b route6 8000::/1
fi
uci set firewall.trswitch_zone=zone
uci set firewall.trswitch_zone.name=trwg
uci add_list firewall.trswitch_zone.network=trwg
uci set firewall.trswitch_zone.input=REJECT
uci set firewall.trswitch_zone.output=ACCEPT
uci set firewall.trswitch_zone.forward=REJECT
uci set firewall.trswitch_zone.masq=1
uci set "firewall.trswitch_zone.masq6=$has6"
uci set firewall.trswitch_zone.mtu_fix=1
uci set firewall.trswitch_forward=forwarding
uci set "firewall.trswitch_forward.src=$lan_zone"
uci set firewall.trswitch_forward.dest=trwg
# Offloaded connections bypass normal forward hooks; disable both in both modes.
uci set 'firewall.@defaults[0].flow_offloading=0'
uci set 'firewall.@defaults[0].flow_offloading_hw=0'
uci set 'dhcp.@dnsmasq[0].noresolv=0'
uci set "dhcp.@dnsmasq[0].resolvfile=$RUN_DIR/resolv.conf"
uci set 'dhcp.@dnsmasq[0].localuse=1'
touch /etc/config/tr3000-switch-wireguard
uci set tr3000-switch-wireguard.main=wireguard
uci set tr3000-switch-wireguard.main.wg_interface=trwg
uci set "tr3000-switch-wireguard.main.lan_device=$lan_device"
for dns in $dns_list; do uci add_list "tr3000-switch-wireguard.main.vpn_dns=$dns"; done
uci set tr3000-switch-wireguard.main.wg_ready=1
uci set tr3000-switch.main.action=/etc/tr3000-switch/wireguard.sh
uci set tr3000-switch.main.check_interval=30
uci set tr3000-switch.main.action_timeout=30
for package in network firewall dhcp tr3000-switch tr3000-switch-wireguard; do uci commit "$package"; done
mkdir -p /usr/lib/tr3000-switch-wireguard
cp "$example_dir/lib.sh" /usr/lib/tr3000-switch-wireguard/lib.sh
cp "$example_dir/action.sh" /etc/tr3000-switch/wireguard.sh
chmod 644 /usr/lib/tr3000-switch-wireguard/lib.sh
chmod 700 /etc/tr3000-switch/wireguard.sh
chmod 600 /etc/config/network
runtime_init
sync_dns off
fw4 check >/dev/null
ubus call network reload >/dev/null
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
trap - EXIT HUP INT TERM
printf '\nConfigured example adapter; trwg is still down. Backup: %s\nEnable the switch service as described in README.md.\n' "$backup"
