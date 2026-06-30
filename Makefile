.PHONY: generate build test verify

SHELL := /bin/bash
TEST_DESTINATION = platform=macOS
TEST_FILTER_ARG = $(if $(TEST_FILTER),-only-testing:YakamozTests/$(TEST_FILTER),)
DERIVED_DATA_PATH = $(CURDIR)/DerivedData
SOURCE_PACKAGES_PATH = $(CURDIR)/.build/SourcePackages
VERIFY_LOG = $(CURDIR)/.build/verify-xcodebuild.log
XCODEBUILD_FLAGS = -derivedDataPath '$(DERIVED_DATA_PATH)' -clonedSourcePackagesDirPath '$(SOURCE_PACKAGES_PATH)' -skipMacroValidation

generate:
	xcodegen generate

build: generate
	xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination '$(TEST_DESTINATION)' $(XCODEBUILD_FLAGS) build

test: generate
	xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination '$(TEST_DESTINATION)' $(XCODEBUILD_FLAGS) test $(TEST_FILTER_ARG)

verify:
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
