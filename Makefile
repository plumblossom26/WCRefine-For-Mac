SHELL := /bin/bash

BUILD_DIR := build
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
CXX := xcrun clang++
CC := xcrun clang
COMMON_FLAGS := -arch arm64 -mmacosx-version-min=12.0 -isysroot "$(SDK)" -Wall -Wextra
OBJC_FLAGS := $(COMMON_FLAGS) -fobjc-arc -fblocks -std=gnu++20 -O2

PLUGIN_SOURCES := Sources/WCRefineMac.mm Sources/WCRPatchProfiles.mm \
	Sources/WCRRecallTip.mm Sources/WCRCodePatch.mm Sources/WCROriginalID.mm \
	Sources/WCRVoiceForward.mm Sources/WCRAvatarRound.mm \
	Sources/WCRMessageRepeat.mm Sources/WCRCommentRepeat.mm \
	Sources/WCRMessageCapture.mm Sources/WCRGroupLeaveMonitor.mm \
	Sources/WCRFloatingID.mm Sources/WCRScreenCapture.mm \
	Sources/WCRAutoUpdate.mm \
	Sources/WCRContactName.mm \
	Sources/WCRConfigStore.mm Sources/WCRContactPicker.mm \
	Sources/WCRSessionSelect.mm Sources/WCRRecallNotify.mm
CLI_SOURCES := Tools/wcrefine-check.m Sources/WCRPatchProfiles.mm Sources/WCRCodePatch.mm
APP_SOURCES := Sources/WCRefineForMacApp.mm Sources/WCRInstaller.mm \
	Sources/WCRMachOInjector.mm Sources/WCRPatchProfiles.mm Sources/WCRCodePatch.mm
APP_BUNDLE := $(BUILD_DIR)/WCRefine-for-Mac.app
APP_BINARY := $(APP_BUNDLE)/Contents/MacOS/WCRefine-for-Mac
APP_ICON := Resources/WCRefine.icns
APP_SOCIAL_ICONS := Resources/GitHubTemplate.png Resources/TelegramTemplate.png
APP_SIGNATURE := $(BUILD_DIR)/.WCRefine-for-Mac.signed
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null)
DIST_NAME := WCRefine-For-Mac-$(VERSION)
DIST_APP := dist/$(DIST_NAME)-macos-arm64.zip
DIST_SOURCE := dist/$(DIST_NAME)-source.tar.gz

.PHONY: all app clean check dist help

all: $(BUILD_DIR)/WCRefineMac.dylib $(BUILD_DIR)/wcrefine-check app

app: $(APP_SIGNATURE)

PET_JS := Resources/kimi-pet/pet.js
PET_STAGE := $(BUILD_DIR)/kimi-pet

$(PET_STAGE)/pet.js: $(PET_JS) Resources/kimi-pet/index.html
	@mkdir -p $(PET_STAGE)
	cp Resources/kimi-pet/index.html $(PET_STAGE)/index.html
	cp "$(PET_JS)" $(PET_STAGE)/pet.js

$(BUILD_DIR)/WCRefineMac.dylib: $(PLUGIN_SOURCES) Sources/WCRPatchProfiles.h Sources/WCRRecallTip.h Sources/WCRCodePatch.h Sources/WCROriginalID.h Sources/WCRVoiceForward.h Sources/WCRAvatarRound.h Sources/WCRMessageRepeat.h Sources/WCRCommentRepeat.h Sources/WCRMessageCapture.h Sources/WCRGroupLeaveMonitor.h Sources/WCRFloatingID.h Sources/WCRScreenCapture.h Sources/WCRAutoUpdate.h Sources/WCRContactName.h Sources/WCRConfigStore.h Sources/WCRContactPicker.h Sources/WCRSessionSelect.h Sources/WCRRecallNotify.h $(PET_STAGE)/pet.js
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(OBJC_FLAGS) -dynamiclib \
		-install_name @rpath/WCRefineMac.dylib \
		-framework Cocoa -framework Foundation -framework WebKit \
		-o $@ $(PLUGIN_SOURCES)
	codesign --force --sign - --timestamp=none $@

