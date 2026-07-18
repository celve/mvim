PROJECT := Norm
SCHEME  := Norm
CONFIG  := Debug
DERIVED := build
APP     := $(DERIVED)/Build/Products/$(CONFIG)/$(PROJECT).app

.PHONY: all gen build run release clean test

all: build

# The pure Vim engine: every .swift under Sources/Vim EXCEPT Runtime/ (which has AppKit/AX
# deps). Recursive so the engine can live in layer subfolders (Model/Text/Plan/Resolve).
# Invariant: impure code lives ONLY under Sources/Vim/Runtime/.
VIM_PURE := $(shell find Sources/Vim -name '*.swift' -not -path '*/Runtime/*')

# Permission-free unit tests for the pure Vim engine. No Xcode/app build, no Accessibility grant.
test:
	@mkdir -p $(DERIVED)
	@swiftc -o $(DERIVED)/vim-engine-test $(VIM_PURE) Tests/VimEngineTests/main.swift
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

release: gen
	xcodebuild \
		-project $(PROJECT).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(DERIVED) \
		build

clean:
	rm -rf $(DERIVED) $(PROJECT).xcodeproj
