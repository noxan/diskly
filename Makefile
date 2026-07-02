APP          = Diskly
TARGET       = Diskly
PROJECT      = Diskly.xcodeproj
BUILD_DIR    = build
APP_BUNDLE   = $(BUILD_DIR)/Release/$(APP).app
ZIP          = $(APP).zip

# --- Distribution (Developer ID signing + notarization) ----------------------
# Fill these in once you have an Apple Developer certificate. Until then the
# `dist` target refuses to run, leaving the project in a safe state.
#
#   DEVELOPER_ID  Your "Developer ID Application" signing identity name.
#                 Find via: security find-identity -p codesigning -v
#                 Example: "Developer ID Application: Rick Stromer (ABCDEFG123)"
#
#   NOTARY_KEY    Path to an App Store Connect API key (.p8) used to authenticate
#                 notarization submissions. Create one at
#                 https://appstoreconnect.apple.com/access/integrations/api
#                 (create a Team Key with "App Manager" role).
#
#   NOTARY_KEY_ID The 10-char Key ID printed on that API key page.
#
#   NOTARY_ISSUER The Issuer ID from the same API key page.
#
# All four can be overridden on the command line:
#   make dist DEVELOPER_ID="..." NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=... NOTARY_ISSUER=...
# Or set them once in a local `config.mk` (gitignored) and they'll be picked up.
-include config.mk
DEVELOPER_ID   ?=
NOTARY_KEY     ?=
NOTARY_KEY_ID  ?=
NOTARY_ISSUER  ?=

ZIP_SHARE = $(APP)-share.zip
ZIP_DIST  = $(APP)-dist.zip

# --- Benchmark: build Diskly's scanner against the cross-tool bench --------
# `make bench` compiles bench/bench.swift + Diskly/Scanner.swift into
# bench/bench (gitignored) and runs it. Override BENCH_PATH to scan a
# different folder (default: ~/Library).
BENCH_BIN   = bench/bench
BENCH_PATH ?= ~/Library

.PHONY: share dist sign notarize staple verify clean build zip open bench

bench: $(BENCH_BIN)
	./$(BENCH_BIN) "$(BENCH_PATH)"

$(BENCH_BIN): bench/bench.swift Diskly/Scanner.swift
	swiftc -O bench/bench.swift Diskly/Scanner.swift -o $(BENCH_BIN)

# --- Internal testing: ad-hoc build zipped for sharing -----------------------
# Build a Release .app, zip it for sharing. Recipients bypass Gatekeeper with
# right-click → Open the first time. Uses zip -X --symlinks (see dist target
# note) so the archive stays Gatekeeper-clean.
share: clean build
	cd "$(BUILD_DIR)/Release" && zip -qrX --symlinks "$(CURDIR)/$(ZIP_SHARE)" "$(APP).app"
	@echo
	@echo "Built: $(ZIP_SHARE)"
	@echo "Recipients: right-click the app → Open the first time to bypass Gatekeeper."

# --- Distribution: Developer ID sign → notarize → staple → verify → zip ------
# Ready to run once DEVELOPER_ID and NOTARY_* are filled in (via config.mk).
# NB: zip -X --symlinks (not ditto) — ditto emits `._` AppleDouble companions
# for any file carrying xattrs (e.g. com.apple.provenance stamped by LaunchServices
# during signing). Those `._` files land inside Sparkle.framework/Updater.app and
# break its sub-bundle seal, so Gatekeeper rejects the extracted archive with
# "could not verify… free of malware". -X skips xattrs, --symlinks keeps the
# framework's Versions/Current symlinks intact.
dist: sign notarize staple verify
	cd "$(BUILD_DIR)/Release" && zip -qrX --symlinks "$(CURDIR)/$(ZIP_DIST)" "$(APP).app"
	@echo
	@echo "Distributed: $(ZIP_DIST) — signed + notarized, ready for anyone to open."

clean:
	-@if [ -d $(BUILD_DIR) ]; then mv $(BUILD_DIR) $(BUILD_DIR).old && (rm -rf $(BUILD_DIR).old &); fi
	rm -f $(ZIP_SHARE) $(ZIP_DIST) $(BENCH_BIN)

build: clean
	xcodebuild -project $(PROJECT) -target $(TARGET) -configuration Release \
	  SYMROOT=$(PWD)/$(BUILD_DIR) OBJROOT=$(PWD)/$(BUILD_DIR)/Intermediates build

# Sign the built bundle with the Developer ID Application identity.
# Sparkle's Downloader.xpc is removed first — we hold the network.client
# entitlement, so the service is never launched and --deep re-signing it
# (which would strip its entitlements) is a non-issue. Trims the bundle too.
sign: build
	@if [ -z "$(DEVELOPER_ID)" ]; then \
	  echo "Set DEVELOPER_ID before running 'make dist'." >&2; \
	  echo "Put it in config.mk (see Makefile comments). Run-time check: security find-identity -p codesigning -v" >&2; \
	  exit 2; \
	fi
	@echo "Signing with: $(DEVELOPER_ID)"
	@rm -rf "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
	codesign --force --deep --options runtime \
	  --sign "$(DEVELOPER_ID)" "$(APP_BUNDLE)"

# Submit the signed bundle for notarization and wait for Apple's verdict.
notarize: sign
	@if [ -z "$(NOTARY_KEY)" ] || [ -z "$(NOTARY_KEY_ID)" ] || [ -z "$(NOTARY_ISSUER)" ]; then \
	  echo "Set NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER (via config.mk) before notarizing." >&2; \
	  exit 2; \
	fi
	@echo "Submitting $(APP_BUNDLE) for notarization…"
	ditto -c -k --keepParent "$(APP_BUNDLE)" /tmp/$(APP)-notary.zip
	xcrun notarytool submit /tmp/$(APP)-notary.zip \
	  --key "$(NOTARY_KEY)" --key-id "$(NOTARY_KEY_ID)" --issuer "$(NOTARY_ISSUER)" \
	  --wait
	rm -f /tmp/$(APP)-notary.zip

# Staple the notarization ticket onto the bundle.
staple: notarize
	xcrun stapler staple "$(APP_BUNDLE)"

# Verify signature and Gatekeeper acceptance after stapling.
verify: staple
	@echo "Verifying signature + notarization…"
	codesign --verify --strict --verbose=2 "$(APP_BUNDLE)"
	spctl -a -v -t exec "$(APP_BUNDLE)"
	xcrun stapler validate "$(APP_BUNDLE)"

# Quick local run of the just-built app.
open: build
	open "$(APP_BUNDLE)"