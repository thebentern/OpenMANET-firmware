# OpenMANET on GL.iNet GL-AXT1800

Operator-side tooling for installing OpenMANET on the GL.iNet GL-AXT1800
(Qualcomm IPQ6018, qualcommax/ipq60xx target). All scripts run on macOS;
they talk to the router over USB ethernet (192.168.1.x) and to a build
VM (for the apk-install delivery model).

## What gets installed

A configured AXT-1800 ends up with:

- OpenWrt 25.12 base (stock or custom build, depending on path)
- `luci-app-axt1800-meshwizard` — LuCI form for one-page mesh setup
- `alfred` — gossip protocol for batman-adv, with `libgps30`
- `openmanetd` — OpenMANET management daemon + web UI (8080/8081/8087)
- `tailscale` + `kmod-tun`
- batman-adv kernel module + `batctl`
- `meshtastic-repo` — configures the official Meshtastic apk repository
  (`https://openwrt.meshtastic.org/`) + its signing key, plus a
  uci-defaults script that does a best-effort `apk add meshtasticd
  meshtasticd-web meshtasticd-avahi-service python3-meshtastic` on
  first boot. If the router has internet at boot, the daemon
  installs and auto-starts. If not, the install retries every
  subsequent boot until it succeeds — or operators can install
  manually any time via the same one-liner. Runtime deps
  (`avahi-daemon`, `libgpiod`, `libyaml-cpp`, `libuv`, `libusb-1.0`,
  `python3`, etc.) are pre-installed in the image so the first-boot
  fetch is small.
- `v4l2rtspserver` + `kmod-video-uvc` + `v4l-utils` — plug a UVC USB
  webcam into the router and the mesh wizard's "USB camera → RTSP
  stream" section (or the dedicated **Network → Camera** page) turns
  it into `rtsp://<router-ip>:8554/<path>` for VLC / ATAK / any
  RTSP-capable peer on the mesh. The dedicated page auto-detects
  plugged cameras (via `v4l2-ctl --list-devices`), shows a copy-able
  URL, and renders a **QR code** for one-tap setup in ATAK / VLC
  mobile. Off by default until enabled.
- 2.4 GHz management AP `openmanet-mgmt` on radio1 (WPA3-SAE)
- LAN at 192.168.1.1/24 — preserved across saves (openmanetd's
  address-reservation worker is pinned off via UCI)

Configuration is one-shot via `/etc/uci-defaults/99-axt1800-openmanet-init`
which ships inside the wizard package. The script self-deletes after a
successful first-boot run.

## Two delivery models

### Model A: all-in-one factory image

Build the custom AXT-1800 image and flash it via u-boot recovery. Everything
is baked in. No internet required on the operator's side.

```
# Prerequisite: openmanet-axt1800-factory.ubi in ~/Downloads/
# (build with `make` from the OpenWrt 25.12 tree configured for AXT-1800,
#  or download from project releases)

# 1. Put the AXT-1800 in u-boot recovery:
#    - Power off
#    - Press and hold the reset button
#    - Plug power back in while holding reset
#    - Keep holding 10 seconds, release

./axt-net.sh recovery        # Mac → static 192.168.1.5/24
./axt-flash.sh               # POST the image, wait for boot, show status

# 2. Open the mesh wizard:
#    http://192.168.1.1/cgi-bin/luci/admin/network/meshwizard
#    Set Mesh ID, channel, encryption, per-node bat0 IP → Save & Apply
```

Total operator time: ~2 minutes.

### Model B: stock OpenWrt + install scripts

Flash stock OpenWrt 25.12.4 from openwrt.org, then layer our packages
on top via apk. Useful when you want the upstream-vetted base and don't
want to maintain a custom image.

```
# Prerequisites:
#   ~/Downloads/stock-25.12-axt1800-factory.ubi   (from downloads.openwrt.org)
#   ~/Downloads/owrt-25.12-pkgs/*.apk             (custom .apks: wizard, alfred,
#                                                  openmanetd, tailscale)
#   ~/Downloads/owrt-25.12-pkgs/openmanet-feed/   (custom deps cache from VM)
#   Access to the OpenMANET build VM             (only for first cache populate)

# 1. Put AXT-1800 in u-boot recovery (same as Model A)
./axt-net.sh recovery
./axt-install.sh             # detects state, flashes stock, installs packages,
                             # runs post-install hardening, prints summary

# 2. Open the wizard (same URL as Model A)
```

