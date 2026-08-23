# Development Makefile for MinimalReport (macOS).
#
#   make                 Build a debug .app and launch it
#   make run             Same as the default
#   make build           Compile and bundle without launching
#   make stop            Quit a running instance
#   make clean           Remove build artifacts
#
# Override CONFIG for an optimized local build:
#   make CONFIG=release

APP        := MinimalReport
MAC_DIR    := Mac
APP_BUNDLE := $(MAC_DIR)/$(APP).app
CONFIG     ?= debug
BINARY     := $(MAC_DIR)/.build/$(CONFIG)/$(APP)

.DEFAULT_GOAL := run

.PHONY: run build stop clean help

help:
	@echo "MinimalReport — development targets"
	@echo
	@echo "  make / make run   Build (debug) and launch"
	@echo "  make build        Compile and bundle, do not launch"
	@echo "  make stop         Quit a running instance"
	@echo "  make clean        Remove .build and the .app bundle"
	@echo
	@echo "  CONFIG=release make run   Optimized build + launch"

run: build
	@echo "▸ Launching $(APP).app"
	open "$(APP_BUNDLE)"

build:
	@echo "▸ Building $(APP) ($(CONFIG))"
	cd "$(MAC_DIR)" && swift build -c $(CONFIG)
	@echo "▸ Bundling $(APP).app"
	-pkill -x "$(APP)"
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(BINARY)" "$(APP_BUNDLE)/Contents/MacOS/$(APP)"
	cp "$(MAC_DIR)/Resources/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	-cp "$(MAC_DIR)/Resources/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	codesign --force --deep --sign - "$(APP_BUNDLE)" 2>/dev/null || true
	@echo "✓ $(APP_BUNDLE)"

stop:
	-pkill -x "$(APP)"

clean:
	-pkill -x "$(APP)"
	cd "$(MAC_DIR)" && swift package clean
	rm -rf "$(APP_BUNDLE)" "$(MAC_DIR)/.build"
