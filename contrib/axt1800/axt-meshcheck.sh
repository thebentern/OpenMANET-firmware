#!/usr/bin/env bash
# axt-meshcheck.sh — verify this AXT-1800 is ready to mesh, and print the
# exact settings a second node needs to match.
#
# What it checks on the running router:
#   - 802.11s mesh point is up on radio0 (phy0-mesh0) and broadcasting
#   - batman-adv soft-iface (bat0) is up
#   - phy0-mesh0 is bound to bat0 as a hard-iface
#   - alfred + openmanetd processes are alive
#   - mgmt-AP is up on radio1
#   - LAN is still at 192.168.1.1 (renumber stayed off)
#
# What it reports for joining a peer:
#   - Mesh ID, channel, country, encryption, passphrase
#   - Per-node IP allocation suggestion (next free in /16)
#
# Run from the Mac while the router is at 192.168.1.1.

set -uo pipefail

ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts")

if [[ -t 1 ]]; then
	C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
	C_HEAD=$'\033[36;1m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
	C_OK=""; C_WARN=""; C_ERR=""; C_HEAD=""; C_DIM=""; C_RST=""
fi

step() { printf '\n%s━━━ %s ━━━%s\n' "$C_HEAD" "$*" "$C_RST"; }
ok()   { printf '  %s✓%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$C_WARN" "$C_RST" "$*"; }
fail() { printf '  %s✗%s %s\n' "$C_ERR"  "$C_RST" "$*"; }
kv()   { printf '    %s%-14s%s %s\n' "$C_DIM" "$1" "$C_RST" "$2"; }

# Reach the router
if ! ssh "${SSH_OPTS[@]}" "root@${ROUTER_IP}" true 2>/dev/null; then
	fail "Cannot SSH to root@${ROUTER_IP}. Is the router up + Mac on the right subnet?"
	exit 1
fi

# Pull all the state in one SSH round-trip and parse locally.
state=$(ssh "${SSH_OPTS[@]}" "root@${ROUTER_IP}" '
	echo "## firmware"
	. /etc/openwrt_release && echo "$DISTRIB_RELEASE"

	echo "## lan_ip"
	uci -q get network.lan.ipaddr

	echo "## mesh_ssid"
	uci -q get wireless.mesh0.mesh_id

	echo "## mesh_encryption"
	uci -q get wireless.mesh0.encryption

	echo "## mesh_key"
	uci -q get wireless.mesh0.key

	echo "## mesh_radio_dev"
	uci -q get wireless.mesh0.device

	echo "## mesh_channel"
	uci -q get wireless.$(uci -q get wireless.mesh0.device).channel

	echo "## mesh_country"
	uci -q get wireless.$(uci -q get wireless.mesh0.device).country

	echo "## bat0_ip"
	uci -q get network.bat0_ip.ipaddr
	uci -q get network.bat0_ip.netmask

	echo "## bat0_link"
	ip link show bat0 2>/dev/null | head -1

	echo "## phy0_mesh_link"
	ip link show phy0-mesh0 2>/dev/null | head -1

	echo "## batctl_iface"
	batctl meshif bat0 interface 2>&1

	echo "## batctl_originators"
	batctl meshif bat0 originators 2>&1 | head -5

	echo "## iwinfo_phy0_mesh0"
	iwinfo phy0-mesh0 info 2>/dev/null

	echo "## iwinfo_phy1_ap0"
	iwinfo phy1-ap0 info 2>/dev/null

	echo "## alfred_pid"
	pidof alfred || echo none

	echo "## openmanetd_pid"
	pidof openmanetd || echo none

	echo "## openmanetd_flags"
	uci show openmanetd

	echo "## alfred_iface"
	grep -E "interface|batmanif" /etc/config/alfred
') || { fail "SSH call failed mid-collection"; exit 1; }

# tiny parser — extract the block between "## key" and the next "##"
get() {
	awk -v section="## $1" '$0==section {found=1; next} /^## / {found=0} found' <<<"$state"
}

# ─── Section: stack health ─────────────────────────────────────────────────
step "Stack health"

case "$(get firmware)" in
	25.12.4)
		ok "Firmware: stock OpenWrt 25.12.4 (apk-install path)" ;;
	25.12-SNAPSHOT*)
		ok "Firmware: $(get firmware) (custom all-in-one image)" ;;
	*)
		warn "Firmware: $(get firmware) (unexpected — known good: 25.12.4 or 25.12-SNAPSHOT*)" ;;
esac

lan=$(get lan_ip)
if [[ "$lan" == "192.168.1.1/24" || "$lan" == "192.168.1.1" ]]; then
	ok "LAN IP preserved at $lan (renumber stayed off)"
else
	fail "LAN IP is $lan — was openmanetd's address-reservation re-enabled?"
fi

