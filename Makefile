TARGET := iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyCustomCC

MyCustomCC_FILES = Tweak.x
MyCustomCC_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
MyCustomCC_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
