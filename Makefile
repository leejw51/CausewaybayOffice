# CAUSEWAYBAY OFFICE
# Usage: make / make help / make core / make start / make test / make check / make package / make app
#
# Two halves, one contract:
#   rust/    cargo crate `cbo_core` -> libcbo_core.dylib (SSH, VT100, LLM streaming)
#   love2d/  LÖVE 11.5 app that loads the dylib through LuaJIT FFI
# rust/include/cbo.h is the source of truth for the boundary; `make cdef`
# regenerates the Lua mirror from it.

.DEFAULT_GOAL := help
.PHONY: help version core core-debug cdef start start-mock test test-unit test-core test-integration test-ui-integration test-ffi test-love test-live \
        lint lint-lua lint-rust format fmt fmt-check check smoke art love verify-archive package package-smoke \
        app app-icon app-sign app-smoke notarize gatekeeper clean \
        require-love require-luajit require-cargo require-core

RUST   := rust
GAME   := love2d
PY     := python

# LÖVE is not on PATH on this machine (the brew cask is disabled); the .app
# lives in ~/Applications. Override with LOVE=/path/to/love if yours differs.
LOVE_APP    ?= $(HOME)/Applications/love.app
LOVE        ?= $(if $(wildcard $(LOVE_APP)/Contents/MacOS/love),$(LOVE_APP)/Contents/MacOS/love,love)
LUAJIT      ?= /opt/homebrew/bin/luajit
STYLUA      ?= /opt/homebrew/bin/stylua
CARGO       ?= cargo
PYTHON      ?= python3

LOVE_VERSION := 11.5
LOVE_URL     := https://github.com/love2d/love/releases/download/$(LOVE_VERSION)/love-$(LOVE_VERSION)-macos.zip

# One number, in one file. `make version` prints it and refuses a malformed one.
VERSION := $(shell sed -n '1p' VERSION | tr -d ' \t\r\n')

HEADER  := $(RUST)/include/cbo.h
CDEF    := $(GAME)/src/cbo_cdef.lua
DYLIB   := $(RUST)/target/release/libcbo_core.dylib
DYLIB_D := $(RUST)/target/debug/libcbo_core.dylib

help:
	@printf '%s\n' \
		'CAUSEWAYBAY OFFICE $(VERSION)' \
		'' \
		'make help        list targets' \
		'make version     print the version of record' \
		'' \
		'  core (Rust, rust/)' \
		'make core        cargo build --release -> $(DYLIB)' \
		'make core-debug  cargo build (debug) -> $(DYLIB_D)' \
		'make cdef        regenerate $(CDEF) from $(HEADER)' \
		'make smoke       cargo run --release --example smoke' \
		'' \
		'  app (LÖVE $(LOVE_VERSION), love2d/)' \
		'make start       build the core, then launch the app   (ARGS=... passes through)' \
		'make start-mock  launch without building the core (mock / UI work)' \
		'make test        all unit, integration, FFI and live UI tests; logs + JSON report' \
		'make test-unit   Rust unit tests + in-engine UI suite' \
		'make test-integration  Rust integrations + FFI + real SSH UI/restart checks' \
		'make lint        byte-compile every Lua file + cargo clippy when installed' \
		'make format      stylua + cargo fmt' \
		'make fmt-check   fail if stylua or rustfmt would change anything' \
		'make check       formatting + lint + tests' \
		'make test-live   explicit provider and embedding API tests (may incur charges)' \
		'make art         generate sprites/backgrounds (python/gen_art.py, needs GROK_API_KEY)' \
		'' \
		'  package' \
		'make love        build love2d/build/CausewaybayOffice.love' \
		'make package     portable bundle (.love + core + launcher) into ./dist; needs LÖVE to run' \
		'make package-smoke  package, then load the bundled core headlessly through LuaJIT' \
		'make app         macOS .app with LÖVE + libcbo_core inside, icon, signed (Developer ID or ad-hoc)' \
		'make notarize    notarise + staple the .app (APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID)' \
		'make gatekeeper  assess the .app the way Finder does' \
		'make clean       remove build output and ./dist' \
		'' \
		'LOVE=$(LOVE)'

