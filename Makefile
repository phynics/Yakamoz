.PHONY: generate build test verify

TEST_DESTINATION = platform=macOS
TEST_FILTER_ARG = $(if $(TEST_FILTER),-only-testing:YakamozTests/$(TEST_FILTER),)
DERIVED_DATA_PATH = $(CURDIR)/DerivedData
SOURCE_PACKAGES_PATH = $(CURDIR)/.build/SourcePackages
XCODEBUILD_FLAGS = -derivedDataPath '$(DERIVED_DATA_PATH)' -clonedSourcePackagesDirPath '$(SOURCE_PACKAGES_PATH)' -skipMacroValidation

generate:
	xcodegen generate

build: generate
	xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination '$(TEST_DESTINATION)' $(XCODEBUILD_FLAGS) build

test: generate
	xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination '$(TEST_DESTINATION)' $(XCODEBUILD_FLAGS) test $(TEST_FILTER_ARG)

verify: build test