$(BUILD_DIR)/wcrefine-check: $(CLI_SOURCES) Sources/WCRPatchProfiles.h
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(OBJC_FLAGS) -x objective-c++ -framework Foundation -o $@ $(CLI_SOURCES)

$(APP_BINARY): $(APP_SOURCES) Sources/WCRInstaller.h Sources/WCRMachOInjector.h \
		Sources/WCRPatchProfiles.h Sources/WCRCodePatch.h Resources/Info.plist
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	$(CXX) $(OBJC_FLAGS) -framework Cocoa -framework Foundation \
		-o $@ $(APP_SOURCES)

$(APP_SIGNATURE): $(APP_BINARY) $(BUILD_DIR)/WCRefineMac.dylib $(PET_STAGE)/pet.js Resources/Info.plist $(APP_ICON) $(APP_SOCIAL_ICONS)
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp $(BUILD_DIR)/WCRefineMac.dylib $(APP_BUNDLE)/Contents/Resources/WCRefineMac.dylib
	cp $(APP_ICON) $(APP_BUNDLE)/Contents/Resources/WCRefine.icns
	cp $(APP_SOCIAL_ICONS) $(APP_BUNDLE)/Contents/Resources/
	rm -rf $(APP_BUNDLE)/Contents/Resources/wcrefine-pet \
		$(APP_BUNDLE)/Contents/Resources/kimi-pet
	cp -R $(PET_STAGE) $(APP_BUNDLE)/Contents/Resources/kimi-pet
	codesign --force --sign - --timestamp=none \
		$(APP_BUNDLE)/Contents/Resources/WCRefineMac.dylib
	codesign --force --sign - --timestamp=none $(APP_BUNDLE)
	codesign --verify --deep --strict $(APP_BUNDLE)
	# Finder 按 .app 目录的修改时间缓存图标。只替换包内文件不会改这个时间。
	touch $(APP_BUNDLE)
	@touch $@

check: all
	$(BUILD_DIR)/wcrefine-check --app /Applications/WeChat.app

dist: all
	@mkdir -p dist
	COPYFILE_DISABLE=1 tar -czf "$(DIST_SOURCE)" \
		--exclude='./build' --exclude='./private' --exclude='./dist' --exclude='./.git' \
		--exclude='.DS_Store' --exclude='__pycache__' --exclude='*.pyc' .
	ditto -c -k --norsrc --noextattr --keepParent $(APP_BUNDLE) "$(DIST_APP)"
	@tmp=$$(mktemp -d "$(TMPDIR)/wcrefine-dist.XXXXXX"); \
		unzip -q "$(DIST_APP)" -d "$$tmp" && \
		cmp -s "$(APP_ICON)" "$$tmp/WCRefine-for-Mac.app/Contents/Resources/WCRefine.icns" && \
		test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$$tmp/WCRefine-for-Mac.app/Contents/Info.plist")" = "WCRefine.icns" && \
		codesign --verify --deep --strict "$$tmp/WCRefine-for-Mac.app"; \
		status=$$?; rm -rf "$$tmp"; exit $$status
	cd dist && shasum -a 256 "$(notdir $(DIST_SOURCE))" "$(notdir $(DIST_APP))" \
		> "$(DIST_NAME)-sha256.txt"
	@printf 'source archive: %s\napp archive: %s\nchecksums: %s\n' \
		"$(CURDIR)/$(DIST_SOURCE)" "$(CURDIR)/$(DIST_APP)" \
		"$(CURDIR)/dist/$(DIST_NAME)-sha256.txt"

clean:
	rm -rf $(BUILD_DIR)

help:
	@printf '%s\n' \
		'  make all    构建 dylib、检查器与 WCRefine-for-Mac.app' \
		'  make app    只构建管理 App' \
		'  make check  检查 /Applications/WeChat.app' \
		'  make dist   生成带 SHA-256 的源码归档' \
		'  make clean  删除 build 目录'
