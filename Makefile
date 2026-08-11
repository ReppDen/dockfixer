APP_NAME  := DockFix
BUNDLE_ID := com.github.drepp.dockfix
VERSION   := 0.1.0

# "-" means an ad-hoc signature, which is all a release build needs. macOS ties
# the Accessibility grant to the code hash of an ad-hoc signed app, so every
# rebuild costs another trip through System Settings. During development, point
# this at a self-signed code-signing certificate to get a stable identity and
# keep the grant across rebuilds:
#
#   make app SIGN_IDENTITY="DockFix Dev"
#
# See the Development section of the README for creating that certificate.
SIGN_IDENTITY ?= -

BUILD_DIR := build
APP       := $(BUILD_DIR)/$(APP_NAME).app
ZIP       := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).zip

ICONSET := $(BUILD_DIR)/AppIcon.iconset
ICNS    := $(BUILD_DIR)/AppIcon.icns

.PHONY: all app icon run test install uninstall reset-tcc zip clean help

all: app

## icon: draw the app icon and build AppIcon.icns
icon: $(ICNS)

$(ICNS): Scripts/make-icon.swift
	mkdir -p "$(ICONSET)"
	swift Scripts/make-icon.swift "$(BUILD_DIR)/icon-1024.png"
	# iconutil insists on exactly these names and sizes.
	sips -z 16 16     "$(BUILD_DIR)/icon-1024.png" --out "$(ICONSET)/icon_16x16.png"      >/dev/null
	sips -z 32 32     "$(BUILD_DIR)/icon-1024.png" --out "$(ICONSET)/icon_16x16@2x.png"   >/dev/null
	sips -z 32 32     "$(BUILD_DIR)/icon-1024.png" --out "$(ICONSET)/icon_32x32.png"      >/dev/null
	sips -z 64 64     "$(BUILD_DIR)/icon-1024.png" --out "$(ICONSET)/icon_32x32@2x.png"   >/dev/null
	sips -z 128 128   "$(BUILD_DIR)/icon-1024.png" --out "$(ICONSET)/icon_128x128.png"    >/dev/null
	sips -z 256 256   "$(BUILD_DIR)/icon-1024.png" --out "$(ICONSET)/icon_128x128@2x.png" >/dev/null
	sips -z 256 256   "$(BUILD_DIR)/icon-1024.png" --out "$(ICONSET)/icon_256x256.png"    >/dev/null
	sips -z 512 512   "$(BUILD_DIR)/icon-1024.png" --out "$(ICONSET)/icon_256x256@2x.png" >/dev/null
	sips -z 512 512   "$(BUILD_DIR)/icon-1024.png" --out "$(ICONSET)/icon_512x512.png"    >/dev/null
	cp "$(BUILD_DIR)/icon-1024.png" "$(ICONSET)/icon_512x512@2x.png"
	iconutil -c icns "$(ICONSET)" -o "$(ICNS)"
	@echo "built $(ICNS)"

## app: build a release binary and wrap it in a .app bundle
app: $(ICNS)
	swift build -c release
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp "$(ICNS)" "$(APP)/Contents/Resources/AppIcon.icns"
	sed -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' -e 's/__VERSION__/$(VERSION)/g' \
		Resources/Info.plist > "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(APP)"
	@echo "built $(APP) (signed with '$(SIGN_IDENTITY)')"

## run: build and launch
run: app
	open "$(APP)"

## test: run the unit tests (plain executable — no Xcode needed)
test:
	swift run DockFixTests

## install: copy the bundle into /Applications
install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	@echo "installed /Applications/$(APP_NAME).app"

## uninstall: remove the installed bundle and revoke its Accessibility grant
uninstall:
	rm -rf "/Applications/$(APP_NAME).app"
	-tccutil reset Accessibility "$(BUNDLE_ID)"

## reset-tcc: clear the Accessibility grant so the next launch asks again
reset-tcc:
	tccutil reset Accessibility "$(BUNDLE_ID)"
	@echo "Accessibility grant for $(BUNDLE_ID) cleared"

## zip: package the bundle for a GitHub release, preserving the signature
zip: app
	rm -f "$(ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(ZIP)"
	@shasum -a 256 "$(ZIP)"

## clean: remove build products
clean:
	rm -rf "$(BUILD_DIR)" .build

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  make /'
