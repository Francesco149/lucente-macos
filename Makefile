# Lucente for macOS — everyday commands. Run `make` for the list.
# Only Xcode is required; there are no third-party tools or dependencies.

PROJECT  := Lucente.xcodeproj
SCHEME   := Lucente
CONFIG   ?= Debug
DERIVED  := .build/xcode
APP      := $(DERIVED)/Build/Products/$(CONFIG)/Lucente.app
KIT      := Packages/LucenteKit
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
              -destination "platform=macOS,arch=$(shell uname -m)" -derivedDataPath $(DERIVED)

.DEFAULT_GOAL := help
.PHONY: help build run test probe logs install open clean

help: ## Show this list
	@awk 'BEGIN {FS = ":.*## "} /^[a-z]+:.*## / {printf "  \033[1m%-8s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the app (CONFIG=Release for an optimized build)
	@$(XCODEBUILD) build -quiet

run: build ## Build, then (re)launch the app
	@pkill -x Lucente 2>/dev/null; sleep 0.3; open "$(APP)"

test: ## Run the protocol/driver tests (seconds, no hardware needed)
	@swift test --package-path $(KIT) --quiet

probe: ## Raw Bluetooth workbench, e.g. make probe ARGS="scan" (see scripts/probe --help)
	@scripts/probe $(ARGS)

logs: ## Stream the app's unified log (Bluetooth traffic at debug level)
	@log stream --level debug --style compact --predicate 'subsystem == "uk.headpats.lucente"'

install: ## Build Release and copy it to /Applications
	@$(MAKE) --no-print-directory build CONFIG=Release
	@pkill -x Lucente 2>/dev/null; rm -rf /Applications/Lucente.app
	@ditto "$(DERIVED)/Build/Products/Release/Lucente.app" /Applications/Lucente.app
	@echo "Installed /Applications/Lucente.app"

open: ## Open the project in Xcode
	@open $(PROJECT)

clean: ## Remove build products
	@rm -rf .build $(KIT)/.build
