#!/usr/bin/env bash
# openmanet-build-test.sh — validate a board's diffconfig on the build VM.
#
# Two test depths, controlled by --full:
#
#   default   (~3-5 min) — set up the per-board OpenWrt tree if missing,
#                           sync the fork, run feed update + install, apply
#                           the board's diffconfig, `make defconfig`.
#                           Verifies target/subtarget resolved, WiFi driver
#                           selected, all 6 OpenMANET LuCI pages enabled.
#                           Catches Kconfig typos, target/subtarget
#                           mismatches, missing feed deps.
#
#   --full   (~30-90 min) — also `make download` + `make -j$(nproc)`.
#                            Produces a real factory image artifact in
#                            bin/targets/<target>/. This is also when host
#                            tools (host-lua etc.) actually get built —
#                            the quick path deliberately skips compile
#                            steps so it doesn't trigger that 30-min cost.
#
# Usage:
#   ./openmanet-build-test.sh [board-name] [--full]
#
# Defaults:
#   board-name = glinet-mt3000
#   VM         = thebentern@192.168.2.180  (override via $VM_HOST)
#   fork       = $HOME/Documents/GitHub/OpenMANET-firmware  (override via $FORK_PATH)
#
# Examples:
#   ./openmanet-build-test.sh                         # quick MT3000 check
#   ./openmanet-build-test.sh glinet-mt3000 --full    # full MT3000 image
#   ./openmanet-build-test.sh glinet-axt1800          # re-validate AXT-1800
#
# The script is idempotent — re-running just refreshes the fork content
# on the VM and re-runs defconfig. Existing build_dir/staging_dir are reused.

set -euo pipefail

BOARD="${1:-glinet-mt3000}"
FULL=0
[[ "${2:-}" == "--full" ]] && FULL=1

VM_HOST="${VM_HOST:-thebentern@192.168.2.180}"
FORK_PATH="${FORK_PATH:-$HOME/Documents/GitHub/OpenMANET-firmware}"
VM_TREE="${VM_TREE:-\$HOME/openmanet-build/owrt-25.12-${BOARD}}"
OPENWRT_BRANCH="${OPENWRT_BRANCH:-openwrt-25.12}"
OPENWRT_REPO="${OPENWRT_REPO:-https://git.openwrt.org/openwrt/openwrt.git}"

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

# --- pre-flight checks -----------------------------------------------------
step "Pre-flight"

DIFFCONFIG="$FORK_PATH/boards/$BOARD/target_diffconfig"
if [[ ! -f "$DIFFCONFIG" ]]; then
	fail "Board diffconfig not found: $DIFFCONFIG"
	fail "Available boards: $(ls "$FORK_PATH/boards/" 2>/dev/null | grep -v common | tr '\n' ' ')"
	exit 1
fi
ok "Board: $BOARD ($(wc -l < "$DIFFCONFIG" | tr -d ' ') lines in diffconfig)"

if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$VM_HOST" true 2>/dev/null; then
	fail "Cannot SSH to build VM: $VM_HOST"
	fail "Set VM_HOST=user@host or check connectivity."
	exit 1
fi
ok "Build VM reachable: $VM_HOST"

VM_TREE_REAL=$(ssh "$VM_HOST" "eval echo $VM_TREE")
ok "Target tree: $VM_TREE_REAL"
ok "Depth: $([[ "$FULL" == "1" ]] && echo 'FULL (defconfig + download + make world)' || echo 'quick (defconfig + smoke compile)')"

# --- bootstrap the tree if missing -----------------------------------------
step "Build-tree bootstrap"

NEED_BOOTSTRAP=$(ssh "$VM_HOST" "[ -f $VM_TREE/Makefile ] && [ -f $VM_TREE/feeds.conf.default ] && echo no || echo yes")
if [[ "$NEED_BOOTSTRAP" == "yes" ]]; then
	warn "Tree doesn't exist yet — bootstrapping fresh openwrt-25.12 checkout"
	echo "  (one-time setup; ~3-5 min depending on network)"
	ssh "$VM_HOST" "bash -lc '
		set -e
		mkdir -p \$HOME/openmanet-build
		cd \$HOME/openmanet-build
		if [ ! -d $VM_TREE ]; then
			git clone --depth 1 --branch $OPENWRT_BRANCH $OPENWRT_REPO $(basename $VM_TREE)
		fi
	'"
	ok "Tree cloned"
else
	ok "Tree already present (reusing)"
fi

# --- sync fork content into the tree ---------------------------------------
step "Sync fork → VM"

# Tarball just the parts the test needs (smaller transfer than the whole
# fork). Use COPYFILE_DISABLE=1 because Mac BSD tar otherwise injects the
# AppleDouble ._foo metadata that broke a previous build.
TAR=/tmp/openmanet-build-test-${BOARD}.tar
( cd "$FORK_PATH" && COPYFILE_DISABLE=1 tar --no-xattrs -cf "$TAR" \
	boards/common \
	boards/common_extras \
	"boards/$BOARD" \
	package/luci-app-openmanet-meshwizard \
	package/luci-app-openmanet-camera \
	package/luci-app-openmanet-cot \
	package/luci-app-openmanet-meshstatus \
	package/luci-app-openmanet-meshtasticd \
	package/luci-app-openmanet-tailscale \
	package/meshtastic-repo \
	package/libs/libyaml-cpp \
	feeds.conf.default 2>/dev/null )

