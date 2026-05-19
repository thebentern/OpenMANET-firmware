#!/usr/bin/env bash
# mt3000-flash.sh — flash a pre-built OpenMANET-for-MT3000 factory image
# via the GL.iNet stock u-boot recovery web UI.
#
# Unlike the AXT-1800 (which uses the pepe2k u-boot mod), the MT3000 ships
# with GL.iNet's own u-boot recovery web interface at 192.168.1.1. The
# upload form's field name is the same (`firmware`) but the recovery page
# HTML/branding differs, so pre-flight detection looks for GL.iNet-specific
# strings before posting.
#
# Operator flow:
#   1. Power off the MT3000
#   2. Hold the reset button, plug power back in, keep holding 4-5 seconds,
#      release. (LED pattern: solid → blinking → solid signals recovery.)
#   3. From the Mac (already on static 192.168.1.5 — see mt3000-net.sh):
#        ./mt3000-flash.sh
#   4. Wait ~60-90s for boot, then connect to wireless SSID `openmanet-mgmt`
#      OR plug ethernet into a LAN port; LAN is at 192.168.1.1.
#
# Image lives at ~/Downloads/openmanet-mt3000-factory.bin by default;
# override with $MT3000_IMAGE.
#
# Compatible image filename patterns produced by OpenWrt's MediaTek/filogic
# build: openwrt-mediatek-filogic-glinet_gl-mt3000-squashfs-factory.bin

set -euo pipefail

ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
MT3000_IMAGE="${MT3000_IMAGE:-$HOME/Downloads/openmanet-mt3000-factory.bin}"

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
if [[ ! -f "$MT3000_IMAGE" ]]; then
	fail "Image not found: $MT3000_IMAGE"
	fail "Set MT3000_IMAGE=/path/to/openmanet-mt3000-factory.bin or place it at $HOME/Downloads/"
	exit 1
fi
size=$(stat -f%z "$MT3000_IMAGE" 2>/dev/null || stat -c%s "$MT3000_IMAGE")
ok "Image: $MT3000_IMAGE ($(printf '%.1f' $(echo "scale=2; $size/1024/1024" | bc)) MB)"
ok "Target: http://$ROUTER_IP/"

step "Confirm u-boot recovery mode (GL.iNet stock)"
http_body=$(curl -s --max-time 5 "http://${ROUTER_IP}/" 2>/dev/null || true)
# GL.iNet stock u-boot recovery pages typically contain one of:
#   - "GL.iNet" branding
#   - "U-Boot" or "uboot" text
#   - "Firmware update" / "Update firmware" form labels
# We also accept the pepe2k mod text in case the operator has cross-flashed,
# because the upload form field name is the same either way.
if echo "$http_body" | grep -qiE "GL\.iNet|U-Boot|uboot|firmware update|update firmware"; then
	if echo "$http_body" | grep -qi "GL.iNet"; then
		ok "GL.iNet stock u-boot recovery is responding"
	else
		ok "Some flavour of u-boot recovery is responding"
	fi
else
	fail "Router at $ROUTER_IP is not in u-boot recovery."
	fail "To enter recovery mode on the GL-MT3000:"
	fail "  1. Power off the MT3000"
	fail "  2. Press and hold the reset button"
	fail "  3. While holding reset, plug in power"
	fail "  4. Keep holding for 4-5 seconds, then release"
	fail "     (LED goes solid → blinking → solid when entering recovery)"
	fail "  5. Re-run me"
	exit 1
fi

step "Upload firmware image"
# `firmware` is the form field name used by both pepe2k and GL.iNet stock
# u-boot recovery uploads. If a future MT3000 firmware revision changes
# this, the upload returns 4xx and the post-flash wait below times out —
# at which point the operator would need to use GL.iNet's official web UI
# (uboot.gl-inet.com pattern) as a fallback.
curl --max-time 300 \
     -w "  HTTP %{http_code} in %{time_total}s — %{size_upload} bytes uploaded\n" \
     -F "firmware=@${MT3000_IMAGE}" \
     -s -o /dev/null \
     "http://${ROUTER_IP}/"

step "Wait for first boot (up to 3 min)"
echo "  Router writes the image to NAND, reboots, and runs uci-defaults on first boot."
echo "  MT3000 typically completes the write+reboot in 60-90 seconds (256 MB NAND, fast eMMC vs AXT's UBI)."
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
	# Dynamic AP iface lookup (radio numbering differs across mt76 vs ath11k)
	AP_IF=$(iw dev 2>/dev/null | awk "/Interface/ {iface=\$2} /type AP/ {print iface; exit}")
	if [ -n "$AP_IF" ]; then
		echo "  Mgmt AP:    $(iwinfo "$AP_IF" info 2>/dev/null | grep ESSID | head -1 | sed s/.*ESSID:\ //)"
	else
		echo "  Mgmt AP:    (no AP iface up yet — wizard not clicked?)"
	fi
	echo "  Wizard:     /usr/share/luci/menu.d/luci-app-openmanet-meshwizard.json present? $(test -f /usr/share/luci/menu.d/luci-app-openmanet-meshwizard.json && echo yes || echo no)"
	echo "  openmanetd: $(pidof openmanetd >/dev/null && echo running || echo down)"
	echo "  alfred:     $(pidof alfred >/dev/null && echo running || echo down)"
	echo "  tailscale:  $(pidof tailscaled >/dev/null && echo running || echo down)"
	echo "  uci-defaults left behind: $(ls /etc/uci-defaults/ 2>/dev/null | wc -l) script(s) (want 0)"
'

cat <<EOF

  Next:
    - Wired access: SSH or LuCI → http://192.168.1.1/
    - Wireless access: connect to SSID "openmanet-mgmt" (WPA3-SAE,
      passphrase: openmanet-mgmt-please-change — CHANGE IT)
    - Open the mesh wizard:
        http://192.168.1.1/cgi-bin/luci/admin/mesh/wizard
      Set Mesh ID, channel, and optionally per-node bat0 IP, then
      Save & Apply.

EOF