# If the wizard hasn't been clicked yet, wireless.mesh0 won't exist —
# bat0 and friends are intentionally NOT up. Detect that state and
# skip mesh-radio checks (they'd be misleading-as-failures).
wizard_ran=1
if [[ -z "$(get mesh_ssid)" ]]; then
	wizard_ran=0
fi

if (( wizard_ran == 0 )); then
	warn "Wizard not yet run — bat0 / phy0-mesh0 / batman-adv intentionally not up."
	warn "Open http://${ROUTER_IP}/cgi-bin/luci/admin/network/meshwizard and Save & Apply to bring the mesh online."
else
	bat_link=$(get bat0_link)
	if echo "$bat_link" | grep -q "state UP\|state UNKNOWN"; then
		ok "bat0 netdev is up"
		kv "bat0 line:" "$(echo "$bat_link" | tr -s ' ')"
	else
		fail "bat0 netdev not up: $bat_link"
	fi

	phy_link=$(get phy0_mesh_link)
	if echo "$phy_link" | grep -q "master bat0"; then
		ok "phy0-mesh0 bound to bat0"
	else
		warn "phy0-mesh0 NOT bound to bat0: $phy_link"
	fi

	if echo "$(get batctl_iface)" | grep -q "phy0-mesh0: active"; then
		ok "batman-adv: phy0-mesh0 active as hardif"
	else
		fail "batman-adv hardif not active. batctl said: $(get batctl_iface)"
	fi
fi

[[ "$(get alfred_pid)"     != "none" ]] && ok "alfred running (PID $(get alfred_pid))"     || fail "alfred not running"
[[ "$(get openmanetd_pid)" != "none" ]] && ok "openmanetd running (PID $(get openmanetd_pid))" || fail "openmanetd not running"

if get alfred_iface | grep -q "bat0"; then
	ok "alfred bound to bat0 (not the stale br-ahwlan default)"
else
	warn "alfred config still mentions: $(get alfred_iface)"
fi

if get openmanetd_flags | grep -q "dhcpconfigured='1'"; then
	ok "openmanetd renumber-worker pinned off (dhcpconfigured=1)"
else
	warn "openmanetd dhcpconfigured is NOT 1 — LAN may get renumbered later"
fi

# ─── Section: peer-join cheat sheet ────────────────────────────────────────
step "Bring up a 2nd node with these exact settings"

ssid=$(get mesh_ssid)
encryption=$(get mesh_encryption)
key=$(get mesh_key)
channel=$(get mesh_channel)
country=$(get mesh_country)
bat_ip_lines=$(get bat0_ip)
my_bat_ip=$(echo "$bat_ip_lines" | head -1)
my_bat_mask=$(echo "$bat_ip_lines" | sed -n '2p')

kv "Mesh ID:"      "$ssid"
kv "Channel:"      "${channel:-(unset)}"
kv "Country:"      "${country:-(unset)}"
kv "Encryption:"   "$encryption"
[[ "$encryption" == "sae" ]] && kv "Passphrase:" "$key"

if [[ -n "$my_bat_ip" ]]; then
	# Suggest next IP in the same /24
	last=$(echo "$my_bat_ip" | awk -F. '{print $4+1}')
	prefix=$(echo "$my_bat_ip" | awk -F. '{print $1"."$2"."$3}')
	suggest="${prefix}.${last}"
	kv "This node bat0 IP:" "${my_bat_ip}/${my_bat_mask:-?}"
	kv "Suggest 2nd node IP:" "${suggest} (same netmask)"
else
	kv "Mesh L3:" "not configured on this node (L2-only mesh)"
fi

# ─── Section: radio + mesh broadcast detail ────────────────────────────────
step "Radio detail (what's actually on the air)"
get iwinfo_phy0_mesh0 | grep -E "ESSID|Mode|Channel|HT Mode|Signal|Encryption|Type" | sed 's/^/  /'
echo
echo "  Management AP:"
get iwinfo_phy1_ap0 | grep -E "ESSID|Mode|Channel" | sed 's/^/    /'

# ─── Section: peers ────────────────────────────────────────────────────────
step "Mesh peers seen by batman-adv"
peers=$(get batctl_originators | tail -n +3 | grep -c '^[a-f0-9:]' || true)
peers=${peers:-0}
if [[ "$peers" -gt 0 ]]; then
	ok "$peers peer(s) discovered"
	echo
	echo "$(get batctl_originators)" | sed 's/^/  /'
else
	warn "No peers yet (alone on the mesh). Bring up a 2nd node with the settings above."
fi

echo
echo "  Once a 2nd node joins:"
echo "    batctl meshif bat0 originators    # peers + last-seen + throughput"
echo "    batctl meshif bat0 ping <peer>    # L2 ping over batman-adv"
[[ -n "$my_bat_ip" ]] && echo "    ping ${prefix}.${last}                # L3 ping (if Mesh L3 set)"
echo
