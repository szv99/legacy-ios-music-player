THEOS ?= $(HOME)/theos
TARGET := iphone:clang:9.3:7.1
ARCHS := armv7
INSTALL_TARGET_PROCESSES = Player7

# The iOS 9.3 SDK's module maps don't build with the current clang; use plain headers.
override MODULESFLAGS :=

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Player7

Player7_FILES = $(wildcard Sources/*.m)
Player7_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AVFoundation CoreMedia CoreImage MediaPlayer Security MediaToolbox Accelerate JavaScriptCore
# -Wunguarded-availability flags any API newer than iOS 7 used without a runtime check.
Player7_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wunguarded-availability -Werror=unguarded-availability -Wno-strict-prototypes
Player7_CODESIGN_FLAGS = -Sentitlements.plist

# Theos searches the SDK's PrivateFrameworks first, and the iOS 9.3 SDK has a header-less
# JavaScriptCore.framework there that hides the public one; point <JavaScriptCore/...> at the real headers.
JSC_INCLUDE = $(THEOS_PROJECT_DIR)/.theos/include
Player7_CFLAGS += -I$(JSC_INCLUDE) -Wno-expansion-to-defined

include $(THEOS_MAKE_PATH)/application.mk

before-all::
	@mkdir -p $(JSC_INCLUDE) && ln -sfn $(SYSROOT)/System/Library/Frameworks/JavaScriptCore.framework/Headers $(JSC_INCLUDE)/JavaScriptCore

after-install::
	install.exec "su mobile -c uicache; uiopen player7://"
