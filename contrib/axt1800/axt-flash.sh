#!/usr/bin/env bash
# axt-flash.sh — flash a pre-built OpenMANET-for-AXT1800 factory image
# via u-boot recovery. No package install needed: the image already
# contains the wizard, alfred, openmanetd, tailscale, and the
# /etc/uci-defaults script that auto-configures everything on first boot.
#
# Operator flow:
#   1. Power off the AXT-1800
#   2. Hold the reset button, plug power back in, keep holding 10s, release
#   3. From the Mac (already on static 192.168.1.5):
#        ~/Downloads/axt-flash.sh
#   4. Wait ~60s for boot, then connect to wireless SSID `openmanet-mgmt`
#      (passphrase: openmanet-mgmt-please-change — change after first login)
#      OR plug ethernet into a LAN port; LAN is at 192.168.1.1.
#
# Image lives at ~/Downloads/openmanet-axt1800-factory.ubi by default;
# override with $AXT_IMAGE.

set -euo pipefail

ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
AXT_IMAGE="${AXT_IMAGE:-$HOME/Downloads/openmanet-axt1800-factory.ubi}"

if [[ -t 1 ]]; then
	C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
	C_HEAD=$'\033[36;1m'; C_RST=$'\033[0m'
else
	C_OK=""; C_WARN=""; C_ERR=""; C_HEAD=""; C_RST=""
fi
step() { printf '\n%s━━━ %s ━━━%s\n' "$C_HEAD" "$*" "$C_RST"; }
ok()   { printf '  %s✓%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$C_WARN" "$C_RST" "$*"; }
fail() { printf '  %s✗%s %s\n' "$C_ERR"  "$C_RST" "$*"; }

step "Pre-flight"
if [[ ! -f "$AXT_IMAGE" ]]; then
	fail "Image not found: $AXT_IMAGE"
	fail "Set AXT_IMAGE=/path/to/openmanet-axt1800-factory.ubi or place it at $HOME/Downloads/"
	exit 1
fi
size=$(stat -f%z "$AXT_IMAGE" 2>/dev/null || stat -c%s "$AXT_IMAGE")
ok "Image: $AXT_IMAGE ($(printf '%.1f' $(echo "scale=2; $size/1024/1024" | bc)) MB)"
ok "Target: http://$ROUTER_IP/"

step "Confirm u-boot recovery mode"
http_body=$(curl -s --max-time 5 "http://${ROUTER_IP}/" 2>/dev/null || true)
if echo "$http_body" | grep -qiE "uboot|firmware update"; then
	ok "u-boot recovery is responding (pepe2k mod)"
else
	fail "Router at $ROUTER_IP is not in u-boot recovery."
	fail "To enter recovery mode:"
	fail "  1. Power off the AXT-1800"
	fail "  2. Press and hold the reset button"
	fail "  3. While holding reset, plug in power"
	fail "  4. Keep holding for 10 seconds, then release"
	fail "  5. Re-run me"
	exit 1
fi

step "Upload firmware image"
curl --max-time 300 \
     -w "  HTTP %{http_code} in %{time_total}s — %{size_upload} bytes uploaded\n" \
     -F "firmware=@${AXT_IMAGE}" \
     -s -o /dev/null \
     "http://${ROUTER_IP}/"

step "Wait for first boot (up to 3 min)"
echo "  Router writes the image to NAND, reboots, and runs uci-defaults on first boot."
deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < deadline )); do
	if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
	   -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
	   root@"$ROUTER_IP" true 2>/dev/null; then
		ok "Router back online and accepting SSH"
		break
	fi
	sleep 5
	printf '.'
done

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
   -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
   root@"$ROUTER_IP" true 2>/dev/null; then
	echo
	fail "Router didn't come back. Check power, cable, LEDs."
	exit 1
fi

step "Done — final state"
ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null root@"$ROUTER_IP" '
	. /etc/openwrt_release
	echo "  Firmware:   $DISTRIB_DESCRIPTION"
	echo "  LAN IP:     $(uci -q get network.lan.ipaddr)"
	echo "  Mgmt AP:    $(iwinfo phy1-ap0 info 2>/dev/null | grep ESSID | head -1 | sed s/.*ESSID:\ //)"
	echo "  Wizard:     /usr/share/luci/menu.d/luci-app-axt1800-meshwizard.json present? $(test -f /usr/share/luci/menu.d/luci-app-axt1800-meshwizard.json && echo yes || echo no)"
	echo "  openmanetd: $(pidof openmanetd >/dev/null && echo running || echo down)"
	echo "  alfred:     $(pidof alfred >/dev/null && echo running || echo down)"
	echo "  tailscale:  $(pidof tailscaled >/dev/null && echo running || echo down)"
	echo "  uci-defaults left behind: $(ls /etc/uci-defaults/ 2>/dev/null | wc -l) script(s) (want 0)"
' 2>/dev/null

cat <<EOF

  Next:
    - Wired access: SSH or LuCI → http://${ROUTER_IP}/
    - Wireless access: connect to SSID "openmanet-mgmt" (WPA3-SAE,
      passphrase: openmanet-mgmt-please-change — CHANGE IT)
    - Open the mesh wizard:
        http://${ROUTER_IP}/cgi-bin/luci/admin/network/meshwizard
      Set Mesh ID, channel, and optionally per-node bat0 IP, then
      Save & Apply.

EOF
