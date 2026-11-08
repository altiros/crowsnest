# Only when the Command Line Tools are active instead of Xcode: they ship the swift-testing plugin elsewhere.
CLT := /Library/Developer/CommandLineTools
TEST_FLAGS := $(if $(filter $(CLT),$(shell xcode-select -p)),\
	-Xswiftc -plugin-path -Xswiftc $(CLT)/usr/lib/swift/host/plugins/testing \
	-Xswiftc -F -Xswiftc $(CLT)/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT)/Library/Developer/Frameworks,)

IPAD_SIM ?= iPad Pro 13-inch (M5)
IPAD_DD := .build/ipad

.PHONY: build test run app open clean xcode ipad ipad-run icon probe

build:
	swift build

test:
	swift test $(TEST_FLAGS)

run:
	swift run Crowsnest

# build/Crowsnest.app (ad-hoc signed)
app:
	./scripts/bundle.sh

open: app
	open build/Crowsnest.app

clean:
	rm -rf .build build

# Xcode project (iPad + macOS targets), generated from App/project.yml (needs xcodegen)
xcode:
	xcodegen generate --spec App/project.yml --quiet

ipad: xcode
	xcodebuild -project App/CrowsnestApp.xcodeproj -scheme "Crowsnest iPad" \
		-destination 'platform=iOS Simulator,name=$(IPAD_SIM)' -derivedDataPath $(IPAD_DD) -quiet build

ipad-run: ipad
	xcrun simctl boot "$(IPAD_SIM)" 2>/dev/null || true
	-open -a Simulator 2>/dev/null
	xcrun simctl install "$(IPAD_SIM)" "$(IPAD_DD)/Build/Products/Debug-iphonesimulator/Crowsnest.app"
	xcrun simctl launch "$(IPAD_SIM)" com.altiros.Crowsnest

# Regenerates the app icon (asset catalog + .icns)
icon:
	swift scripts/make-icon.swift Resources

# Read-only smoke test against a cluster: make probe CONTEXT=<name>
probe:
	swift run crowsnest-probe $(CONTEXT)
