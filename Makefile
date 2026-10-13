APP_NAME  := DockFixer
BUNDLE_ID := com.github.reppden.dockfixer
VERSION   := 0.1.0

# "-" means an ad-hoc signature, which is all a release build needs. macOS ties
# the Accessibility grant to the code hash of an ad-hoc signed app, so every
# rebuild costs another trip through System Settings. During development, point
# this at a self-signed code-signing certificate to get a stable identity and
# keep the grant across rebuilds:
#
#   make app SIGN_IDENTITY="DockFixer Dev"
#
# See the Development section of the README for creating that certificate.
SIGN_IDENTITY ?= -

# Baked into the bundle. "make dev" overrides it with "debug" so a local build
# always explains itself; a release stays at "info", where every line is an
# event rather than a running commentary.
LOG_LEVEL ?= info

# PostHog project keys for the usage statistics (Usage.swift): one project for
# releases, one for local builds, so that a day of development is not a day
# of use. Write-only keys, so they can live here. Empty means nothing is sent.
USAGE_KEY     ?=
DEV_USAGE_KEY ?=

BUILD_DIR := build
APP       := $(BUILD_DIR)/$(APP_NAME).app
ZIP       := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).zip

ICONSET := $(BUILD_DIR)/AppIcon.iconset
ICNS    := $(BUILD_DIR)/AppIcon.icns

DEV_IDENTITY := DockFixer Dev

.PHONY: all app icon readme-icon run test install uninstall dev dev-cert reset-tcc zip clean help

all: app

## dev-cert: create a self-signed code-signing identity for local builds
dev-cert:
	./Scripts/dev-cert.sh

## dev: build and install signed with the local identity, with debug logging, so the Accessibility grant survives rebuilds
dev: dev-cert
	$(MAKE) install SIGN_IDENTITY="$(DEV_IDENTITY)" LOG_LEVEL=debug USAGE_KEY="$(DEV_USAGE_KEY)"

## icon: draw the app icon and build AppIcon.icns
icon: $(ICNS)

## readme-icon: redraw docs/icon.png, the copy of the icon the README shows
readme-icon: $(ICNS)
	sips -z 512 512 "$(BUILD_DIR)/icon-1024.png" --out docs/icon.png >/dev/null
	@echo "wrote docs/icon.png"

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
	# Octicons' GitHub mark (MIT), for the GitHub button.
	cp Resources/github-mark.pdf "$(APP)/Contents/Resources/github-mark.pdf"
	sed -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' -e 's/__VERSION__/$(VERSION)/g' \
		-e 's/__LOG_LEVEL__/$(LOG_LEVEL)/g' -e 's/__USAGE_KEY__/$(USAGE_KEY)/g' \
		Resources/Info.plist > "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(APP)"
	@echo "built $(APP) (signed with '$(SIGN_IDENTITY)')"

## run: build and launch
run: app
	open "$(APP)"

## test: run the unit tests (plain executable — no Xcode needed)
test:
	swift run DockFixerTests

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
