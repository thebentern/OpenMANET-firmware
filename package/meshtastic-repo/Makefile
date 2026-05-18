include $(TOPDIR)/rules.mk

PKG_NAME:=meshtastic-repo
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/meshtastic-repo
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Meshtastic apk repo + signing key + first-boot installer
  URL:=https://openwrt.meshtastic.org/
  PKGARCH:=all
endef

define Package/meshtastic-repo/description
 Ships the official Meshtastic OpenWrt apk repository configuration
 plus the signing key for binary package verification, so the operator
 can run `apk update && apk add meshtasticd` against meshtastic's
 pre-built artifacts rather than compiling them from source.

 Also includes a /etc/uci-defaults script that attempts the install
 on first boot. If the router has internet at boot, meshtasticd is
 installed and started automatically. If not, the install retries
 on subsequent boots until it succeeds.
endef

define Build/Compile
endef

define Package/meshtastic-repo/install
	$(CP) ./root/* $(1)/
endef

$(eval $(call BuildPackage,meshtastic-repo))
