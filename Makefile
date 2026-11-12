# AutoClicker — 越狱自动连点器
#
# rootless 越狱（Dopamine / palera1n-rootless / XinaA15）保持下面这行开启。
# 老式 rootful 越狱（unc0ver / checkra1n / palera1n-rootful）请把它注释掉。
THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoClicker
AutoClicker_FILES = Tweak.xm ACCore.m ACUI.m
AutoClicker_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
AutoClicker_FRAMEWORKS = UIKit Foundation CoreGraphics
AutoClicker_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