Total operator time: ~4 minutes (extra time vs. Model A is the package
install + per-package reboot bisect).

## Scripts

| Script | Role |
|---|---|
| `axt-flash.sh` | Upload the all-in-one factory image to u-boot recovery, wait for first boot, summarize state. **Use this for Model A.** |
| `axt-install.sh` | One-button: stock-flash if needed → install 4 packages → harden → summarize. **Use this for Model B.** |
| `axt-bisect.sh` | Staged apk install with per-package reboot test. Called by `axt-install.sh`; usable standalone for debugging. Pulls custom deps from local cache (`~/Downloads/owrt-25.12-pkgs/openmanet-feed/`) or VM. |
| `axt-postinstall.sh` | Idempotent re-apply of openmanetd `dhcpconfigured=1` flags + mgmt AP setup. Called by `axt-install.sh`; runnable any time as recovery if state drifts. |
| `axt-meshcheck.sh` | Diagnostic. Confirms node is wired correctly and prints the exact Mesh ID/channel/encryption/IP a 2nd node needs to match. |
| `axt-net.sh` | Mac-side helper: switch the USB ethernet adapter between `recovery` mode (static 192.168.1.5/24 for u-boot) and `openmanet` mode (DHCP from OpenMANET's dnsmasq at 10.41.254.1). |
| `axt-find.sh` | ARP-sweep the AXT subnet looking for a responding host. Useful when you don't know what IP the router booted at. |

## First-boot uci-defaults: what the image actually does

When either delivery model finishes, the router's first boot runs the
package's uci-defaults script. It performs two operations idempotently
and then deletes itself:

1. **Pins openmanetd's address-reservation worker off.** Without this,
   openmanetd would (about 5 minutes after starting) allocate a
   `10.41.x.x` IP for this node from the mesh address pool, REWRITE
   `network.lan` to use that IP, and DROP `dhcp.lan`. We want the wired
   LAN to stay at 192.168.1.1/24 for management. Setting the three
   `*configured` flags to `'1'` makes the worker short-circuit at its
   own "already done" check.

2. **Stands up a 2.4 GHz management AP** on radio1 (SSID `openmanet-mgmt`,
   WPA3-SAE, passphrase `openmanet-mgmt-please-change`). Stock OpenWrt
   ships both radios disabled; this gives the operator a wireless way
   in independent of the wired side.

Both operations are safe no-ops if the relevant pieces aren't installed,
so the script is robust to package install order.

## Subnet layout / address conventions

| Network | Range | Role |
|---|---|---|
| Wired LAN / mgmt-AP | `192.168.1.0/24` (gateway `192.168.1.1`) | Operator access. Wired LAN + 2.4 GHz mgmt AP are both bridged into `br-lan`. |
| Mesh L3 (operator-set, optional) | typically `10.41.0.0/16` | If the wizard's "Mesh L3" field is filled, the script creates a separate `network.bat0_ip` interface using `bat0` as device, with the operator-supplied static IP. Per-node addresses (e.g. `10.41.1.1`, `10.41.1.2`, ...) are operator-coordinated. |
| Mesh L2 (always) | — | `bat0` batman-adv soft-iface, `phy0-mesh0` bound as hardif. Carries 802.11s on 5 GHz channel 36 (DFS-free) by default. |

## Verification

After `axt-flash.sh` or `axt-install.sh`, run:

```
./axt-meshcheck.sh
```

You should see ✓ on every line under "Stack health" and a ⚠ noting the
wizard hasn't been clicked yet (mesh consent gate). Once you Save & Apply
in the wizard, re-running `axt-meshcheck.sh` shows the mesh radio active,
batman-adv hardif bound, and reads back the exact settings (Mesh ID,
channel, encryption, per-node IP) you'd configure on a 2nd node to peer
with this one.

## Recovery

If the router becomes unreachable for any reason:

1. **u-boot recovery is always available.** Power off → hold reset → plug
   in → 10s → release. The pepe2k u-boot mod serves a recovery HTTP page
   at 192.168.1.1.
2. `./axt-net.sh recovery` to set Mac → static 192.168.1.5.
3. `./axt-flash.sh` (for Model A) or `./axt-install.sh` (Model B) to
   reflash + reinstall.

No matter how badly the running system gets misconfigured, u-boot is in
SPI flash and untouchable from the OS.
