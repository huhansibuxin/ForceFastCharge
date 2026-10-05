export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
FINALPACKAGE = 1
export TARGET = iphone:clang:16.5:15.0
# scheme 由 CI/环境变量决定（rootless 默认，roothide 构建时 CI 传 roothide）；
# 必须用 ?= 条件赋值——make 里普通赋值会覆盖环境变量，roothide job 会被打回 rootless
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME
include $(THEOS)/makefiles/common.mk

# 不配置 INSTALL_TARGET_PROCESSES；安装/升级由 postinst 单独重启 powerd。
export ARCHS = arm64 arm64e

# ---------- 1) 强制快充核心：仅注入 powerd，吞掉系统降流写 ----------
TWEAK_NAME = ForceFastCharge
ForceFastCharge_FILES = Tweak.xm
ForceFastCharge_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -fvisibility=hidden
ForceFastCharge_FRAMEWORKS = Foundation CoreFoundation IOKit
ForceFastCharge_LIBRARIES = substrate

# ---------- 2) 状态指示点：注入 SpringBoard，画灵动岛侧小圆点 ----------
TWEAK_NAME += ForceFastChargeIndicator
ForceFastChargeIndicator_FILES = FFIndicatorTweak.xm
ForceFastChargeIndicator_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -fvisibility=hidden
ForceFastChargeIndicator_FRAMEWORKS = Foundation UIKit CoreFoundation
ForceFastChargeIndicator_LIBRARIES = substrate

# ---------- 3) 设置面板 ----------
BUNDLE_NAME = ForceFastChargeSettings
ForceFastChargeSettings_FILES = Settings/FRootListController.m
ForceFastChargeSettings_INSTALL_PATH = /Library/PreferenceBundles
ForceFastChargeSettings_CFLAGS = -fobjc-arc -Iinclude
ForceFastChargeSettings_FRAMEWORKS = UIKit Foundation IOKit CoreFoundation
ForceFastChargeSettings_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

before-all::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_PROJECT_DIR)/build_scripts"$(ECHO_END)
	$(ECHO_NOTHING)if [ "$(THEOS_PACKAGE_SCHEME)" = "rootless" ]; then sed 's|@JBROOT@|/var/jb|g' "$(THEOS_PROJECT_DIR)/scripts/postinst.in" > "$(THEOS_PROJECT_DIR)/build_scripts/postinst"; sed 's|@JBROOT@|/var/jb|g' "$(THEOS_PROJECT_DIR)/scripts/prerm.in" > "$(THEOS_PROJECT_DIR)/build_scripts/prerm"; else sed 's|@JBROOT@||g' "$(THEOS_PROJECT_DIR)/scripts/postinst.in" > "$(THEOS_PROJECT_DIR)/build_scripts/postinst"; sed 's|@JBROOT@||g' "$(THEOS_PROJECT_DIR)/scripts/prerm.in" > "$(THEOS_PROJECT_DIR)/build_scripts/prerm"; fi$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/build_scripts/postinst" "$(THEOS_PROJECT_DIR)/build_scripts/prerm"$(ECHO_END)

# postinst/prerm 必须在 after-stage 拷进 staging 的 DEBIAN/。
# 教训：靠 before-all 动态创建 layout/DEBIAN 在多 target 工程里不可靠，
# 产物 deb 的 control.tar 里会丢失 postinst（实测 ChargeControl 单 target 可以，
# 本工程三 target 丢失）。改用上游 sbcpu 已验证的 after-stage + THEOS_STAGING_DIR 方案。
after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/build_scripts/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/build_scripts/prerm" "$(THEOS_STAGING_DIR)/DEBIAN/prerm"$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/prerm"$(ECHO_END)

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/usr/local/share/ForceFastCharge"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ForceFastChargeSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/ForceFastChargeSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/ForceFastChargeSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp ForceFastChargeIndicator.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ForceFastChargeIndicator.plist"$(ECHO_END)
