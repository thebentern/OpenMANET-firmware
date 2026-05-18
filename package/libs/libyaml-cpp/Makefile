#
# Local override of openwrt/packages' libs/libyaml-cpp/Makefile to fix
# an upstream packaging bug.
#
# Upstream's Package/libyaml-cpp/install block (as of openwrt-25.12) does:
#
#     $(CP) $(PKG_INSTALL_DIR)/usr/lib/libyaml-cpp.so.$(ABI_VERSION) $(1)/usr/lib/
#
# where ABI_VERSION=0.8. But `libyaml-cpp.so.0.8` in the cmake staging
# dir is a SYMLINK to `libyaml-cpp.so.0.8.0`. $(CP) — which expands to
# `cp -fpR` — copies symlinks AS symlinks; it does NOT dereference
# them. So the produced apk contains only the dangling symlink, never
# the actual `.so.0.8.0` payload.
#
# Result: every consumer of libyaml-cpp on a fresh OpenWrt 25.12
# install gets a broken binary. Discovered chasing a meshtasticd
# crash loop (`Error loading shared library libyaml-cpp.so.0.8: No
# such file or directory` — file exists but its target doesn't).
#
# Fix: use a glob `libyaml-cpp.so.*` that matches BOTH the .0.8
# symlink AND the .0.8.0 real payload. $(CP) preserves both
# correctly. Also bump PKG_RELEASE so apk-tools sees this as newer
# than the stock 0.8.0-r3 in the feed.
#
# This override should be removed once upstream openwrt/packages
# carries an equivalent fix; track:
#   https://github.com/openwrt/packages/blob/openwrt-25.12/libs/libyaml-cpp/Makefile
#
# Top-level package/ takes precedence over package/feeds/packages/
# at build time, so dropping this file here is sufficient.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=libyaml-cpp
PKG_VERSION:=0.8.0
PKG_RELEASE:=4

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/jbeder/yaml-cpp
PKG_SOURCE_VERSION:=$(PKG_VERSION)
PKG_MIRROR_HASH:=b81c7d39efa379a52c4cd7a6ee00e21b546e26284a44aa6d4b836e339c655803

PKG_MAINTAINER:= Steven Hessing <steven.hessing@gmail.com>
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_CPE_ID:=cpe:/a:yaml-cpp_project:yaml-cpp

CMAKE_INSTALL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/libyaml-cpp
  SECTION:=development
  CATEGORY:=Libraries
  TITLE:=libyaml-cpp
  URL:=https://github.com/jbeder/yaml-cpp
  DEPENDS:=+libstdcpp
  ABI_VERSION:=0.8
endef

define Package/libyaml-cpp/description
  yaml-cpp is a YAML parser and emitter in C++ matching the YAML 1.2 spec.
endef

# yaml-cpp 0.8.0's CMakeLists.txt has cmake_minimum_required(VERSION X.Y)
# with X.Y < 3.5, which CMake 4.x has removed support for. The error
# message itself suggests the workaround. Once yaml-cpp upstream bumps
# the floor (or openwrt ships a newer point release) this can drop.
CMAKE_OPTIONS += \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DYAML_BUILD_SHARED_LIBS=ON \
	-DYAML_CPP_BUILD_TESTS=OFF \
	-DYAML_CPP_BUILD_TOOLS=OFF

define Build/InstallDev
	$(call Build/InstallDev/cmake,$(1))
	$(SED) 's,/usr/include,$$$${prefix}/include,g' $(1)/usr/lib/pkgconfig/yaml-cpp.pc
	$(SED) 's,/usr/lib,$$$${exec_prefix}/lib,g' $(1)/usr/lib/pkgconfig/yaml-cpp.pc
endef

# Glob `libyaml-cpp.so.*` instead of `libyaml-cpp.so.$(ABI_VERSION)` —
# the latter is a symlink which $(CP) copies as a symlink and never
# pulls in the .so.0.8.0 payload it points to. The glob grabs both.
define Package/libyaml-cpp/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libyaml-cpp.so.* $(1)/usr/lib/
endef

$(eval $(call BuildPackage,libyaml-cpp))
