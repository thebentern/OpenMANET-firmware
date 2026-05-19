# OpenMANET on GL.iNet GL-MT3000 (Beryl AX)

Operator-side tooling for installing OpenMANET on the GL.iNet GL-MT3000
(MediaTek MT7981B, mediatek/filogic target). Mirrors the AXT-1800
workflow with two differences:

1. **Recovery flow uses GL.iNet's stock u-boot recovery** at 192.168.1.1
   (not the pepe2k mod the AXT-1800 ships). Same upload endpoint, same
   `firmware` form field — different branding on the page, slightly
   different button-hold timing for entering recovery (~5 sec vs 10).
2. **Different image filename**: factory image is
   `openwrt-mediatek-filogic-glinet_gl-mt3000-squashfs-factory.bin`
   instead of the AXT's `-factory.ubi`.

Everything else — LuCI pages, mesh wizard, ATAK / CoT support,
Tailscale, meshtasticd, camera — is shared with the AXT-1800 because
the architectures match (both aarch64_cortex-a53).

## What gets installed

Identical inventory to the AXT-1800 image. See
[`contrib/axt1800/README.md`](../axt1800/README.md#what-gets-installed)
for the full list. Notable differences:

- **NAND budget**: MT3000 has 256 MB vs AXT-1800's 128 MB. The wizard
  package can be auto-installed in the factory image (`=y` instead of
  `=m`) — no post-flash apk-install needed.
- **No PWM fan**: MT3000 is fanless; the `kmod-hwmon-pwmfan` module is
  omitted.
- **WiFi driver**: mt76 + mt7981-firmware instead of ath11k + ipq6018
  firmware. Mesh-interface name auto-detected via `iw dev` in the
  status/CoT pages.

## Delivery

```sh
# 1. Build the factory image:
#    boards/glinet-mt3000/target_diffconfig + openwrt-25.12 tree → 
#    bin/targets/mediatek/filogic/openwrt-...-glinet_gl-mt3000-squashfs-factory.bin
#
# 2. Put it at ~/Downloads/openmanet-mt3000-factory.bin (or override via
#    $MT3000_IMAGE)
#
# 3. Enter u-boot recovery on the MT3000:
#    - Power off
#    - Hold reset button
#    - Plug power back in (while still holding reset)
#    - Keep holding 4-5 seconds, release
#    - LED goes solid → blinking → solid = recovery mode active
#
# 4. Switch Mac side to recovery static IP:
./mt3000-net.sh recovery

# 5. Flash:
./mt3000-flash.sh             # POST the image, wait for boot, show status

# 6. Open the mesh wizard:
#    http://192.168.1.1/cgi-bin/luci/admin/mesh/wizard
#    Set Mesh ID, channel, encryption, per-node bat0 IP → Save & Apply
```

Total operator time: ~3 minutes (faster than the AXT-1800's ~4 because
the MT3000 boots faster and uses smaller NAND I/O during sysupgrade).

## Scripts

| Script | Role |
|---|---|
| `mt3000-flash.sh` | Upload the factory image to GL.iNet u-boot recovery, wait for first boot, summarize state. |
| `mt3000-net.sh` | Mac-side helper: switch the USB ethernet adapter between `recovery` mode (static 192.168.1.5/24) and `openmanet` mode (DHCP from OpenMANET's dnsmasq). Same logic as `axt-net.sh`. |

The AXT-1800-side scripts `axt-install.sh`, `axt-bisect.sh`,
`axt-postinstall.sh`, `axt-meshcheck.sh`, `axt-find.sh` haven't been
ported to MT3000 yet — they assume the AXT's stock-flash-then-apk-
install model (Model B) which the MT3000 doesn't need because the
wizard package is in the factory image by default. If you need any of
those for MT3000 diagnostics, the bodies are board-agnostic — symlink
or copy from `contrib/axt1800/`.

## Recovery

If the MT3000 becomes unreachable:

1. **GL.iNet u-boot recovery is always available** as a hardware-level
   fallback. Power off → hold reset → plug in → hold 4-5 sec → release.
   The stock u-boot serves the recovery HTTP page at 192.168.1.1.
2. `./mt3000-net.sh recovery` to set Mac → static 192.168.1.5.
3. `./mt3000-flash.sh` to reflash.

GL.iNet's recovery page in u-boot lives in the SPI flash boot sector
and is not touched by sysupgrade. If your image bricks the OS partition,
the recovery interface still comes up.

## See also

- [`../axt1800/README.md`](../axt1800/README.md) — the AXT-1800
  counterpart, plus shared concepts (Tailscale fleet setup, mesh
  subnet conventions, ATAK integration).
- [`../README.md`](../README.md) — top-level multi-board overview.
