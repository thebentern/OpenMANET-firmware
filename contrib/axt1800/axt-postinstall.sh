#!/usr/bin/env bash
# Post-install hardening for AXT-1800 + OpenMANET on stock OpenWrt 25.12.4.
#
# Runs AFTER axt-bisect.sh has placed wizard / alfred / openmanetd / tailscale
# on the device. Two jobs:
#
# 1) Tell openmanetd to skip its destructive address-reservation worker.
#    That worker, ~5 minutes after openmanetd starts, otherwise:
#      - allocates a 10.41.x.x static IP for the box from the mesh pool
#      - REWRITES network.lan to use that IP (we lose 192.168.1.1)
#      - REPLACES dhcp.lan
#      - reloads hostapd
#    The toggle is `openmanetd.config.dhcpconfigured`. When it's '1' the worker
#    short-circuits at the IsDHCPConfigured check in
#    internal/mgmt/address_reservation.go.
#
# 2) Stand up a 2.4 GHz management AP on radio1 (which stock 25.12.4 ships
#    disabled=1). This gives the operator a wireless management path that
#    survives any future LAN-side surgery — mesh radio (radio0) stays
#    dedicated to 802.11s, radio1 stays as the admin door.

set -uo pipefail

ROUTER_IP="192.168.1.1"
ROUTER_USER="root"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts")

MGMT_SSID="${MGMT_SSID:-openmanet-mgmt}"
MGMT_KEY="${MGMT_KEY:-openmanet-mgmt-please-change}"
MGMT_CHANNEL="${MGMT_CHANNEL:-6}"        # mid 2.4 GHz, decent overlap-free
MGMT_COUNTRY="${MGMT_COUNTRY:-US}"

log() { printf '\n=== %s ===\n' "$*"; }
warn() { printf '\n!!! %s !!!\n' "$*" >&2; }

ssh_router() {
	ssh "${SSH_OPTS[@]}" "${ROUTER_USER}@${ROUTER_IP}" "$@"
}

# --- Sanity ----------------------------------------------------------------

log "Checking we can reach the router"
if ! ssh_router true; then
	warn "Cannot SSH to ${ROUTER_USER}@${ROUTER_IP}. Run axt-bisect.sh first."
	exit 1
fi

# --- Step 1: pin openmanetd's "already configured" flags -------------------

log "Telling openmanetd that network/dhcp/mesh are already configured"
ssh_router '
	if [ ! -f /etc/config/openmanetd ]; then
		echo "  No /etc/config/openmanetd yet — openmanetd package not installed?"
		exit 1
	fi

	echo "  Before:"
	uci show openmanetd | sed "s/^/    /"

	uci set openmanetd.config.dhcpconfigured=1
	uci set openmanetd.config.roipconfigured=1
	uci set openmanetd.config.batmesh1configured=1
	uci commit openmanetd

	echo "  After:"
	uci show openmanetd | sed "s/^/    /"
'

log "Restarting openmanetd so it re-reads the flags before the worker fires"
ssh_router '/etc/init.d/openmanetd restart' || warn "openmanetd restart returned non-zero (it sometimes does — check pidof openmanetd next)"

sleep 3
ssh_router 'echo "  openmanetd PID: $(pidof openmanetd || echo none)"'

# --- Step 2: enable radio1 as a 2.4 GHz management AP ----------------------

log "Standing up radio1 as 2.4 GHz management AP \"${MGMT_SSID}\""
ssh_router "
	# Detect the 2.4 GHz device dynamically (don't hardcode 'radio1' — could
	# be 'radio0' on different boards).
	radio_2g=\$(uci show wireless | awk -F'[.=]' '/wifi-device/ && /band=.2g./ {print \$2; exit}')
	if [ -z \"\$radio_2g\" ]; then
		# Fallback: parse band by looking at hwmode/channel.
		for r in \$(uci show wireless | awk -F'[.=]' '/=wifi-device\$/ {print \$2}'); do
			ch=\$(uci -q get wireless.\$r.channel)
			case \"\$ch\" in
				1|2|3|4|5|6|7|8|9|10|11|12|13|14|auto) radio_2g=\$r; break ;;
			esac
		done
	fi
	if [ -z \"\$radio_2g\" ]; then
		echo \"  Could not detect a 2.4 GHz radio. Skipping mgmt-AP setup.\"
		exit 0
	fi
	echo \"  2.4 GHz radio is: \$radio_2g\"

	# Enable the radio + set channel + country
	uci set wireless.\$radio_2g.disabled=0
	uci set wireless.\$radio_2g.channel='${MGMT_CHANNEL}'
	uci set wireless.\$radio_2g.country='${MGMT_COUNTRY}'

	# Add or update the mgmt-AP wifi-iface
	if ! uci -q get wireless.mgmt_ap >/dev/null; then
		uci set wireless.mgmt_ap=wifi-iface
	fi
	uci set wireless.mgmt_ap.device=\$radio_2g
	uci set wireless.mgmt_ap.network='lan'
	uci set wireless.mgmt_ap.mode='ap'
	uci set wireless.mgmt_ap.disabled='0'
	uci set wireless.mgmt_ap.ssid='${MGMT_SSID}'
	uci set wireless.mgmt_ap.encryption='sae'
	uci set wireless.mgmt_ap.key='${MGMT_KEY}'
	uci set wireless.mgmt_ap.ieee80211w='2'

	# Disable the stock placeholder AP on that radio if present
	for s in \$(uci show wireless | grep -E '=wifi-iface\$' | awk -F'[.=]' '{print \$2}'); do
		dev=\$(uci -q get wireless.\$s.device)
		mode=\$(uci -q get wireless.\$s.mode)
		if [ \"\$dev\" = \"\$radio_2g\" ] && [ \"\$s\" != \"mgmt_ap\" ] && [ \"\$mode\" = \"ap\" ]; then
			uci set wireless.\$s.disabled=1
		fi
	done

	uci commit wireless

	echo \"  Reloading wifi...\"
	wifi reload
"

sleep 3
log "Verifying mgmt-AP is up"
ssh_router 'iwinfo 2>&1 | grep -E "ESSID|Mode|Channel" | head -20'

# --- Summary --------------------------------------------------------------

cat <<EOF

==========================================================================
Post-install done.

Management strategy now:
  - Wired LAN stays at 192.168.1.1/24 (openmanetd's renumber is pinned off)
  - Mgmt Wi-Fi: SSID "${MGMT_SSID}" on 2.4 GHz, WPA3-SAE, passphrase "${MGMT_KEY}"
    → connect from any phone/laptop and SSH to 192.168.1.1, even if you
      later mess with the wired side via the wizard.

You can now safely open the mesh wizard and click Save & Apply:
  http://192.168.1.1/cgi-bin/luci/admin/network/meshwizard
==========================================================================
EOF
