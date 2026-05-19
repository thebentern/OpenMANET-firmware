#!/usr/bin/env bash
# Switch the Mac's USB ethernet adapter between:
#   recovery   → static 192.168.1.5/24 (talks to GL.iNet u-boot recovery @ 192.168.1.1)
#   openmanet  → DHCP                  (lets OpenMANET dnsmasq hand out 10.41.x.x)
#
# Identical to axt-net.sh in mechanics — the MT3000 and AXT-1800 both use
# 192.168.1.1 as their u-boot recovery IP and 10.41.254.1 as the running-
# OpenMANET DHCP server. Kept as a separate copy so each board's contrib/
# is self-contained for an operator who only has one board.
#
# Usage:  ./mt3000-net.sh recovery
#         ./mt3000-net.sh openmanet
#
# Override the service-name auto-detection with:
#   MT3000_SERVICE='USB 10/100/1000 LAN' ./mt3000-net.sh recovery

set -euo pipefail

mode="${1:-}"
if [[ "$mode" != "recovery" && "$mode" != "openmanet" ]]; then
	cat <<EOF >&2
usage: $0 recovery|openmanet

  recovery   static 192.168.1.5/24 — for u-boot recovery at 192.168.1.1
  openmanet  DHCP                  — for booted OpenMANET (dnsmasq @ 10.41.254.1)
EOF
	exit 2
fi

# Auto-detect the USB ethernet service name. Override with MT3000_SERVICE=.
service="${MT3000_SERVICE:-}"
if [[ -z "$service" ]]; then
	service=$(networksetup -listallhardwareports | awk '
		/^Hardware Port: / { port=$0; sub(/^Hardware Port: /,"",port); next }
		/^Device: / && port ~ /USB.*(LAN|Ethernet)/ { print port; exit }
	')
fi

if [[ -z "$service" ]]; then
	echo "Could not auto-detect a USB ethernet service." >&2
	echo "Set MT3000_SERVICE='<service name>' explicitly. Available services:" >&2
	networksetup -listallhardwareports >&2
	exit 1
fi

echo "Service: $service"

case "$mode" in
	recovery)
		networksetup -setmanual "$service" 192.168.1.5 255.255.255.0 ""
		networksetup -setdnsservers "$service" Empty
		echo "→ static 192.168.1.5/24 (u-boot recovery target: 192.168.1.1)"
		;;
	openmanet)
		networksetup -setdhcp "$service"
		networksetup -setdnsservers "$service" Empty
		echo "→ DHCP (OpenMANET target: 10.41.254.1)"
		;;
esac

# Verify the change applied
sleep 2
dev=$(networksetup -listallhardwareports | awk -v s="$service" '
	$0 ~ "Hardware Port: "s {found=1; next}
	found && /^Device: / { print $2; exit }
')
if [[ -n "$dev" ]]; then
	echo
	echo "Current $dev state:"
	ifconfig "$dev" | grep -E "inet |status:" || ifconfig "$dev" | tail -3
fi
