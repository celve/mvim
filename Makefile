PROJECT := Norm
SCHEME  := Norm
CONFIG  := Debug
DERIVED := build
RELEASE := .release
APP     := $(DERIVED)/Build/Products/$(CONFIG)/$(PROJECT).app
RELAPP  := $(RELEASE)/$(PROJECT).app

.PHONY: all gen build run release clean distclean test

all: build

# The pure Vim engine: every .swift under Sources/Vim EXCEPT Runtime/ (which has AppKit/AX
# deps). Recursive so the engine can live in layer subfolders (Key/Model/Raw/Logical/Physical/State/Text).
# Invariant: impure code lives ONLY under Sources/Vim/Runtime/.
VIM_PURE := $(shell find Sources/Vim -name '*.swift' -not -path '*/Runtime/*')

# Sources/Core is NOT swept: most of it is UserDefaults- or AX-bound. Files are
# listed here one at a time, and only when they are pure enough to link against
# nothing but the stdlib — Surface.swift holds the rung algebra and precedence
# walks, which are the part of per-surface config worth pinning.
CORE_PURE := Sources/Core/Surface.swift Sources/Core/CapabilitySeeds.swift Sources/Core/StrikeLedger.swift Sources/Core/WebAreaWalk.swift

# Permission-free unit tests for the pure Vim engine. No Xcode/app build, no Accessibility grant.
test:
	@mkdir -p $(DERIVED)
	@swiftc -o $(DERIVED)/vim-engine-test $(VIM_PURE) $(CORE_PURE) Tests/VimEngineTests/main.swift
	@$(DERIVED)/vim-engine-test

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
		build
	rm -rf $(RELAPP)
	ditto $(DERIVED)/Build/Products/Release/$(PROJECT).app $(RELAPP)
	codesign --verify --deep --strict $(RELAPP)
	@echo "Release app: $(RELAPP)"

# Spares $(RELEASE): SMAppService records the path of the bundle its login item was registered from.
clean:
	rm -rf $(DERIVED) $(PROJECT).xcodeproj

distclean: clean
	rm -rf $(RELEASE)