version:
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { \
		echo "VERSION is not a semantic version: '$(VERSION)'" >&2; exit 1; }
	@echo "$(VERSION)"

# ---------------------------------------------------------------- requirements

# Fail with a usable message rather than a stack trace three targets deep.
require-love:
	@command -v "$(LOVE)" > /dev/null 2>&1 || { \
		echo "LÖVE $(LOVE_VERSION) not found (looked at: $(LOVE))." >&2; \
		echo "The brew cask is disabled; install it by hand:" >&2; \
		echo "  curl -fsSL -o /tmp/love.zip $(LOVE_URL)" >&2; \
		echo "  mkdir -p ~/Applications && unzip -q -o /tmp/love.zip -d ~/Applications" >&2; \
		echo "then run make again, or set LOVE=/path/to/love." >&2; \
		exit 1; }

require-luajit:
	@command -v "$(LUAJIT)" > /dev/null 2>&1 || { \
		echo "LuaJIT not found at $(LUAJIT). brew install luajit, or set LUAJIT=." >&2; \
		exit 1; }

require-cargo:
	@command -v "$(CARGO)" > /dev/null 2>&1 || { \
		echo "cargo not found. Install Rust: https://rustup.rs" >&2; exit 1; }

require-core:
	@test -f "$(DYLIB)" || test -f "$(DYLIB_D)" || { \
		echo "libcbo_core.dylib not built. Run 'make core' (or 'make start-mock' for UI-only work)." >&2; \
		exit 1; }

# ----------------------------------------------------------------------- core

core: require-cargo
	cd $(RUST) && $(CARGO) build --release
	@echo "  $(DYLIB)"

core-debug: require-cargo
	cd $(RUST) && $(CARGO) build
	@echo "  $(DYLIB_D)"

smoke: require-cargo
	cd $(RUST) && $(CARGO) run --release --example smoke

# The Lua mirror of the C header. Lines starting with '#' (guards, includes,
# the CBO_MAX_SESSIONS define) are dropped because ffi.cdef has no
# preprocessor; the constant is inlined and re-exported as M.MAX_SESSIONS.
# Everything after the cdef block (loader, constant tables) is kept verbatim
# from the current file, so the output is byte-identical apart from the block.
define CDEF_PY
import re, sys
header, out = sys.argv[1], sys.argv[2]
body = "".join(l for l in open(header, encoding="utf-8") if not l.startswith("#"))
body = body.replace("CBO_MAX_SESSIONS", "128")
try:
    cur = open(out, encoding="utf-8").read()
    head, tail = cur.split("ffi.cdef([[", 1)
    tail = tail.split("]])", 1)[1]
except (FileNotFoundError, ValueError):
    head = ('-- GENERATED from rust/include/cbo.h — keep in sync (make cdef).\n'
            'local ffi = require("ffi")\n\n')
    tail = "\n\nlocal M = {}\nM.MAX_SESSIONS = 128\n\nreturn M\n"
# stylua's form: ffi.cdef([[ ... ]]) so `make cdef` after `make format` is a no-op
open(out, "w", encoding="utf-8").write(head + "ffi.cdef([[\n" + body + "]])" + tail)
print("  " + out)
endef
export CDEF_PY

cdef:
	@$(PYTHON) -c "$$CDEF_PY" "$(HEADER)" "$(CDEF)"

# ------------------------------------------------------------------- run/test

start: core require-love
	"$(LOVE)" $(GAME) $(ARGS)

# For UI work: no cargo, no dylib. The app decides what "mock" means when the
# core is missing (see love2d/src/core.lua).
start-mock: require-love
	"$(LOVE)" $(GAME) --mock $(ARGS)

# Full verification: real local SSH is mandatory; provider tests use available keys.
# The runner isolates all persistent data and retains per-stage logs + a JSON report.
test: core require-love require-luajit
	$(PYTHON) tools/run_tests.py --cargo "$(CARGO)" --love "$(LOVE)" --luajit "$(LUAJIT)"

test-unit: require-cargo test-love
	cd $(RUST) && $(CARGO) test --release --lib

