# OpenMANET operator tooling

Per-board operator scripts and docs for the OpenMANET-firmware fork. All
boards share the same LuCI packages (`package/luci-app-openmanet-*`),
mesh stack (batman-adv + 802.11s + alfred + openmanetd), and apk-based
delivery for meshtasticd. What differs per board is the kernel /
firmware blob set in `boards/<board>/target_diffconfig` and the
flash-recovery flow in `contrib/<board>/`.

## Supported boards

| Board | SoC | Target | Flash | Recovery |
|---|---|---|---|---|
| [GL.iNet GL-AXT1800 (Slate AX)](axt1800/README.md) | Qualcomm IPQ6018 | qualcommax/ipq60xx | 128 MB NAND | pepe2k u-boot mod |
| [GL.iNet GL-MT3000 (Beryl AX)](mt3000/README.md) | MediaTek MT7981B | mediatek/filogic | 256 MB NAND | GL.iNet stock u-boot |

Both boards run `aarch64_cortex-a53` and share every binary apk in the
image — same `luci-app-openmanet-*`, same `meshtasticd` (from
[openwrt.meshtastic.org](https://openwrt.meshtastic.org)), same
`tailscale`, same `v4l2rtspserver`. Only the kernel/driver/firmware
layer differs.

## Shared concepts (read once, applies to every board)

### Mesh stack

- **802.11s** on the 5 GHz radio (channel 36, DFS-free, by default) is
  the L2 mesh.
- **batman-adv** rides on top as the L3 routing fabric (BATMAN_V).
- **alfred** does gossip / hostname distribution across the mesh.
- **openmanetd** is the management daemon (web UI on ports 8080/8081/8087).

The Mesh Wizard (LuCI: Mesh → Wizard) is the single-page operator surface
for this whole stack. Set Mesh ID, channel, encryption key, per-node
`bat0` IP → Save & Apply. Same wizard on every supported board; the
underlying uci-defaults script auto-detects the 2.4 GHz radio for the
mgmt-AP and the 5 GHz radio for mesh.

### Subnet layout

| Network | Range | Role |
|---|---|---|
| Wired LAN + mgmt-AP (`br-lan`) | `192.168.1.0/24` (gateway `.1`) | Operator access. Wired LAN + 2.4 GHz mgmt AP bridged. |
| Mesh L3 (optional, operator-set) | typically `10.41.0.0/16` | If wizard's "Mesh L3" field is filled, the script creates `network.bat0_ip` over `bat0` with the operator's static IP. |
| Mesh L2 | n/a | `bat0` batman-adv softif, `phy0-mesh0` (or per-board equivalent — auto-detected by LuCI pages) as the 802.11s hardif. |

### LuCI surface

Six pages under the Mesh menu (LuCI: Mesh → ...):

| Page | URL | Purpose |
|---|---|---|
| Status | `admin/mesh/status` | Read-only: who's on the mesh, link quality, batman state, log tail |
| Wizard | `admin/mesh/wizard` | One-page configuration of the whole mesh stack |
| Camera | `admin/mesh/camera` | USB UVC camera → RTSP stream + QR code + live preview |
| ATAK / CoT | `admin/mesh/cot` | Multicast posture, joined groups, per-iface counters, ATAK reference |
| meshtasticd | `admin/mesh/meshtasticd` | LoRa daemon: profile picker, MAC source, web UI, log tail |
| Tailscale | `admin/mesh/tailscale` | Tunnel state, fleet enrollment via pre-auth key, peer list |

The status, CoT, and meshtasticd pages auto-detect interface names so
they work across both ath11k (AXT-1800) and mt76 (MT3000) hardware
without per-board tuning.

### Tailscale fleet setup (SAR / multi-router ops)

The "bridge an off-grid mesh to a remote command center via someone's
phone hotspot" workflow is documented end-to-end in
[`axt1800/README.md`](axt1800/README.md#tailscale-fleet-setup-for-sar--multi-router-ops).
The Tailscale page on every board takes a pre-auth key and enrolls
non-interactively with the right hostname + tags + advertised routes
in one Apply.

The pattern works the same regardless of which board you're enrolling
— only ONE router in the fleet needs WAN/internet, and it bridges the
rest via Tailscale subnet routing.

## Building a board image

```sh
# In a checked-out OpenMANET-firmware tree on the build VM:
./scripts/openmanet_setup.sh -i -b glinet-axt1800     # or glinet-mt3000
make defconfig
make -j$(nproc)

# Image lands in:
#   bin/targets/qualcommax/ipq60xx/openwrt-...glinet_gl-axt1800-...-factory.ubi
#   bin/targets/mediatek/filogic/openwrt-...glinet_gl-mt3000-...-factory.bin
```

Then follow the per-board flash instructions linked at the top of this
file.

## Adding a third board

The infrastructure now supports this cleanly:

1. Add `boards/<new-board>/target_diffconfig` (copy from an existing
   board, swap target/subtarget + firmware blob + WiFi driver lines).
2. Add `contrib/<new-board>/` scripts (start by mirroring an existing
   board's flash + net helpers; tweak the recovery-detection regex
   if the new board's u-boot variant differs).
3. Add a row to the "Supported boards" table above + a per-board
   README in `contrib/<new-board>/README.md`.
4. No package changes required — all `luci-app-openmanet-*` packages
   are board-agnostic.
