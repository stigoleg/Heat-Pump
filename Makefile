# Build, test and install Varmepumpe.
#   make build    Release build (signed) in build/DerivedData
#   make test     HeatPumpKit unit tests
#   make install  build, then copy to /Applications (refuses while the app is running)
#   make demo     run the Debug build with simulated data (no MELCloud calls)
#                 [LANGUAGE=en|nb] overrides the language for this run
#   make l10n     refresh the string catalogs from the sources and list missing translations
#                 [TRANSLATIONS="a.json b.json"] merges translation files (see scripts/l10n.py)
#   make release VERSION=1.2.3 [NOTARY_PROFILE=varmepumpe]
#                 Developer ID signed + notarized zip in build/release (CI does this on tags)

SCHEME       := Varmepumpe
DERIVED      := build/DerivedData
PACKAGE      := Packages/HeatPumpKit
RELEASE_APP  := $(DERIVED)/Build/Products/Release/$(SCHEME).app
DEBUG_APP    := $(DERIVED)/Build/Products/Debug/$(SCHEME).app
INSTALL_DIR  := /Applications
DEMO_DB      := build/demo/varmepumpe.sqlite

.PHONY: all build buil debug test check install demo release project clean l10n l10n-check

all: build

project:
	xcodegen generate

build: project
	xcodebuild -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) build -quiet
	codesign --verify --deep --strict $(RELEASE_APP)
	@echo "Built: $(RELEASE_APP)"

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
		echo "Quit Varmepumpe before installing."; exit 1; fi
	rm -rf "$(INSTALL_DIR)/$(SCHEME).app"
	ditto $(RELEASE_APP) "$(INSTALL_DIR)/$(SCHEME).app"
	codesign --verify --deep --strict "$(INSTALL_DIR)/$(SCHEME).app"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALL_DIR)/$(SCHEME).app"
	@echo "Installed in $(INSTALL_DIR)/$(SCHEME).app"

demo: debug
	mkdir -p $(dir $(DEMO_DB))
	VARMEPUMPE_BACKEND=mock VARMEPUMPE_DB_PATH=$(abspath $(DEMO_DB)) $(if $(LANGUAGE),VARMEPUMPE_LANGUAGE=$(LANGUAGE)) \
		$(DEBUG_APP)/Contents/MacOS/$(SCHEME)

# Catalogs in App/Resources: app keys come from the Debug build's .stringsdata.
l10n: debug
	python3 scripts/l10n.py sync $(if $(TRANSLATIONS),--translations $(TRANSLATIONS))
	python3 scripts/l10n.py missing

l10n-check: debug
	python3 scripts/l10n.py check

release:
	@test -n "$(VERSION)" || { echo "Usage: make release VERSION=1.2.3 [NOTARY_PROFILE=name]"; exit 1; }
	NOTARY_PROFILE=$(NOTARY_PROFILE) scripts/release.sh $(VERSION)

clean:
	rm -rf build Varmepumpe.xcodeproj
	cd $(PACKAGE) && swift package clean
