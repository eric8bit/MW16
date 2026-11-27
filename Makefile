export THEOS_PACKAGE_SCHEME = roothide
# 只编 arm64：包架构会变成 iphoneos-arm64，装得更省事；
# arm64e 设备跑 arm64 代码没问题。
export ARCHS = arm64
export TARGET = iphone:clang:16.5:15.0
export DEBUG = 0

TWEAK_NAME = MW16
MW16_FILES = $(wildcard src/*.m) src/Tweak.x
MW16_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
MW16_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
