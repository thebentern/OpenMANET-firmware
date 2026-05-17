#!/usr/bin/env bash
# Bisect which custom OpenMANET package (if any) breaks boot on stock
# OpenWrt 25.12.4 on a GL.iNet AXT-1800.
#
# Works WITHOUT WAN: opens an ssh -R reverse tunnel so the router can
# reach downloads.openwrt.org via this Mac's existing internet connection,
# only while the script is running.
#
# How the tunnel works:
#   - ssh -R 18443:downloads.openwrt.org:443 root@router
#       Router's port 18443 → (tunnel) → Mac → real downloads.openwrt.org:443
#       (high port avoids conflicting with uhttpd's :443 LuCI HTTPS bind)
#   - /etc/hosts on router: downloads.openwrt.org -> 127.0.0.1
#   - /etc/apk/repositories[.d/*]: URLs rewritten from
#       https://downloads.openwrt.org/...  →  https://downloads.openwrt.org:18443/...
#   - apk resolves downloads.openwrt.org via /etc/hosts → 127.0.0.1 → hits
#     the ssh-R bind on :18443 → tunnels through Mac → real server :443.
#   - TLS is end-to-end (SNI=downloads.openwrt.org), cert validates, Mac
#     just shuffles bytes.
#
# Repo config is backed up on first run and restored on script exit.
#
# Run from the Mac with the AXT-1800 reachable at 192.168.1.1, with the
# Mac connected to the LAN side (any LAN port) and the Mac itself online
# via Wi-Fi or any other interface.

set -uo pipefail

ROUTER_IP="192.168.1.1"
ROUTER_USER="root"
PKG_DIR="$HOME/Downloads/owrt-25.12-pkgs"

# Build VM — has all our locally-built packages (alfred, openmanetd,
# their custom deps like libgps30, etc). Reachable from the Mac via Wi-Fi
# while the Mac is also on the router's LAN side via USB-ethernet.
VM_HOST="thebentern@192.168.2.180"
VM_BIN="/home/thebentern/openmanet-build/owrt-25.12/bin"

# Local cache of the VM's openmanet feed. Mirrored from the VM with
# `rsync -av --delete VM_HOST:.../openmanet/ LOCAL_FEED_CACHE/`. The
# script checks here FIRST before reaching out to the VM, so a flaky
# VM doesn't block installs.
LOCAL_FEED_CACHE="$HOME/Downloads/owrt-25.12-pkgs/openmanet-feed"

PACKAGES=(
	"luci-app-axt1800-meshwizard-0.apk"
	"alfred-2025.5-r1.apk"
	"openmanetd-1.3.1-r1.apk"
	"tailscale-1.96.4-r2.apk"
)

REBOOT_WAIT_MAX=180
PING_INTERVAL=3
TUNNEL_PORT=18443

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o UserKnownHostsFile="$HOME/.ssh/known_hosts")

TUNNEL_PID=""

log() { printf '\n=== %s ===\n' "$*"; }
warn() { printf '\n!!! %s !!!\n' "$*" >&2; }

ssh_router() {
	ssh "${SSH_OPTS[@]}" "${ROUTER_USER}@${ROUTER_IP}" "$@"
}

scp_to_router() {
	scp -O "${SSH_OPTS[@]}" "$@" "${ROUTER_USER}@${ROUTER_IP}:/tmp/"
}

# --- ssh -R tunnel management ---------------------------------------------

