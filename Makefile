.PHONY: generate build test verify gnostic-smoke

SHELL := /bin/bash
# Disable SwiftPM macro prebuilts to avoid incompatible SwiftSyntax prebuilt modules
# on Xcode 27 / Swift 6.4 toolchains.
export SWIFTPM_ENABLE_MACROS_PREBUILTS := NO
TEST_DESTINATION = platform=macOS
TEST_SCHEME ?= Yakamoz
# A filter names a suite/class in either test bundle; scope it to both so a
# network-suite name no longer resolves to zero tests.
TEST_FILTER_ARG = $(if $(TEST_FILTER),-only-testing:YakamozTests/$(TEST_FILTER) -only-testing:YakamozNetworkTests/$(TEST_FILTER),)
DERIVED_DATA_PATH = $(CURDIR)/DerivedData
SOURCE_PACKAGES_PATH = $(CURDIR)/.build/SourcePackages
TEST_LOG = $(CURDIR)/.build/test-xcodebuild.log
VERIFY_LOG = $(CURDIR)/.build/verify-xcodebuild.log
XCODEBUILD_FLAGS = -derivedDataPath '$(DERIVED_DATA_PATH)' -clonedSourcePackagesDirPath '$(SOURCE_PACKAGES_PATH)' -skipMacroValidation
# Highest per-bundle test count reported in a log (0 when nothing ran). Both
# XCTest ("Executed N tests") and Swift Testing ("Test run with N tests") lines
# are considered; max keeps the two report styles from double-counting.
COUNT_TESTS = awk '\
	/Executed [0-9]+ tests?/ { for (i = 1; i <= NF; i++) if ($$i == "Executed" && $$(i + 1) > max) max = $$(i + 1) } \
	/Test run with [0-9]+ tests?/ { for (i = 1; i <= NF; i++) if ($$i == "with" && $$(i + 1) > max) max = $$(i + 1) } \
	END { print max + 0 }'

generate:
	xcodegen generate

build: generate
	xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination '$(TEST_DESTINATION)' $(XCODEBUILD_FLAGS) build

test: generate
	@mkdir -p '$(dir $(TEST_LOG))'
	@set -o pipefail; xcodebuild -project Yakamoz.xcodeproj -scheme '$(TEST_SCHEME)' -destination '$(TEST_DESTINATION)' $(XCODEBUILD_FLAGS) test $(TEST_FILTER_ARG) 2>&1 | tee '$(TEST_LOG)'
	@executed=$$($(COUNT_TESTS) '$(TEST_LOG)'); \
	echo "make test: executed $$executed tests"; \
	if [ "$$executed" -eq 0 ]; then \
		echo "error: zero tests executed; does TEST_FILTER='$(TEST_FILTER)' name a real suite in either bundle?"; \
		exit 1; \
	fi

verify:
	xcodegen generate
	@mkdir -p '$(dir $(VERIFY_LOG))'
	@set -o pipefail; xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination '$(TEST_DESTINATION)' $(XCODEBUILD_FLAGS) test 2>&1 | tee '$(VERIFY_LOG)'
	@executed=$$($(COUNT_TESTS) '$(VERIFY_LOG)'); \
	echo "make verify: executed $$executed tests"; \
	if [ "$$executed" -eq 0 ]; then \
		echo "error: xcodebuild reported zero executed tests"; \
		exit 1; \
	fi

gnostic-smoke:
	@./Scripts/gnostic-smoke.sh
