define Device/8devices_mango-dvk
	$(call Device/FitImageLzma)
	DEVICE_VENDOR := 8devices
	DEVICE_MODEL := Mango-DVK
	IMAGE_SIZE := 27776k
	BLOCKSIZE := 64k
	SOC := ipq6010
	SUPPORTED_DEVICES += 8devices,mango
	IMAGE/sysupgrade.bin := append-kernel | pad-to 64k | append-rootfs | pad-rootfs | check-size | append-metadata
	DEVICE_PACKAGES := ipq-wifi-8devices_mango
endef
TARGET_DEVICES += 8devices_mango-dvk

define Device/cambiumnetworks_xe3-4
       $(call Device/FitImage)
       $(call Device/UbiFit)
       DEVICE_VENDOR := Cambium Networks
       DEVICE_MODEL := XE3-4
       BLOCKSIZE := 128k
       PAGESIZE := 2048
       DEVICE_DTS_CONFIG := config@cp01-c3-xv3-4
       SOC := ipq6010
       DEVICE_PACKAGES := ipq-wifi-cambiumnetworks_xe34 ath11k-firmware-qcn9074 kmod-ath11k-pci
endef
TARGET_DEVICES += cambiumnetworks_xe3-4

define Device/netgear_wax214
       $(call Device/FitImage)
       $(call Device/UbiFit)
       DEVICE_VENDOR := Netgear
       DEVICE_MODEL := WAX214
       BLOCKSIZE := 128k
       PAGESIZE := 2048
       DEVICE_DTS_CONFIG := config@cp03-c1
       SOC := ipq6010
       DEVICE_PACKAGES := ipq-wifi-netgear_wax214
endef
TARGET_DEVICES += netgear_wax214

define Device/yuncore_fap650
    $(call Device/FitImage)
    $(call Device/UbiFit)
    DEVICE_VENDOR := Yuncore
    DEVICE_MODEL := FAP650
    BLOCKSIZE := 128k
    PAGESIZE := 2048
    DEVICE_DTS_CONFIG := config@cp03-c1
    SOC := ipq6018
    DEVICE_PACKAGES := ipq-wifi-yuncore_fap650
    IMAGES := factory.ubi factory.ubin sysupgrade.bin
    IMAGE/factory.ubin := append-ubi | qsdk-ipq-factory-nand
endef
TARGET_DEVICES += yuncore_fap650

define Device/glinet_gl-axt1800
	$(call Device/FitImage)
	$(call Device/UbiFit)
	DEVICE_VENDOR := GL.iNet
	DEVICE_MODEL := GL-AXT1800
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	# Hard cap so the build fails loud if the squashfs+kernel can't fit
	# in a comfortable rootfs UBI volume. Discovered the hard way: sysupgrade
	# silently fails to grow the rootfs UBI volume when rootfs_data already
	# spans all free LEBs, leaving the device booting from the old rootfs.
	# Cap of ~45 MB leaves enough room in the 119 MB rootfs partition for
	# a 7 MB kernel + 45 MB rootfs + ~65 MB rootfs_data after factory write.
	IMAGE_SIZE := 46080k
	DEVICE_DTS_CONFIG := config@cp03-c1
	SOC := ipq6018
	DEVICE_PACKAGES := ipq-wifi-glinet_gl-axt1800 kmod-hwmon-pwmfan
	SUPPORTED_DEVICES += glinet,axt1800
endef
TARGET_DEVICES += glinet_gl-axt1800