test-ui-integration: core require-love require-luajit
	$(PYTHON) tools/run_tests.py --suite ui-integration --cargo "$(CARGO)" --love "$(LOVE)" --luajit "$(LUAJIT)"

test-core: require-cargo
	cd $(RUST) && $(CARGO) test --release

# The ssh tests (rust/tests/ssh_localhost.rs) need the local sshd; CBO_IT=1
# forces them on. Live LLM tests require CBO_LIVE=1 (make test-live).
test-integration: core require-love require-luajit
	$(PYTHON) tools/run_tests.py --suite integration --cargo "$(CARGO)" --love "$(LOVE)" --luajit "$(LUAJIT)"

# Provider-only subset; make test also exercises providers with available keys.
test-live: require-cargo
	cd $(RUST) && CBO_LIVE=1 $(CARGO) test --release --test llm_live
	cd $(RUST) && CBO_LIVE=1 $(CARGO) test --release --test db semantic_and_hybrid_search_with_openai

# LuaJIT loads the dylib through the same cdef the app uses.
test-ffi: core require-luajit
	$(LUAJIT) $(RUST)/examples/ffi_smoke.lua

# The suite runs inside the engine because loading a font or a sprite needs
# a graphics context. It needs the dylib, hence `core` first.
test-love: core require-love
	"$(LOVE)" $(GAME) -- --test

# --------------------------------------------------------------------- checks

# A glob, not a list: what compiles must never depend on somebody remembering
# to add a file.
lint: lint-lua lint-rust

lint-lua: require-luajit
	@status=0; n=0; \
	for file in $$(find $(GAME) -name '*.lua' -not -path '$(GAME)/build/*' | sort); do \
		n=$$((n + 1)); \
		$(LUAJIT) -bl "$$file" /dev/null > /dev/null || { \
			echo "  syntax error in $$file" >&2; status=1; }; \
	done; \
	[ $$status -eq 0 ] && echo "  every Lua file compiles ($$n files)"; \
	exit $$status

lint-rust: require-cargo
	@if $(CARGO) clippy --version > /dev/null 2>&1; then \
		cd $(RUST) && $(CARGO) clippy --release --all-targets -- -D warnings; \
	else \
		echo "  cargo clippy not installed (rustup component add clippy); skipping"; \
	fi

format:
	@command -v "$(STYLUA)" > /dev/null 2>&1 || { \
		echo "stylua not found at $(STYLUA). brew install stylua" >&2; exit 1; }
	$(STYLUA) $(GAME)
	cd $(RUST) && $(CARGO) fmt

fmt: format

fmt-check:
	@command -v "$(STYLUA)" > /dev/null 2>&1 || { \
		echo "stylua not found at $(STYLUA). brew install stylua" >&2; exit 1; }
	$(STYLUA) --check $(GAME) && echo "  Lua formatting is clean"
	cd $(RUST) && $(CARGO) fmt --check && echo "  Rust formatting is clean"

check: fmt-check lint test

# ------------------------------------------------------------------------ art

art:
	@test -n "$$GROK_API_KEY" || { echo "  GROK_API_KEY is not set" >&2; exit 1; }
	$(PYTHON) $(PY)/gen_art.py

# -------------------------------------------------------------------- package

# Two shapes ship, the same way CausewaybayWallet's LÖVE GUI does:
#
#   make package   a directory in ./dist that runs anywhere LÖVE 11 is
#                  installed: the .love archive, libcbo_core beside it (the
#                  loader looks next to the archive first), and a launcher.
#                  Every platform; this is what CI builds on Linux.
#   make app       a double-clickable macOS .app with LÖVE embedded, the core
#                  in Contents/Frameworks, an icon from the key art, signed
#                  (Developer ID when one is available, ad-hoc otherwise) and
#                  zipped. `make notarize` finishes it for distribution.

APP_NAME     := CausewaybayOffice
DISPLAY_NAME := Causewaybay Office
BUNDLE_ID    := com.causewaybay.office
BUILD        := $(GAME)/build
APP          := $(BUILD)/$(APP_NAME).app
GAME_LOVE    := $(BUILD)/$(APP_NAME).love
DIST_DIR     ?= $(abspath $(CURDIR)/dist)
STAGE        := $(DIST_DIR)/$(APP_NAME)

