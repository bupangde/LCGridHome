ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LCGridHome
LCGridHome_FILES = LCGridHome.m
LCGridHome_FRAMEWORKS = UIKit Foundation LocalAuthentication QuartzCore CoreGraphics CoreFoundation
LCGridHome_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

# 构建后 dylib 在 .theos/obj/debug/LCGridHome.dylib（release 在 .theos/obj/ 下）
# LiveContainer 只需要这个 dylib 本身，不需要安装 .deb。
