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

.PHONY: all app run test install uninstall reset-tcc zip clean help

all: app

## app: build a release binary and wrap it in a .app bundle
app:
	swift build -c release
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
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
