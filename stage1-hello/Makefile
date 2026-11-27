export THEOS_PACKAGE_SCHEME = roothide
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0
export DEBUG = 0

TWEAK_NAME = MW16Stage1
MW16Stage1_FILES = Tweak.x
MW16Stage1_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
MW16Stage1_FRAMEWORKS = UIKit Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