# The core library, named per platform the way cbo_cdef.lua looks for it.
UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
  CORE_LIB := libcbo_core.dylib
else ifeq ($(OS),Windows_NT)
  CORE_LIB := cbo_core.dll
else
  CORE_LIB := libcbo_core.so
endif
CORE_BIN := $(RUST)/target/release/$(CORE_LIB)

# The app as one archive. Staged by name rather than by zipping the directory,
# so build/ and the throwaway junk beside the source cannot ride along.
love: $(GAME_LOVE)

$(GAME_LOVE): $(wildcard $(GAME)/*.lua) $(wildcard $(GAME)/src/*.lua) \
              $(wildcard $(GAME)/src/scenes/*.lua) $(wildcard $(GAME)/assets/*) \
              $(wildcard $(GAME)/assets/*/*)
	@rm -rf "$(BUILD)/stage" && mkdir -p "$(BUILD)/stage"
	@cp $(GAME)/*.lua "$(BUILD)/stage/"
	@cp -R $(GAME)/src $(GAME)/assets "$(BUILD)/stage/"
	@rm -f "$(GAME_LOVE)"
	@cd "$(BUILD)/stage" && zip -qr9 "../$(APP_NAME).love" .
	@rm -rf "$(BUILD)/stage"
	@$(MAKE) --no-print-directory verify-archive ARCHIVE="$(GAME_LOVE)"
	@echo "  $(GAME_LOVE) ($$(du -h '$(GAME_LOVE)' | cut -f1))"

# Every .lua under love2d/ has to be in the archive. A missing module is not
# subtle - the bundle dies on its first `require` - but it dies on somebody
# else's machine, because the checkout it was built from has the file right
# there and `make start` never touches the archive.
verify-archive:
	@test -f "$(ARCHIVE)" || { echo "  no archive at $(ARCHIVE)" >&2; exit 1; }
	@missing=""; n=0; \
	for file in $$(cd $(GAME) && find . -name '*.lua' -not -path './build/*' | sed 's|^\./||' | sort); do \
		n=$$((n + 1)); \
		unzip -Z1 "$(ARCHIVE)" | grep -qxF "$$file" || missing="$$missing $$file"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "  the archive is missing:$$missing" >&2; exit 1; \
	fi; \
	echo "  archive carries every module ($$n files)"

# The portable bundle: needs LÖVE 11 on the machine that runs it.
package: core love
	@rm -rf "$(STAGE)" "$(DIST_DIR)/$(APP_NAME)-$(VERSION)-*.zip"
	@mkdir -p "$(STAGE)"
	@cp "$(GAME_LOVE)" "$(STAGE)/$(APP_NAME).love"
	@cp -f "$(CORE_BIN)" "$(STAGE)/$(CORE_LIB)"
	@if [ "$(UNAME)" = "Darwin" ]; then codesign --force --sign - "$(STAGE)/$(CORE_LIB)" 2>/dev/null || true; fi
	@cp README.md "$(STAGE)/README.md"
	@printf '%s\n' \
		'#!/bin/sh' \
		'# CAUSEWAYBAY OFFICE - runs the .love beside this script with the LÖVE' \
		'# on PATH (or $$LOVE). The core library is found next to the archive.' \
		'set -eu' \
		'here=$$(CDPATH= cd -- "$$(dirname -- "$$0")" && pwd)' \
		'exec "$${LOVE:-love}" "$$here/$(APP_NAME).love" "$$@"' \
		> "$(STAGE)/$(APP_NAME)"
	@chmod +x "$(STAGE)/$(APP_NAME)"
	@echo "  staged $(STAGE)"
	@ls -1lh "$(STAGE)" | tail -n +2 | awk '{printf "    %-28s %s\n", $$9, $$5}'
	@echo
	@echo "  Needs LÖVE $(LOVE_VERSION) on the machine that runs it: $(STAGE)/$(APP_NAME)"

# Prove the staged bundle loads its own core through the same cdef the app
# uses, with no checkout beside it. Headless, so CI can run it on every OS.
package-smoke: package require-luajit
	@CBO_TEST_BUNDLE="$(STAGE)" $(LUAJIT) $(RUST)/examples/ffi_smoke.lua
	@echo "  the packaged core loads from $(STAGE)"

# ------------------------------------------------------------------ macOS app

# LÖVE for the bundle: the installed copy when there is one, otherwise the
# official release zip, downloaded once into love2d/build.
LOVE_DL_APP := $(BUILD)/love-macos/love.app
LOVE_SRC_APP = $(if $(wildcard $(LOVE_APP)/Contents/MacOS/love),$(LOVE_APP),$(LOVE_DL_APP))

$(LOVE_DL_APP):
	@mkdir -p "$(BUILD)"
	@echo "  fetching LÖVE $(LOVE_VERSION)"
	@curl -fsSL -o "$(BUILD)/love-macos.zip" "$(LOVE_URL)"
	@rm -rf "$(BUILD)/love-macos" && unzip -q -o "$(BUILD)/love-macos.zip" -d "$(BUILD)/love-macos"
	@rm -f "$(BUILD)/love-macos.zip"

# The dylib goes to Contents/Frameworks (where a bundle keeps libraries) and
# also next to the archive in Contents/Resources, because cbo_cdef.lua looks
# beside the source first. LÖVE runs Contents/Resources/<anything>.love when
# no argument is given, so the cask's own game.love must not survive the copy.
app: core love
	@test "$(UNAME)" = "Darwin" || { echo "  'make app' is macOS only." >&2; exit 1; }
	@$(MAKE) --no-print-directory "$(LOVE_SRC_APP)"
	@rm -rf "$(APP)" "$(BUILD)/$(APP_NAME)-macos.zip"
	@cp -R "$(LOVE_SRC_APP)" "$(APP)"
	@cp "$(GAME_LOVE)" "$(APP)/Contents/Resources/$(APP_NAME).love"
	@mkdir -p "$(APP)/Contents/Frameworks"
	@cp "$(CORE_BIN)" "$(APP)/Contents/Frameworks/libcbo_core.dylib"
	@cp "$(CORE_BIN)" "$(APP)/Contents/Resources/libcbo_core.dylib"
	@plutil -replace CFBundleName -string "$(DISPLAY_NAME)" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(DISPLAY_NAME)" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleVersion -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	@plutil -remove CFBundleDocumentTypes "$(APP)/Contents/Info.plist" 2>/dev/null || true
	@plutil -remove UTExportedTypeDeclarations "$(APP)/Contents/Info.plist" 2>/dev/null || true
	@plutil -replace CFBundleExecutable -string "love" "$(APP)/Contents/Info.plist"
	@plutil -replace NSHighResolutionCapable -bool true "$(APP)/Contents/Info.plist"
	@find "$(APP)/Contents/Resources" -name '*.love' -not -name '$(APP_NAME).love' -delete
	@$(MAKE) --no-print-directory app-icon
	@$(MAKE) --no-print-directory app-sign
	@if [ -n "$(SKIP_SMOKE)" ]; then \
		echo "  smoke test skipped (SKIP_SMOKE set)"; \
	else \
		$(MAKE) --no-print-directory app-smoke; \
	fi
	@cd "$(BUILD)" && ditto -c -k --sequesterRsrc --keepParent "$(APP_NAME).app" "$(APP_NAME)-macos.zip"
	@echo
	@du -sh "$(APP)" "$(BUILD)/$(APP_NAME)-macos.zip" | sed 's/^/    /'
	@echo
	@echo "  Open it with: open \"$(APP)\""

# The icon, from the key art. It is 16:9, so it is padded to a square first
# (sips will not do that itself) and every size is generated from the pad.
app-icon:
	@test -f $(GAME)/assets/logo_hero.png || { echo "  no logo_hero.png; keeping LÖVE's icon"; exit 0; }
	@rm -rf "$(BUILD)/icon.iconset" && mkdir -p "$(BUILD)/icon.iconset"
	@sips -s format png -p 1280 1280 $(GAME)/assets/logo_hero.png --out "$(BUILD)/icon-square.png" > /dev/null 2>&1
	@for size in 16 32 64 128 256 512 1024; do \
		sips -s format png -z $$size $$size "$(BUILD)/icon-square.png" \
			--out "$(BUILD)/icon.iconset/icon_$${size}x$${size}.png" > /dev/null 2>&1; \
	done
	@for size in 16 32 128 256 512; do \
		double=$$((size * 2)); \
		cp "$(BUILD)/icon.iconset/icon_$${double}x$${double}.png" \
			"$(BUILD)/icon.iconset/icon_$${size}x$${size}@2x.png" 2>/dev/null || true; \
	done
	@rm -f "$(BUILD)/icon.iconset/icon_1024x1024.png"
	@iconutil -c icns "$(BUILD)/icon.iconset" -o "$(BUILD)/icon.icns"
	@cp "$(BUILD)/icon.icns" "$(APP)/Contents/Resources/OS X AppIcon.icns" 2>/dev/null || true
	@cp "$(BUILD)/icon.icns" "$(APP)/Contents/Resources/Love.icns" 2>/dev/null || true
	@rm -rf "$(BUILD)/icon.iconset" "$(BUILD)/icon.icns" "$(BUILD)/icon-square.png"
	@echo "  icon from love2d/assets/logo_hero.png"

# Signed inside-out: nested binaries, then the executable, then the bundle.
# LuaJIT needs allow-jit and allow-unsigned-executable-memory under the
# hardened runtime, and disable-library-validation because libcbo_core is
# not signed by whoever signed LÖVE. APPLE_SIGNING_IDENTITY wins when set
# (the release workflow exports it); a keychain search is the laptop path.
app-sign:
	@test -d "$(APP)" || { echo "  no $(APP); run 'make app'" >&2; exit 1; }
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'  <key>com.apple.security.cs.allow-jit</key><true/>' \
		'  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>' \
		'  <key>com.apple.security.cs.disable-library-validation</key><true/>' \
		'  <key>com.apple.security.network.client</key><true/>' \
		'</dict></plist>' \
		> "$(BUILD)/entitlements.plist"
	@identity="$${APPLE_SIGNING_IDENTITY:-}"; \
	if [ -z "$$identity" ] || [ "$$identity" = "-" ]; then \
		identity=$$(security find-identity -v -p codesigning 2>/dev/null \
			| grep "Developer ID Application" | head -1 | awk -F'"' '{print $$2}'); \
	fi; \
	if [ -z "$$identity" ]; then \
		identity="-"; echo "  no Developer ID found - signing ad-hoc (runs here, not elsewhere)"; \
	else \
		echo "  signing as $$identity"; \
	fi; \
	stamp=--timestamp; [ "$$identity" = "-" ] && stamp=""; \
	find "$(APP)/Contents/Frameworks" "$(APP)/Contents/Resources" -type f 2>/dev/null | while read -r file; do \
		if file "$$file" | grep -q "Mach-O"; then \
			codesign --force --options runtime --sign "$$identity" \
				--entitlements "$(BUILD)/entitlements.plist" $$stamp "$$file" || exit 1; \
		fi; \
	done; \
	find "$(APP)/Contents/Frameworks" -maxdepth 1 -name "*.framework" 2>/dev/null | while read -r bundle; do \
		codesign --force --options runtime --sign "$$identity" \
			--entitlements "$(BUILD)/entitlements.plist" $$stamp "$$bundle" || exit 1; \
	done; \
	codesign --force --options runtime --sign "$$identity" \
		--entitlements "$(BUILD)/entitlements.plist" $$stamp "$(APP)/Contents/MacOS/love" || exit 1; \
	codesign --force --options runtime --sign "$$identity" \
		--entitlements "$(BUILD)/entitlements.plist" $$stamp "$(APP)" || exit 1
	@rm -f "$(BUILD)/entitlements.plist"
	@codesign --verify --deep --strict "$(APP)" && echo "  signature verifies"

# Start the bundle and see whether it draws. The only test here that runs the
# .app rather than the checkout: a module missing from the archive dies on
# the first `require`, which is instant, so twenty seconds without a frame
# means it did not start. Uses the in-app shot harness (--shots=maps).
app-smoke:
	@test -d "$(APP)" || { echo "  no $(APP); run 'make app'" >&2; exit 1; }
	@rm -rf "$(BUILD)/smoke.log"
	@"$(APP)/Contents/MacOS/love" --shots=maps > "$(BUILD)/smoke.log" 2>&1 & \
	pid=$$!; ok=0; \
	for _ in $$(seq 1 40); do \
		if ! kill -0 $$pid 2>/dev/null; then wait $$pid && ok=1; break; fi; \
		grep -q "\[core\] loaded" "$(BUILD)/smoke.log" 2>/dev/null && ok=1 && break; \
		sleep 0.5; \
	done; \
	kill $$pid 2>/dev/null || true; wait $$pid 2>/dev/null || true; \
	if [ $$ok -ne 1 ]; then \
		echo "  the bundle did not start:" >&2; head -20 "$(BUILD)/smoke.log" >&2; exit 1; \
	fi
	@rm -f "$(BUILD)/smoke.log"
	@echo "  the bundle starts and loads its core"

# Notarise and staple the built .app. Not part of `make app`: it needs Apple
# credentials this repository must not carry, and it uploads to Apple and
# waits. The variable names are CausewaybayWallet's, so one exported set
# covers both repositories:
#     export APPLE_ID=you@example.com
#     export APPLE_PASSWORD=abcd-efgh-ijkl-mnop   # app-specific
#     export APPLE_TEAM_ID=ABCDE12345
#     make notarize
notarize:
	@test -d "$(APP)" || { echo "  no $(APP); run 'make app' first" >&2; exit 1; }
	@for name in APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do \
		eval "value=\$$$$name"; \
		[ -n "$$value" ] || { echo "  $$name is not set (Apple ID, app-specific password, team id)." >&2; exit 1; }; \
	done
	@codesign -dv --verbose=2 "$(APP)" 2>&1 | grep -q "Authority=Developer ID Application" || { \
		echo "  $(APP) is not signed with a Developer ID; Apple refuses ad-hoc signatures." >&2; exit 1; }
	@echo "  submitting to Apple - this takes minutes, not seconds"
	@ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(BUILD)/notarize.zip"
	@xcrun notarytool submit "$(BUILD)/notarize.zip" \
		--apple-id "$$APPLE_ID" --password "$$APPLE_PASSWORD" --team-id "$$APPLE_TEAM_ID" \
		--wait --timeout 20m
	@rm -f "$(BUILD)/notarize.zip"
	@xcrun stapler staple "$(APP)"
	@xcrun stapler validate "$(APP)"
	@# The distribution zip predates the staple; rebuild it or the download is unchanged.
	@rm -f "$(BUILD)/$(APP_NAME)-macos.zip"
	@cd "$(BUILD)" && ditto -c -k --sequesterRsrc --keepParent "$(APP_NAME).app" "$(APP_NAME)-macos.zip"
	@$(MAKE) --no-print-directory gatekeeper

# What a person who downloads it will get. `--context context:primary-signature`
# is what Finder asks; plain `spctl -a` accepts an un-notarised Developer ID.
gatekeeper:
	@test -d "$(APP)" || { echo "  no $(APP); run 'make app' first" >&2; exit 1; }
	@codesign --verify --deep --strict "$(APP)" && echo "  signature: valid"
	@if xcrun stapler validate "$(APP)" > /dev/null 2>&1; then \
		echo "  notarised: yes, and stapled"; \
	else \
		echo "  notarised: NO - a downloaded copy will be blocked"; \
	fi
	@spctl -a -vvv -t open --context context:primary-signature "$(APP)" 2>&1 | sed 's/^/  /' || true

clean:
	rm -rf $(BUILD) $(DIST_DIR) $(GAME)/.tmp_save_test
	cd $(RUST) && $(CARGO) clean 2>/dev/null || true
