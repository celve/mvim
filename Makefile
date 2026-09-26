PROJECT := mvim
SCHEME  := mvim
CONFIG  := Debug
DERIVED := build
RELEASE := .release
DIST    := dist
APP     := $(DERIVED)/Build/Products/$(CONFIG)/$(PROJECT).app
RELAPP  := $(RELEASE)/$(PROJECT).app
SPARKLE := $(DERIVED)/SourcePackages/artifacts/sparkle/Sparkle/bin
# Sparkle orders updates by CFBundleVersion, which the commit count only ever raises along main.
BUILD   := $(shell git rev-list --count HEAD 2>/dev/null)

.PHONY: all gen build run release dist publish clean distclean test test-pasteboard

all: build

# The pure Vim engine: every .swift under Sources/Vim EXCEPT Runtime/ (which has AppKit/AX
# deps). Recursive so the engine can live in layer subfolders (Key/Model/Raw/Logical/Physical/State/Text).
# Invariant: impure code lives ONLY under Sources/Vim/Runtime/.
VIM_PURE := $(shell find Sources/Vim -name '*.swift' -not -path '*/Runtime/*')

# Sources/Core is NOT swept: most of it is UserDefaults- or AX-bound. Files are
# listed here one at a time, and only when they are pure enough to link against
# nothing but the stdlib — Surface.swift holds the rung algebra and precedence
# walks, which are the part of per-surface config worth pinning.
CORE_PURE := Sources/Core/Surface.swift Sources/Core/CapabilitySeeds.swift Sources/Core/StrikeLedger.swift Sources/Core/WebAreaWalk.swift Sources/Core/MarkerText.swift

# Permission-free unit tests for the pure Vim engine. No Xcode/app build, no Accessibility grant.
test:
	@mkdir -p $(DERIVED)
	@swiftc -o $(DERIVED)/vim-engine-test $(VIM_PURE) $(CORE_PURE) Tests/VimEngineTests/main.swift
	@$(DERIVED)/vim-engine-test

# The register paste's pasteboard loan, on a private named pasteboard: needs a login session, no grant.
test-pasteboard:
	@mkdir -p $(DERIVED)
	@swiftc -o $(DERIVED)/pasteboard-test Sources/Vim/Runtime/PasteboardLoan.swift Tests/PasteboardTests/main.swift
	@$(DERIVED)/pasteboard-test

gen:
	xcodegen generate

build: gen
	xcodebuild \
		-project $(PROJECT).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) \
		build

run: build
	open "$(APP)"

# The rm before ditto is load-bearing: ditto merges into an existing bundle, and a file left
# from an older build breaks the signature's seal.
release: gen
	xcodebuild \
		-project $(PROJECT).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(DERIVED) \
		$(if $(BUILD),CURRENT_PROJECT_VERSION=$(BUILD)) \
		build
	rm -rf $(RELAPP)
	ditto $(DERIVED)/Build/Products/Release/$(PROJECT).app $(RELAPP)
	codesign --verify --deep --strict $(RELAPP)
	@echo "Release app: $(RELAPP)"

# Stages an update in dist/ without publishing it: the zipped app and the appcast pointing at it.
dist: release
	scripts/sparkle-release.sh dist $(RELAPP) $(SPARKLE) $(DIST)

# Stages as dist does, then releases it on GitHub, where every installed copy's feed looks.
publish: release
	scripts/sparkle-release.sh publish $(RELAPP) $(SPARKLE) $(DIST)

# Spares $(RELEASE): SMAppService records the path of the bundle its login item was registered from.
clean:
	rm -rf $(DERIVED) $(PROJECT).xcodeproj $(DIST)

distclean: clean
	rm -rf $(RELEASE)
