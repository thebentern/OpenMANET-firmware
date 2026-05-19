include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Tailscale dashboard
# Doesn't depend on tailscale here — tailscale is independently in the
# diffconfig and may exist on the device. If it isn't, the page just
# shows a "not installed" state.
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
