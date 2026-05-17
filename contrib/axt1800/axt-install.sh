#!/usr/bin/env bash
# axt-install.sh — one-button installer for OpenMANET on GL.iNet AXT-1800.
#
# Detects router state and runs the full pipeline:
#   1. If router is in u-boot recovery → flash stock OpenWrt 25.12.4
#   2. Wait for boot
#   3. Install our four .apk packages from local cache
#      (luci-app-axt1800-meshwizard, alfred, openmanetd, tailscale) + custom
#      deps (libgps30 etc.) — via reverse-SSH tunnel for upstream packages
#   4. Apply post-install hardening:
#       - openmanetd.config.dhcpconfigured=1 (prevents LAN renumber)
#       - 2.4 GHz management AP on radio1
#   5. Print summary and the URL of the mesh wizard
#
# Re-runnable. Skips steps already done.
#
# Requires (in $HOME/Downloads):
#   stock-25.12-axt1800-factory.ubi              ← stock OpenWrt factory image
#   owrt-25.12-pkgs/                              ← package directory
#     luci-app-axt1800-meshwizard-0.apk
#     alfred-2025.5-r1.apk
#     openmanetd-1.3.1-r1.apk
#     tailscale-1.96.4-r2.apk
#     openmanet-feed/                             ← cached custom-dep .apks
#       libgps30-3.25-r1.apk
#       …
#   axt-bisect.sh + axt-postinstall.sh           ← these helpers, alongside me
#
# The default Mac-side setup uses static 192.168.1.5/24 on the USB-ethernet
# adapter (run `axt-net.sh recovery` first if you don't have it set).

set -uo pipefail

ROUTER_IP="192.168.1.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STOCK_IMAGE="$HOME/Downloads/stock-25.12-axt1800-factory.ubi"
EXPECTED_VERSION="25.12.4"

# ANSI colors when stdout is a TTY (skip when piped).
if [[ -t 1 ]]; then
	C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
	C_HEAD=$'\033[36;1m'; C_RST=$'\033[0m'
else
	C_OK=""; C_WARN=""; C_ERR=""; C_HEAD=""; C_RST=""
fi

