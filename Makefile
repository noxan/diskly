APP          = Diskly
TARGET       = Diskly
PROJECT      = Diskly.xcodeproj
BUILD_DIR    = build
APP_BUNDLE   = $(BUILD_DIR)/Release/$(APP).app
ZIP          = $(APP).zip

.PHONY: share clean build zip open

# Build a Release .app, zip it for sharing (ad-hoc signed, internal use only).
share: zip
	@echo
	@echo "Built: $(ZIP)"
	@echo "Recipients: right-click the app → Open the first time to bypass Gatekeeper."

clean:
	rm -rf $(BUILD_DIR) $(ZIP)

build: clean
	xcodebuild -project $(PROJECT) -target $(TARGET) -configuration Release \
	  SYMROOT=$(PWD)/$(BUILD_DIR) OBJROOT=$(PWD)/$(BUILD_DIR)/Intermediates build

zip: build
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(ZIP)"

open: build
	open "$(APP_BUNDLE)"