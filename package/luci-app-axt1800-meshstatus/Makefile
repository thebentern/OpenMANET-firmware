include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI mesh status dashboard for GL.iNet GL-AXT1800
# Read-mostly diagnostic page. batctl-full and iw-full are already pulled in
# by the meshwizard package; we don't re-list them here to keep deps minimal.
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