start_tunnel() {
	if [[ -n "$TUNNEL_PID" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
		return 0
	fi
	# -N: no remote command; ExitOnForwardFailure: bail if remote bind fails;
	# ServerAliveInterval: keep connection healthy so the tunnel doesn't die
	# silently while apk is mid-fetch.
	ssh "${SSH_OPTS[@]}" \
		-o ExitOnForwardFailure=yes \
		-o ServerAliveInterval=15 \
		-o ServerAliveCountMax=3 \
		-N -T \
		-R "${TUNNEL_PORT}:downloads.openwrt.org:443" \
		"${ROUTER_USER}@${ROUTER_IP}" &
	TUNNEL_PID=$!
	# Give the forward a moment to bind. ssh -N with ExitOnForwardFailure
	# will exit immediately if the bind fails.
	sleep 3
	if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
		warn "ssh -R tunnel failed to establish on port ${TUNNEL_PORT}."
		TUNNEL_PID=""
		return 1
	fi
}

stop_tunnel() {
	if [[ -n "$TUNNEL_PID" ]]; then
		kill "$TUNNEL_PID" 2>/dev/null || true
		wait "$TUNNEL_PID" 2>/dev/null || true
		TUNNEL_PID=""
	fi
}

# Map downloads.openwrt.org -> 127.0.0.1 in router's /etc/hosts so apk
# resolves to the tunnel endpoint. Idempotent.
configure_router_hosts() {
	ssh_router "grep -q 'downloads.openwrt.org' /etc/hosts || echo '127.0.0.1 downloads.openwrt.org' >> /etc/hosts"
}

# Rewrite apk repo URLs to use the tunnel port. Backs up originals to
# *.bak-axt-bisect on first run, then it's idempotent.
configure_apk_repos() {
	local port="$TUNNEL_PORT"
	ssh_router "
		set -e
		for f in /etc/apk/repositories /etc/apk/repositories.d/*.list; do
			[ -f \"\$f\" ] || continue
			if [ ! -f \"\$f.bak-axt-bisect\" ]; then
				cp \"\$f\" \"\$f.bak-axt-bisect\"
			fi
			# Start from the backup each time so we don't double-rewrite.
			sed -e 's|https://downloads.openwrt.org/|https://downloads.openwrt.org:${port}/|g' \
			    -e 's|http://downloads.openwrt.org/|http://downloads.openwrt.org:${port}/|g' \
			    \"\$f.bak-axt-bisect\" > \"\$f\"
		done
	"
}

restore_apk_repos() {
	ssh_router "
		for f in /etc/apk/repositories /etc/apk/repositories.d/*.list; do
			[ -f \"\$f.bak-axt-bisect\" ] || continue
			mv \"\$f.bak-axt-bisect\" \"\$f\"
		done
	" 2>/dev/null || true
}

# Quick smoke test that the tunnel actually carries traffic.
test_tunnel() {
	ssh_router "uclient-fetch -q -O /dev/null --timeout=10 https://downloads.openwrt.org:${TUNNEL_PORT}/releases/25.12.4/"
}

ensure_tunnel_and_hosts() {
	stop_tunnel
	start_tunnel || return 1
	configure_router_hosts
	configure_apk_repos
	if ! test_tunnel; then
		warn "Tunnel established but fetch test failed. Check that this Mac has internet."
		return 1
	fi
	return 0
}

# --- Router state helpers --------------------------------------------------

wait_for_ping() {
	local deadline=$(( $(date +%s) + REBOOT_WAIT_MAX ))
	while (( $(date +%s) < deadline )); do
		if ping -c 1 -W 1 -t 1 -n -q "$ROUTER_IP" >/dev/null 2>&1; then
			return 0
		fi
		sleep "$PING_INTERVAL"
	done
	return 1
}

wait_for_ssh() {
	local deadline=$(( $(date +%s) + REBOOT_WAIT_MAX ))
	while (( $(date +%s) < deadline )); do
		if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${ROUTER_USER}@${ROUTER_IP}" true >/dev/null 2>&1; then
			return 0
		fi
		sleep "$PING_INTERVAL"
	done
	return 1
}

pkg_installed_on_router() {
	local apk_file="$1"
	local short
	short=$(echo "${apk_file%.apk}" | sed -E 's/-[0-9][^-]*(-r[0-9]+)?$//')
	ssh_router "apk info -e $short" 2>/dev/null | grep -q "^$short"
}

# --- Build VM dep resolution ----------------------------------------------
# When apk reports a missing package (one not in upstream repos), look it up
# in the build VM's bin/ tree, pull it via the Mac, and stage it on the
# router so the next apk add finds it.

vm_reachable() {
	ssh -o BatchMode=yes -o ConnectTimeout=5 "${VM_HOST}" true 2>/dev/null
}

# Look up a dep in the local feed cache (mirrored from VM). Echoes
# absolute path to the .apk if found, empty if not.
local_find_pkg() {
	local pkg="$1"
	[[ -d "$LOCAL_FEED_CACHE" ]] || return 1
	find "$LOCAL_FEED_CACHE" -maxdepth 1 -type f \
		\( -name "${pkg}-[0-9]*.apk" -o -name "${pkg}_[0-9]*.apk" \) \
		2>/dev/null | head -1
}

# Push a local-cache .apk to the router /tmp/. Echoes router-side path.
local_push_to_router() {
	local local_path="$1"
	local fname
	fname=$(basename "$local_path")
	scp -O "${SSH_OPTS[@]}" "$local_path" "${ROUTER_USER}@${ROUTER_IP}:/tmp/$fname" >&2 || return 1
	echo "/tmp/$fname"
}

# Find a .apk file on the VM whose package name matches the given name.
# OpenWrt apk filenames look like:  <name>-<version>-r<rel>.apk
# e.g. libgps30-3.25-r1.apk
vm_find_pkg() {
	local pkg="$1"
	ssh "${VM_HOST}" "
		find '${VM_BIN}/packages' '${VM_BIN}/targets/qualcommax/ipq60xx/packages' \
			-maxdepth 4 -type f \\( -name '${pkg}-[0-9]*.apk' -o -name '${pkg}_[0-9]*.apk' \\) 2>/dev/null \
			| head -1
	"
}

# Pull a file from VM → Mac → router:/tmp. Echoes router-side path on stdout.
vm_pull_to_router() {
	local vm_path="$1"
	local fname
	fname=$(basename "$vm_path")
	local mac_tmp="/tmp/axt-bisect-$$-${fname}"
	scp -q "${VM_HOST}:${vm_path}" "$mac_tmp" >&2 || return 1
	scp -O "${SSH_OPTS[@]}" "$mac_tmp" "${ROUTER_USER}@${ROUTER_IP}:/tmp/$fname" >&2 || return 1
	rm -f "$mac_tmp"
	echo "/tmp/$fname"
}

# Install a package, iteratively pulling missing deps from the build VM.
install_with_vm_deps() {
	local target="$1"
	local extras=()
	local seen_missing=""
	local attempt=0

	while (( attempt < 20 )); do
		attempt=$((attempt + 1))
		local cmd="apk add --allow-untrusted /tmp/${target}"
		if (( ${#extras[@]} > 0 )); then
			cmd="$cmd ${extras[*]}"
		fi

		local output
		# Capture combined stdout+stderr but also tee to terminal so the
		# user sees progress.
		output=$(ssh_router "$cmd" 2>&1)
		local rc=$?
		echo "$output"
		if (( rc == 0 )); then
			return 0
		fi

		# Pull out the first "X (no such package)" — the package name apk
		# couldn't resolve. Be permissive about leading whitespace.
		local missing
		missing=$(echo "$output" \
			| grep -oE '[[:space:]][a-zA-Z0-9._+-]+ \(no such package\)' \
			| head -1 \
			| awk '{print $1}')

		if [[ -z "$missing" ]]; then
			# Not a missing-dep error — bail.
			return 1
		fi

		if echo " $seen_missing " | grep -q " $missing "; then
			warn "Already pulled $missing once and apk still wants it. Giving up."
			return 1
		fi
		seen_missing="$seen_missing $missing"

		log "Missing dep: $missing"

		# Try local cache first — survives VM flakes.
		local cache_path
		cache_path=$(local_find_pkg "$missing")
		if [[ -n "$cache_path" ]]; then
			log "Found in local cache: $cache_path — pushing to router"
			local router_path
			router_path=$(local_push_to_router "$cache_path") || return 1
			extras+=("$router_path")
			continue
		fi

		# Fall back to the build VM.
		log "Not in local cache — checking build VM"
		if ! vm_reachable; then
			warn "Build VM ${VM_HOST} unreachable AND $missing not in local cache. Bail."
			return 1
		fi

		local vm_path
		vm_path=$(vm_find_pkg "$missing")
		if [[ -z "$vm_path" ]]; then
			warn "Could not find $missing on build VM under $VM_BIN"
			return 1
		fi
		log "Found: $vm_path — pulling via VM to router"

		local router_path
		router_path=$(vm_pull_to_router "$vm_path") || return 1
		extras+=("$router_path")
	done

	warn "Hit max attempts ($attempt) resolving deps for $target"
	return 1
}

declare_culprit() {
	local pkg="$1"
	warn "Router did not come back after installing: $pkg"
	echo
	echo "This package is the culprit. Recover with u-boot:"
	echo "  1. Power off the AXT-1800."
	echo "  2. Hold the reset button while plugging power back in."
	echo "  3. Wait ~10s, release."
	echo "  4. Set Mac to 192.168.1.2 static and browse to http://192.168.1.1"
	echo "  5. Upload stock-25.12-axt1800-factory.ubi"
	exit 2
}

# --- Cleanup --------------------------------------------------------------

cleanup() {
	stop_tunnel
	# Restore original apk repo URLs so the router's config isn't left
	# pointing at our high port. /etc/hosts entry is harmless to leave.
	restore_apk_repos
}
trap cleanup EXIT INT TERM

# --- Sanity checks --------------------------------------------------------

if [[ ! -d "$PKG_DIR" ]]; then
	warn "Package directory not found: $PKG_DIR"
	exit 1
fi

for pkg in "${PACKAGES[@]}"; do
	if [[ ! -f "$PKG_DIR/$pkg" ]]; then
		warn "Missing package: $PKG_DIR/$pkg"
		exit 1
	fi
done

# Confirm this Mac has internet — the tunnel is pointless otherwise.
if ! ping -c 1 -W 2 -t 2 -n -q downloads.openwrt.org >/dev/null 2>&1; then
	warn "This Mac can't reach downloads.openwrt.org. Get the Mac online first."
	exit 1
fi

# Confirm this Mac can reach the build VM (we need it for non-upstream deps
# like libgps30 that only exist in our local build tree).
if ! vm_reachable; then
	warn "This Mac can't SSH to ${VM_HOST}. Custom deps (libgps30 etc) won't resolve."
	warn "Continuing anyway — script will bail at first missing dep if needed."
fi

# --- Step 0: reach router --------------------------------------------------

log "Clearing any stale known_hosts entry for $ROUTER_IP"
ssh-keygen -R "$ROUTER_IP" >/dev/null 2>&1 || true

log "Pinging $ROUTER_IP to confirm it is alive"
if ! ping -c 2 -W 1 -t 1 -n -q "$ROUTER_IP" >/dev/null 2>&1; then
	warn "$ROUTER_IP not responding. Is the router booted on stock 25.12.4?"
	exit 1
fi

log "Confirming SSH works"
if ! ssh_router true; then
	warn "SSH to $ROUTER_USER@$ROUTER_IP failed."
	exit 1
fi

# --- Step 1: bring up tunnel ----------------------------------------------

log "Opening ssh -R reverse tunnel so router can fetch packages via this Mac"
if ! ensure_tunnel_and_hosts; then
	warn "Could not establish package-fetch tunnel."
	exit 1
fi

log "Refreshing apk index on router (via tunnel)"
ssh_router "apk update" || warn "apk update had warnings — proceeding."

# --- Step 2 + 3: install + reboot per package -----------------------------
# We re-scp each package's .apk right before installing it, because /tmp
# on the router is tmpfs and gets wiped on every reboot.

for pkg in "${PACKAGES[@]}"; do
	if pkg_installed_on_router "$pkg"; then
		log "Skipping $pkg (already installed from a previous run)"
		continue
	fi

	# Make sure tunnel is still healthy before this install.
	if ! kill -0 "$TUNNEL_PID" 2>/dev/null || ! test_tunnel; then
		log "Re-establishing tunnel before installing $pkg"
		ensure_tunnel_and_hosts || { warn "Tunnel down and won't come up."; exit 1; }
	fi

	log "Staging $pkg to router /tmp/ (post-reboot /tmp is empty)"
	scp_to_router "$PKG_DIR/$pkg"

	log "Installing $pkg (with VM-backed dep resolution)"
	if ! install_with_vm_deps "$pkg"; then
		warn "apk add failed for $pkg (install error, not boot error)."
		exit 3
	fi

	# Tunnel dies when router reboots — drop it cleanly first.
	stop_tunnel

	log "Rebooting router after $pkg"
	ssh_router "reboot" >/dev/null 2>&1 || true
	sleep 8

	log "Waiting for ping (up to ${REBOOT_WAIT_MAX}s)"
	if ! wait_for_ping; then
		declare_culprit "$pkg"
	fi

	log "Ping returned. Waiting for SSH to come back"
	if ! wait_for_ssh; then
		declare_culprit "$pkg"
	fi

	log "$pkg survived reboot."
	sleep 5

	# Bring tunnel back up for the next package's dep fetch.
	ensure_tunnel_and_hosts || warn "Tunnel re-establish failed; next install may fail on deps."
done

log "ALL FOUR PACKAGES SURVIVED REBOOT."
echo
echo "Conclusion: the boot failure is NOT caused by these packages."
echo "Next bisection target: our base-files / uci-defaults customizations"
echo "(99-axt1800-openmanet-defaults, mediaurlbase change, pre-created bat0)."
echo
echo "Suggested next step: reflash stock-25.12-axt1800-factory.ubi to wipe"
echo "back to a clean baseline, then layer customizations on incrementally"
echo "rather than rebuilding the whole image."