step()  { printf '\n%s━━━ %s ━━━%s\n' "$C_HEAD" "$*" "$C_RST"; }
ok()    { printf '  %s✓%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn()  { printf '  %s⚠%s %s\n' "$C_WARN" "$C_RST" "$*"; }
fail()  { printf '  %s✗%s %s\n' "$C_ERR"  "$C_RST" "$*"; }

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts")

router_ssh() {
	ssh "${SSH_OPTS[@]}" "root@${ROUTER_IP}" "$@"
}

# ─── Step 0: artifact sanity ────────────────────────────────────────────────
step "Pre-flight: verify required files"

for f in "$STOCK_IMAGE" \
         "$SCRIPT_DIR/axt-bisect.sh" \
         "$SCRIPT_DIR/axt-postinstall.sh" \
         "$HOME/Downloads/owrt-25.12-pkgs/luci-app-axt1800-meshwizard-0.apk" \
         "$HOME/Downloads/owrt-25.12-pkgs/alfred-2025.5-r1.apk" \
         "$HOME/Downloads/owrt-25.12-pkgs/openmanetd-1.3.1-r1.apk" \
         "$HOME/Downloads/owrt-25.12-pkgs/tailscale-1.96.4-r2.apk"; do
	if [[ -f "$f" ]]; then
		ok "found $f"
	else
		fail "MISSING $f"
		exit 1
	fi
done

if [[ ! -d "$HOME/Downloads/owrt-25.12-pkgs/openmanet-feed" ]]; then
	warn "No openmanet-feed/ cache. Custom deps (libgps30) will need the build VM at install time."
else
	ok "openmanet-feed/ cache present ($(ls "$HOME/Downloads/owrt-25.12-pkgs/openmanet-feed/"*.apk 2>/dev/null | wc -l | tr -d ' ') .apk files)"
fi

# ─── Step 1: detect router state ────────────────────────────────────────────
step "Detect router state"

ROUTER_STATE="unknown"

if router_ssh true 2>/dev/null; then
	version=$(router_ssh "grep DISTRIB_RELEASE /etc/openwrt_release | cut -d\\' -f2" 2>/dev/null || echo "?")
	if [[ "$version" == "$EXPECTED_VERSION" ]]; then
		ROUTER_STATE="stock-running"
		ok "Stock OpenWrt $EXPECTED_VERSION already running. SSH reachable."
	else
		ROUTER_STATE="other-running"
		warn "OpenWrt running but version is '$version', not '$EXPECTED_VERSION'."
		warn "Will flash to stock $EXPECTED_VERSION baseline."
	fi
else
	# SSH failed — maybe in u-boot recovery
	if curl -s --max-time 5 "http://${ROUTER_IP}/" 2>/dev/null | grep -qiE "uboot|firmware update"; then
		ROUTER_STATE="u-boot"
		ok "Router is in u-boot recovery."
	else
		ROUTER_STATE="unreachable"
		fail "Router is unreachable on $ROUTER_IP (neither SSH nor u-boot HTTP)."
		fail "Make sure Mac is on 192.168.1.5 static (\`axt-net.sh recovery\`) and"
		fail "the router is powered on, OR put it into u-boot:"
		fail "  1) Power off the AXT-1800"
		fail "  2) Hold reset, plug in power"
		fail "  3) Keep holding 10s, release"
		exit 1
	fi
fi

# ─── Step 2: flash if needed ────────────────────────────────────────────────
if [[ "$ROUTER_STATE" == "u-boot" || "$ROUTER_STATE" == "other-running" ]]; then
	step "Flash stock OpenWrt $EXPECTED_VERSION"

	if [[ "$ROUTER_STATE" == "other-running" ]]; then
		fail "Router is running non-stock. You need to manually drop it into u-boot:"
		fail "  power off, hold reset, plug in, hold 10s, release. Then re-run me."
		exit 1
	fi

	echo "  Uploading $STOCK_IMAGE..."
	curl --max-time 300 \
	     -w "  upload HTTP %{http_code} in %{time_total}s\n" \
	     -F "firmware=@${STOCK_IMAGE}" \
	     -s -o /dev/null \
	     "http://${ROUTER_IP}/" || { fail "Upload failed"; exit 1; }

	echo "  Waiting for stock to boot..."
	deadline=$(( $(date +%s) + 180 ))
	while (( $(date +%s) < deadline )); do
		if router_ssh -o BatchMode=yes true 2>/dev/null; then
			ok "Stock $EXPECTED_VERSION booted in ~$(( deadline - $(date +%s) ))s"
			break
		fi
		sleep 5
	done

	if ! router_ssh -o BatchMode=yes true 2>/dev/null; then
		fail "Router never came back after flash"
		exit 1
	fi
fi

# ─── Step 3: install our packages ───────────────────────────────────────────
step "Install OpenMANET package stack"
echo "  Delegating to axt-bisect.sh (this takes ~3 min with 4 reboots)..."
echo

if "$SCRIPT_DIR/axt-bisect.sh"; then
	ok "All four packages installed and survived their reboot"
else
	fail "axt-bisect.sh reported a failure. Investigate; rerun me to retry."
	exit 1
fi

# ─── Step 4: post-install hardening ─────────────────────────────────────────
step "Post-install hardening"
echo "  Delegating to axt-postinstall.sh..."
echo

if "$SCRIPT_DIR/axt-postinstall.sh"; then
	ok "openmanetd renumber disabled, mgmt AP up"
else
	fail "axt-postinstall.sh reported a failure"
	exit 1
fi

# ─── Step 5: clean up leftover tunnel state ─────────────────────────────────
step "Tidy up router state"
router_ssh '
	sed -i "/downloads.openwrt.org/d" /etc/hosts 2>/dev/null
	echo "  /etc/hosts: $(grep -c downloads.openwrt.org /etc/hosts || echo 0) downloads.openwrt.org entries (want 0)"
'

# ─── Summary ────────────────────────────────────────────────────────────────
step "Done — summary"

router_ssh '
	echo "  Firmware:    $(grep DISTRIB_DESCRIPTION /etc/openwrt_release | cut -d\" -f2)"
	echo "  Packages:    $(apk info 2>/dev/null | wc -l) installed"
	echo "  LAN IP:      $(uci get network.lan.ipaddr 2>/dev/null)"
	echo "  Mesh radio:  $(iwinfo phy0-mesh0 info 2>/dev/null | grep ESSID | head -1 | tr -s " " || echo "(not yet — open mesh wizard)")"
	echo "  Mgmt AP:     $(iwinfo phy1-ap0 info 2>/dev/null | grep ESSID | head -1 | tr -s " ")"
	echo "  bat0:        $(ip link show bat0 2>/dev/null | head -1 | grep -oE "state [A-Z]+|^[0-9]+: [a-z]+" | tr "\n" " ")"
	echo "  openmanetd:  PID $(pidof openmanetd) — web UI on :8080 :8081 :8087"
	echo "  alfred:      PID $(pidof alfred)"
' 2>/dev/null

cat <<EOF

  Next steps:

    1. Open the mesh wizard to configure the mesh:
         http://${ROUTER_IP}/cgi-bin/luci/admin/network/meshwizard

       Fill in Mesh ID, channel, encryption, and optionally the
       per-node IP in the "Mesh L3" section. Click Save & Apply.

    2. For management resilience: connect to the 2.4 GHz AP
         SSID: openmanet-mgmt
         WPA3-SAE passphrase: openmanet-mgmt-please-change   ← change me!
       Then SSH/LuCI to ${ROUTER_IP} works even if the wired LAN ever drops.

    3. Repeat install on a second AXT-1800 with the same wizard settings
       (especially Mesh ID and channel) and different per-node Mesh L3 IPs.
       The two nodes should auto-discover each other once both are saved.

EOF
