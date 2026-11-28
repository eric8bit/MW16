export THEOS_PACKAGE_SCHEME = roothide
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0
export DEBUG = 0

TWEAK_NAME = MW16Stage11
MW16Stage11_FILES = Tweak.x
MW16Stage11_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
MW16Stage11_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
