include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI USB camera RTSP setup
LUCI_DEPENDS:=+luci-base +v4l2rtspserver +v4l-utils
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
