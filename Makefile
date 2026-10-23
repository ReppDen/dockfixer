APP_NAME  := DockFixer
BUNDLE_ID := com.github.reppden.dockfixer
# release.yml passes the tag's version; local builds say "development".
VERSION   := development

# "-" means an ad-hoc signature: enough for CI to check that the bundle builds.
# macOS ties the Accessibility grant to the code hash of an ad-hoc signed app,
# so every rebuild costs another trip through System Settings. A self-signed
# certificate gives a stable identity instead and the grant survives rebuilds:
# "make dev" signs with a local one (Scripts/dev-cert.sh), and the release
# workflow signs with the project's release certificate.
#
#   make app SIGN_IDENTITY="DockFixer Dev"
#
# See CONTRIBUTING.md for why this matters.
SIGN_IDENTITY ?= -

# Releases run on Apple silicon and Intel alike. "make dev" builds only for the
# machine it runs on, which is half the wait.
ARCHS ?= arm64 x86_64

# Baked into the bundle. "make dev" overrides it with "debug" so a local build
# always explains itself; a release stays at "info", where every line is an
# event rather than a running commentary.
LOG_LEVEL ?= info

# PostHog project key for the usage statistics (Usage.swift). One project for
# every build: a development Mac is one more installation, and on the free plan
# a second project would need a card. The key is write-only, but it stays out of
# the repository so that a fork sends nothing here; a release gets it from the
# USAGE_KEY secret, a local build from the environment. Empty means nothing is sent.
USAGE_KEY ?=

# Where Sparkle looks for updates. Empty by default, and an empty feed means
# the build never checks: a contributor's build is signed with some other
# certificate than a release, and updating itself to a release would swap
# its signature and lose the Accessibility grant. The release workflow passes
# the real one, appcast.xml attached to the newest GitHub release:
#
#   FEED_URL=https://github.com/ReppDen/dockfixer/releases/latest/download/appcast.xml
#
# A local test of the update path points it at a server of its own.
FEED_URL ?=

# The public half of the EdDSA key every update is signed with (Sparkle's
# SUPublicEDKey). Public by nature; the private half is the SPARKLE_ED_KEY
# secret of the release workflow. A fork that publishes updates sets its own.
ED_PUBLIC_KEY ?= 4j2I3P+pHYWICIXVlsoJjEyL6ESMrZOxlZ0/Igrvjv8=

BUILD_DIR := build
APP       := $(BUILD_DIR)/$(APP_NAME).app
ZIP       := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).zip

ICONSET := $(BUILD_DIR)/AppIcon.iconset
ICNS    := $(BUILD_DIR)/AppIcon.icns

DEV_IDENTITY := DockFixer Dev

SPARKLE := $(APP)/Contents/Frameworks/Sparkle.framework

.PHONY: all app icon readme-icon readme-hero run test install uninstall dev dev-cert reset-tcc zip clean help

all: app

## dev-cert: create a self-signed code-signing identity for local builds
dev-cert:
	./Scripts/dev-cert.sh

## dev: build and install signed with the local identity, with debug logging, so the Accessibility grant survives rebuilds
dev: dev-cert
	$(MAKE) install SIGN_IDENTITY="$(DEV_IDENTITY)" LOG_LEVEL=debug USAGE_KEY="$(USAGE_KEY)" FEED_URL="$(FEED_URL)" ARCHS="$$(uname -m)"

## icon: draw the app icon and build AppIcon.icns
icon: $(ICNS)

## readme-icon: redraw docs/icon.png, the copy of the icon the README shows
readme-icon: $(ICNS)
	sips -z 512 512 "$(BUILD_DIR)/icon-1024.png" --out docs/icon.png >/dev/null
	@echo "wrote docs/icon.png"

## readme-hero: redraw docs/hero.png, the before/after picture at the top of the README
readme-hero:
	swift Scripts/make-hero.swift docs/hero.png

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
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	# One build per architecture, joined with lipo. `swift build --arch a
	# --arch b` would do it in one go, but only with Xcode's build system,
	# and the Command Line Tools are all this project asks for.
	for arch in $(ARCHS); do swift build -c release --arch $$arch || exit 1; done
	lipo -create -output "$(APP)/Contents/MacOS/$(APP_NAME)" \
		$(foreach arch,$(ARCHS),"$$(swift build -c release --arch $(arch) --show-bin-path)/$(APP_NAME)")
	# Sparkle, as SwiftPM fetched it: a universal binary already, ad-hoc
	# signed, and re-signed below. SwiftPM links it from next to the binary;
	# in a bundle it lives in Frameworks.
	mkdir -p "$(APP)/Contents/Frameworks"
	ditto "$$(swift build -c release --arch $(firstword $(ARCHS)) --show-bin-path)/Sparkle.framework" "$(SPARKLE)"
	# The XPC services are for sandboxed apps, which cannot launch the
	# installer themselves; DockFixer is not sandboxed and Sparkle runs
	# Autoupdate directly. Sparkle's documentation says they may be removed.
	rm -rf "$(SPARKLE)/XPCServices" "$(SPARKLE)/Versions/B/XPCServices"
	# The search paths SwiftPM leaves in the binary are for running it from
	# .build: the toolchain's own Swift libraries, a duplicate /usr/lib/swift
	# and @loader_path. The Swift runtime is part of macOS 14 and linked by
	# absolute path, so the bundle needs Frameworks and nothing else — and a
	# hardened binary should not go looking in a toolchain directory.
	otool -l "$(APP)/Contents/MacOS/$(APP_NAME)" | awk '$$1 == "path" { print $$2 }' | sort -u | \
		while read -r rpath; do install_name_tool -delete_rpath "$$rpath" "$(APP)/Contents/MacOS/$(APP_NAME)" || exit 1; done
	install_name_tool -add_rpath @executable_path/../Frameworks "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp "$(ICNS)" "$(APP)/Contents/Resources/AppIcon.icns"
	# Octicons' GitHub mark (MIT), for the GitHub button.
	cp Resources/github-mark.pdf "$(APP)/Contents/Resources/github-mark.pdf"
	sed -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' -e 's/__VERSION__/$(VERSION)/g' \
		-e 's/__LOG_LEVEL__/$(LOG_LEVEL)/g' -e 's/__USAGE_KEY__/$(USAGE_KEY)/g' \
		-e 's|__FEED_URL__|$(FEED_URL)|g' -e 's|__ED_PUBLIC_KEY__|$(ED_PUBLIC_KEY)|g' \
		Resources/Info.plist > "$(APP)/Contents/Info.plist"
	# Inside out, each part with the same identity and the hardened runtime,
	# as Sparkle's documentation does it; --deep would sign in an order of its
	# own and is deprecated for signing. The app's entitlements turn off
	# library validation, which needs a Team ID a self-signed certificate
	# does not have: see Resources/DockFixer.entitlements.
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" "$(SPARKLE)/Versions/B/Autoupdate"
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" "$(SPARKLE)/Versions/B/Updater.app"
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" "$(SPARKLE)"
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" \
		--entitlements Resources/DockFixer.entitlements "$(APP)"
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
