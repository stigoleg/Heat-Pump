# Build, test and install Varmepumpe.
#   make build    Release build (signed) in build/DerivedData
#   make test     HeatPumpKit unit tests
#   make install  build, then copy to /Applications (refuses while the app is running)
#   make demo     run the Debug build with simulated data (no MELCloud calls)

SCHEME       := Varmepumpe
DERIVED      := build/DerivedData
PACKAGE      := Packages/HeatPumpKit
RELEASE_APP  := $(DERIVED)/Build/Products/Release/$(SCHEME).app
DEBUG_APP    := $(DERIVED)/Build/Products/Debug/$(SCHEME).app
INSTALL_DIR  := /Applications
DEMO_DB      := build/demo/varmepumpe.sqlite

.PHONY: all build buil debug test check install demo project clean

all: build

project:
	xcodegen generate

build: project
	xcodebuild -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) build -quiet
	codesign --verify --deep --strict $(RELEASE_APP)
	@echo "Bygget: $(RELEASE_APP)"

# Typo-tolerant alias.
buil: build

debug: project
	xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) build -quiet

test:
	cd $(PACKAGE) && swift test

# Unit tests plus a Debug build of the app.
check: test debug

install: build
	@if pgrep -f "$(INSTALL_DIR)/$(SCHEME).app/Contents/MacOS" >/dev/null; then \
		echo "Avslutt Varmepumpe før installering."; exit 1; fi
	rm -rf "$(INSTALL_DIR)/$(SCHEME).app"
	ditto $(RELEASE_APP) "$(INSTALL_DIR)/$(SCHEME).app"
	codesign --verify --deep --strict "$(INSTALL_DIR)/$(SCHEME).app"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALL_DIR)/$(SCHEME).app"
	@echo "Installert i $(INSTALL_DIR)/$(SCHEME).app"

demo: debug
	mkdir -p $(dir $(DEMO_DB))
	VARMEPUMPE_BACKEND=mock VARMEPUMPE_DB_PATH=$(abspath $(DEMO_DB)) $(DEBUG_APP)/Contents/MacOS/$(SCHEME)

clean:
	rm -rf build Varmepumpe.xcodeproj
	cd $(PACKAGE) && swift package clean