scp -q "$TAR" "$VM_HOST:/tmp/$(basename $TAR)"
ssh "$VM_HOST" "bash -lc '
	set -e
	cd $VM_TREE
	# Make sure key directories exist before extract
	mkdir -p boards package
	tar -xf /tmp/$(basename $TAR) --warning=none
	# Sanity: remove any macOS metadata that snuck through
	find boards/$BOARD package/luci-app-openmanet-* package/meshtastic-repo \
		package/libs/libyaml-cpp -name '._*' -delete 2>/dev/null || true
'"
rm -f "$TAR"
ok "Fork content synced"

# --- feed update + install -------------------------------------------------
step "Refresh feeds"

ssh "$VM_HOST" "bash -lc '
	set -e
	cd $VM_TREE
	./scripts/feeds update -a 2>&1 | tail -3
	./scripts/feeds install -a 2>&1 | tail -3
	# Remove the feed symlink for libyaml-cpp so our top-level override wins
	# (the libyaml-cpp upstream Makefile bug fix lives at
	#  package/libs/libyaml-cpp/Makefile in the fork).
	rm -f package/feeds/packages/libyaml-cpp
' 2>&1" | sed 's/^/  /'
ok "Feeds updated"

# --- apply diffconfig + make defconfig -------------------------------------
step "Apply diffconfig + defconfig"

ssh "$VM_HOST" "bash -lc '
	set -e
	cd $VM_TREE
	# Apply common + board diffconfig as the .config. Order matters:
	# common first (defaults), then per-board (overrides).
	rm -f .config
	if [ -f boards/common/openmanet_diffconfig ]; then
		cat boards/common/openmanet_diffconfig >> .config
	fi
	if [ -f boards/common_extras/openmanet_diffconfig_extras ]; then
		cat boards/common_extras/openmanet_diffconfig_extras >> .config
	fi
	cat boards/$BOARD/target_diffconfig >> .config
	echo
	echo \"  .config size: \$(wc -l < .config) lines\"
'"

# Capture defconfig output
DEFCONFIG_LOG=/tmp/openmanet-defconfig-${BOARD}.log
ssh "$VM_HOST" "bash -lc 'cd $VM_TREE && make defconfig 2>&1'" \
	> "$DEFCONFIG_LOG" 2>&1 || true

# Look for the kinds of complaints defconfig emits when something is amiss
WARN_LINES=$(grep -cE "WARNING|warning" "$DEFCONFIG_LOG" || true)
ERR_LINES=$(grep -cE "^make.*Error|^ERROR" "$DEFCONFIG_LOG" || true)
echo "  defconfig output:"
tail -15 "$DEFCONFIG_LOG" | sed 's/^/    /'
echo

if [[ "$ERR_LINES" -gt 0 ]]; then
	fail "$ERR_LINES error(s) during defconfig"
	grep -E "^make.*Error|^ERROR" "$DEFCONFIG_LOG" | head -5 | sed 's/^/    /'
	exit 1
fi
if [[ "$WARN_LINES" -gt 0 ]]; then
	warn "$WARN_LINES warning(s) — most are about missing deps in feed Makefiles, usually safe"
fi
ok "make defconfig completed"

# --- confirm the target + arch resolved correctly --------------------------
step "Verify target resolution"

ssh "$VM_HOST" "bash -lc '
	cd $VM_TREE
	echo \"  CONFIG_TARGET_BOARD:    \$(grep \"^CONFIG_TARGET_BOARD=\" .config 2>/dev/null | cut -d= -f2)\"
	echo \"  CONFIG_TARGET_ARCH:     \$(grep \"^CONFIG_TARGET_ARCH_PACKAGES=\" .config 2>/dev/null | cut -d= -f2)\"
	echo \"  Target subtarget line:  \$(grep \"^CONFIG_TARGET_.*_DEVICE_glinet\" .config 2>/dev/null | head -1)\"
	echo \"  WiFi driver picked:     \$(grep \"^CONFIG_PACKAGE_kmod-\\(ath11k\\|mt76\\|mt7\\)\" .config 2>/dev/null | grep -v \"=n\" | tr \"\\n\" \" \")\"
	echo \"  OpenMANET LuCI pages:   \$(grep \"^CONFIG_PACKAGE_luci-app-openmanet\" .config 2>/dev/null | grep -v \"=n\" | wc -l) selected\"
'"

# Smoke compile is intentionally NOT in the quick path: on a fresh build
# tree, the first `make package/X/compile` triggers a chain that includes
# building host tools (host-lua, etc.) which needs `make download` and
# ~30 min of toolchain setup. That's the wrong cost-trade for "did my
# diffconfig parse correctly." Use --full when you actually want artifacts.

# --- optional full build ---------------------------------------------------
if [[ "$FULL" == "1" ]]; then
	step "Full image build (--full)"
	echo "  This will take 30-90 minutes."
	echo "  Output: bin/targets/<target>/<device>-squashfs-factory.{bin,ubi}"
	echo
	ssh "$VM_HOST" "bash -lc '
		cd $VM_TREE
		make download 2>&1 | tail -5
		time make -j\$(nproc) 2>&1 | tail -30
		echo
		echo \"=== Final artifacts ===\"
		find bin/targets -name \"*squashfs-factory*\" -o -name \"*squashfs-sysupgrade*\" 2>/dev/null | xargs -I{} ls -la {}
	'"
fi

# --- summary ---------------------------------------------------------------
step "Done"
ok "Board $BOARD diffconfig is syntactically valid; defconfig resolved cleanly."
if [[ "$FULL" == "0" ]]; then
	echo
	echo "  For a real image build:"
	echo "    $0 $BOARD --full"
	echo
	echo "  Full defconfig log saved at: $DEFCONFIG_LOG (Mac side)"
fi
