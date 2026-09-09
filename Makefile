# CAUSEWAYBAY OFFICE
# Usage: make / make help / make core / make start / make test / make check / make app
#
# Two halves, one contract:
#   rust/    cargo crate `cbo_core` -> libcbo_core.dylib (SSH, VT100, LLM streaming)
#   love2d/  LÖVE 11.5 app that loads the dylib through LuaJIT FFI
# rust/include/cbo.h is the source of truth for the boundary; `make cdef`
# regenerates the Lua mirror from it.

.DEFAULT_GOAL := help
.PHONY: help version core core-debug cdef start start-mock test test-unit test-core test-integration test-ui-integration test-ffi test-love test-live \
        lint lint-lua lint-rust format fmt fmt-check check smoke art love app clean \
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
		'make app         unsigned macOS .app with LÖVE + libcbo_core inside' \
		'make clean       remove build output' \
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

APP_NAME     := CausewaybayOffice
DISPLAY_NAME := Causewaybay Office
BUNDLE_ID    := com.causewaybay.office
BUILD        := $(GAME)/build
APP          := $(BUILD)/$(APP_NAME).app
GAME_LOVE    := $(BUILD)/$(APP_NAME).love

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
	@echo "  $(GAME_LOVE) ($$(du -h '$(GAME_LOVE)' | cut -f1))"

# A double-clickable, unsigned macOS .app: a copy of the installed love.app
# with the .love archive and libcbo_core.dylib inside. The dylib goes to
# Contents/Frameworks (where a bundle keeps libraries) and also next to the
# archive in Contents/Resources, because cbo_cdef.lua looks for it beside the
# source first. Signing/notarising is deliberately not here (see Raiden for
# the full recipe); ad-hoc is enough to run locally.
app: core love
	@test "$$(uname -s)" = "Darwin" || { echo "  'make app' is macOS only." >&2; exit 1; }
	@test -d "$(LOVE_APP)" || { \
		echo "  no $(LOVE_APP); run 'make require-love' for install instructions" >&2; exit 1; }
	@rm -rf "$(APP)" "$(BUILD)/$(APP_NAME)-macos.zip"
	@cp -R "$(LOVE_APP)" "$(APP)"
	@cp "$(GAME_LOVE)" "$(APP)/Contents/Resources/$(APP_NAME).love"
	@mkdir -p "$(APP)/Contents/Frameworks"
	@cp "$(DYLIB)" "$(APP)/Contents/Frameworks/libcbo_core.dylib"
	@cp "$(DYLIB)" "$(APP)/Contents/Resources/libcbo_core.dylib"
	@plutil -replace CFBundleName -string "$(DISPLAY_NAME)" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(DISPLAY_NAME)" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleVersion -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	@plutil -remove CFBundleDocumentTypes "$(APP)/Contents/Info.plist" 2>/dev/null || true
	@plutil -remove UTExportedTypeDeclarations "$(APP)/Contents/Info.plist" 2>/dev/null || true
	@plutil -replace NSHighResolutionCapable -bool true "$(APP)/Contents/Info.plist"
	@# LÖVE runs Contents/Resources/<anything>.love when no argument is given,
	@# so a stray game.love from the source cask must not be there too.
	@find "$(APP)/Contents/Resources" -name '*.love' -not -name '$(APP_NAME).love' -delete
	@codesign --force --deep --sign - "$(APP)" 2>/dev/null || true
	@cd "$(BUILD)" && ditto -c -k --sequesterRsrc --keepParent "$(APP_NAME).app" "$(APP_NAME)-macos.zip"
	@echo
	@du -sh "$(APP)" "$(BUILD)/$(APP_NAME)-macos.zip" | sed 's/^/    /'
	@echo
	@echo "  Open it with: open \"$(APP)\""

clean:
	rm -rf $(BUILD) $(GAME)/.tmp_save_test
	cd $(RUST) && $(CARGO) clean 2>/dev/null || true
