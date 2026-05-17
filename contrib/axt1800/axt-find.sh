#!/usr/bin/env bash
# Sweep the AXT ethernet subnet to find any responding host.
# Use when you don't know what IP the router booted at.
#
# Try this in order against any device that might be plugged in,
# with the Mac set to a static address on each subnet via axt-net.sh
# or System Settings.

set -uo pipefail

# Find the USB ethernet device (en7 in this user's case, varies)
DEV=$(networksetup -listallhardwareports | awk '
	/^Hardware Port: / { port=$0; sub(/^Hardware Port: /,"",port); next }
	/^Device: / && port ~ /USB.*(LAN|Ethernet)/ { print $2; exit }
')
if [[ -z "$DEV" ]]; then
	echo "Couldn't auto-find USB ethernet adapter. Edit DEV in this script." >&2
	exit 1
fi
echo "Using interface: $DEV"

# Show its current IP so we know which subnet to sweep
MY_IP=$(ifconfig "$DEV" | awk '/inet / { print $2; exit }')
if [[ -z "$MY_IP" ]]; then
	echo "$DEV has no IPv4 address. Set one first with axt-net.sh recovery or openmanet." >&2
	exit 1
fi
echo "My IP on $DEV: $MY_IP"

SUBNET=$(echo "$MY_IP" | awk -F. '{print $1"."$2"."$3}')
echo "Scanning $SUBNET.1-254 (this takes ~5s)..."

# Flush any stale ARP for the subnet
for ip in $(arp -an | awk -F'[ ()]' '/^\?/ { print $3 }' | grep "^${SUBNET}\."); do
	sudo -n arp -d "$ip" 2>/dev/null || true
done

# Sweep with parallel pings
for i in $(seq 1 254); do
	ping -c 1 -W 1 -t 1 -n -q "$SUBNET.$i" >/dev/null 2>&1 &
done
wait 2>/dev/null

# Read responding hosts from ARP table
echo
echo "Hosts responding on $SUBNET.0/24 (interface $DEV):"
arp -an | grep -F "on $DEV" | grep -v incomplete | \
	awk -F'[ ()]' '{ print $3 " -> " $7 }' | sort -t. -k4 -n

echo
echo "Also try common OpenWrt/GL.iNet/OpenMANET default IPs:"
for ip in 192.168.1.1 192.168.8.1 10.41.254.1 192.168.1.254; do
	if ping -c 1 -W 500 -t 1 -n -q "$ip" >/dev/null 2>&1; then
		mac=$(arp -an "$ip" 2>/dev/null | awk '{print $4}')
		echo "  $ip ALIVE${mac:+ ($mac)}"
	fi
done
