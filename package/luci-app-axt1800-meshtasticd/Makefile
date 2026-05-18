include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI meshtasticd configuration for GL.iNet GL-AXT1800
# Intentionally NOT depending on meshtasticd itself. meshtasticd is
# installed at runtime via the meshtastic-repo apk feed, so the LuCI
# page needs to exist *before* meshtasticd does — so the page can show
# the "not installed" state and the operator can spot what's wrong.
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
