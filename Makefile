.PHONY: generate build test verify check-json-schema-pin

SHELL := /bin/bash
TEST_DESTINATION = platform=macOS
TEST_FILTER_ARG = $(if $(TEST_FILTER),-only-testing:YakamozTests/$(TEST_FILTER),)
DERIVED_DATA_PATH = $(CURDIR)/DerivedData
SOURCE_PACKAGES_PATH = $(CURDIR)/.build/SourcePackages
VERIFY_LOG = $(CURDIR)/.build/verify-xcodebuild.log
XCODEBUILD_FLAGS = -derivedDataPath '$(DERIVED_DATA_PATH)' -clonedSourcePackagesDirPath '$(SOURCE_PACKAGES_PATH)' -skipMacroValidation
POSITRONICKIT_RESOLVED = $(CURDIR)/../PositronicKit/Package.resolved

generate:
	xcodegen generate

build: generate
	xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination '$(TEST_DESTINATION)' $(XCODEBUILD_FLAGS) build

test: generate
	xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination '$(TEST_DESTINATION)' $(XCODEBUILD_FLAGS) test $(TEST_FILTER_ARG)

# Guards against project.yml's swift-json-schema exactVersion pin silently
# drifting from PositronicKit's resolved version (see YAK-10): if someone bumps
# one without the other, the app and its embedded package graph can end up with
# a mismatched JSONSchema builder API.
check-json-schema-pin:
	@pinned=$$(grep -A2 '^  swift-json-schema:' project.yml | grep exactVersion | sed -E 's/.*exactVersion: *//'); \
	resolved=$$(python3 -c "import json,sys; d=json.load(open('$(POSITRONICKIT_RESOLVED)')); print(next(p['state']['version'] for p in d['pins'] if p['identity'] == 'swift-json-schema'))"); \
	echo "project.yml pins swift-json-schema $$pinned; PositronicKit resolves $$resolved"; \
	if [ "$$pinned" != "$$resolved" ]; then \
		echo "error: swift-json-schema pin in project.yml ($$pinned) does not match PositronicKit's Package.resolved ($$resolved)"; \
		echo "update the exactVersion in project.yml's packages.swift-json-schema block to match"; \
		exit 1; \
	fi

verify: check-json-schema-pin
	xcodegen generate
	@mkdir -p '$(dir $(VERIFY_LOG))'
	@set -o pipefail; xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination '$(TEST_DESTINATION)' $(XCODEBUILD_FLAGS) test 2>&1 | tee '$(VERIFY_LOG)'
	@executed=$$(awk '\
		/Executed [0-9]+ tests?/ { for (i = 1; i <= NF; i++) if ($$i == "Executed" && $$(i + 1) > max) max = $$(i + 1) } \
		/Test run with [0-9]+ tests?/ { for (i = 1; i <= NF; i++) if ($$i == "with" && $$(i + 1) > max) max = $$(i + 1) } \
		END { print max + 0 }' '$(VERIFY_LOG)'); \
	echo "make verify: executed $$executed tests"; \
	if [ "$$executed" -eq 0 ]; then \
		echo "error: xcodebuild reported zero executed tests"; \
		exit 1; \
	fi
