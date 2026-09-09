# Testing and verification

Run `make test` for the complete maintained suite. It builds the release Rust core,
runs every test layer, and returns nonzero if any stage fails. Failed stages do not
prevent independent stages from running, so the report captures all failures.

## Prerequisites

- Rust/Cargo, Python 3, LuaJIT and LÖVE 11.5. Override `CARGO`, `PYTHON`, `LUAJIT`
  and `LOVE` in the Make invocation when needed.
- A local SSH server on port 22 accepting the current user through SSH agent/key.
  The full suite requires real SSH; it does not silently skip this integration.
- GUI access for LÖVE tests and walkthroughs.
- Provider integration uses `OPENAI_API_KEY`, `XAI_API_KEY`/`GROK_API_KEY`, and
  `ANTHROPIC_API_KEY` when configured. These checks use the network and may incur
  API charges. Missing provider keys are reported as explicit skipped checks.

## What `make test` runs

| Layer | Coverage |
| --- | --- |
| Rust unit tests | SQLite migrations, persistence, command learning, patterns, search, stream parsing, terminal logic and safety guards |
| Rust doc tests | Every compiled documentation example |
| Rust integration tests | Every `rust/tests/*.rs` target, discovered automatically: database, ABI, providers, SSE HTTP fixtures, names/search, real SSH and terminal rendering |
| LuaJIT FFI | Every C header export resolves; persistence and recorder/search calls work through the real dylib |
| LÖVE unit/regression suite | Fields, masks, layouts, input routing, map stages/panning, 100 sessions, JSONL restore model, names, and completion without execution |
| Real UI `maps` | Two localhost sessions; both maps; portrait and panning; automatic favorites; empty stage connection form; SQLite field reuse; real echoed-command completion; zoom into the exact session and back; circular disconnect with other sessions/favorites retained |
| Real UI `aichat` | Open chat through its shortcut, click SEND, receive a real provider response, review insertion, and verify chat below the terminal in portrait and beside it in landscape |
| Real UI `restorewrite` | Connect two sessions, rename one and exit while retaining their JSONL restore records |
| Real UI `restoreread` | A separate app process loads the records, reconnects both, verifies names and persists an explicit close |

The full runner sets `CBO_IT=1` and `CBO_LIVE=1`. Each Rust target and independent
walkthrough gets a fresh temporary `CBO_HOME`; the restart pair shares one directory
across two processes. Real user favorites, settings, history and restore records are
not used. LÖVE tests/screenshots also use separate application save identities.

Reports are kept under `love2d/build/test-results/<timestamp-pid>/`:

- One log per stage, containing the original test output.
- `report.json` with commands’ exit status, duration, reported test count, skipped
  checks and log path. The report is updated after each stage.

Provider tests without a key return early inside Rust's harness. Their skip messages
are preserved separately in the JSON report; a harness “passed” count includes these
skipped checks. Check `skips` when evaluating coverage.

## Other commands

- `make check`: formatting, Lua compilation, Clippy with warnings denied, then the full suite.
- `make test-unit`: Rust library unit tests and the LÖVE regression suite.
- `make test-integration`: every Rust integration target, FFI and real UI/restart checks.
- `make test-ui-integration`: the four real UI walkthroughs only.
- `make test-live`: provider/embedding tests only.
- `make test-ffi`: ABI smoke test only.
- `make app`: rebuild the macOS application bundle and zip.

`make start ARGS=--shots=maps` can also run the latest interactive walkthrough on
its own. Other screenshot phases are developer art/diagnostic scripts, not additional
unit-test targets.
