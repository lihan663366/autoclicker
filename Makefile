# AutoClicker — 越狱自动连点器
#
# 注入目标由 BUNDLE_ID 决定，默认 SpringBoard（在任何 App 上都能用）：
#
#     make package                                   # SpringBoard，全局生效
#     make package BUNDLE_ID=com.tencent.xin         # 只注入微信
#     make package BUNDLE_ID=com.a,com.b             # 同时注入多个 App
#
# 注意：App 进程没有 HID entitlement，注入通道会自动切换成
# -[UIApplication _enqueueHIDEvent:]，代码里已处理，不需要你改任何东西。
#
# rootless 越狱（Dopamine / palera1n-rootless / XinaA15）用默认值。
# rootful 越狱（unc0ver / checkra1n / palera1n-rootful）加 ROOTFUL=1 编译：
#     make package ROOTFUL=1
# 装错这一项的表现是"包能装、但完全没效果"—— dylib 落在 /var/jb 下，
# 老越狱只读根目录，Substrate 永远加载不到它。
ifeq ($(ROOTFUL),1)
THEOS_PACKAGE_SCHEME =
else
THEOS_PACKAGE_SCHEME = rootless
endif

BUNDLE_ID ?= com.apple.springboard

# bundle id 只允许字母数字和 . _ , - ，否则会破坏下面生成的 plist
ifeq ($(shell echo '$(BUNDLE_ID)' | grep -qE '^[A-Za-z0-9._,-]+$$' && echo ok),)
$(error BUNDLE_ID 只能包含字母、数字和 . _ , - ：'$(BUNDLE_ID)')
endif

# Theos 只认静态的 Filter plist，这里按 BUNDLE_ID 生成一份（逗号分隔转成数组）
BUNDLE_LIST := $(shell echo '$(BUNDLE_ID)' | sed 's/[[:space:]]//g; s/,/","/g')
$(shell printf '{ Filter = { Bundles = ( "%s" ); }; }\n' '$(BUNDLE_LIST)' > AutoClicker.plist)

TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# 只有在 SpringBoard 版本里，安装后重启 SpringBoard 才有意义
ifneq ($(findstring com.apple.springboard,$(BUNDLE_ID)),)
INSTALL_TARGET_PROCESSES = SpringBoard
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoClicker
AutoClicker_FILES = Tweak.xm ACCore.m ACUI.m ACDebug.m
AutoClicker_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
AutoClicker_FRAMEWORKS = UIKit Foundation CoreGraphics AudioToolbox
AutoClicker_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
