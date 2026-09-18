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
| Source consistency | `tools/check_consistency.py`: every `--shots` phase is wired into the runner or listed as deliberately unwired, nothing asserts a scene the lobby no longer has, Help names every lobby layout, all three lobbies answer the same chords, the auto-name check still matches the names `sessions.lua` builds. No GUI, so CI runs it too |
| Real UI walkthroughs | Every phase in `PHASES` in `tools/run_tests.py`, cheapest first: `display limit files folders commander map portrait mock polish monitors maps aichat assist kitty notes hotnote qa verify nav nav2 map3 map3verify display3 restorewrite restoreread` |

Phases of note:

| Phase | Coverage |
| --- | --- |
| `qa` | The docs/QA_CHECKLIST walkthrough against localhost: boot, connect, Unicode widths, AI panel reflow, zoom, bezel, disconnect and slot reuse, settings persistence |
| `maps` | Two localhost sessions; both maps; portrait and panning; automatic favorites; empty stage connection form; SQLite field reuse; real echoed-command completion; zoom into the exact session and back; circular disconnect with other sessions/favorites retained |
| `aichat` | Open chat through its shortcut, click SEND, receive a real provider response, review insertion, and verify chat below the terminal in portrait and beside it in landscape |
| `assist` | Assist page against the real core: a code answer with RUN/PRACTICE, local practice with no shell writes, a delayed real command that requires its completion marker, the AGI page adding a live tool, the playground reporting a provider, and an external `curl` JSON-RPC call to the MCP server arriving as a bubble |
| `files` / `folders` | SFTP browser, the in-app upload picker, terminal download picking, click-to-cd |
| `commander` / `monitors` | Map 3 monitor wall: 100 simulated screens, WORD ART broadcast, focus and zoom |
| `restorewrite` / `restoreread` | Connect two sessions, rename one and exit retaining their JSONL restore records; a separate process reloads them, reconnects both and persists an explicit close |

Each `PHASES` row is `(phase, group, needs_mock)`. The group is both the temporary
`CBO_HOME` and `CBO_QA_GROUP`, which scopes the LÖVE save-directory `config.json`
that `config.lua` imports once into a fresh SQLite home. Two phases sharing a group
share persisted settings **on purpose** — that is what a restart pair is
(`qa`+`verify`, `nav`+`nav2`, `map3`+`map3verify`, `restorewrite`+`restoreread`) —
and two phases in different groups cannot leak into each other. Before this was
scoped, a single `--mock` phase writing that file seeded every later phase and every
later run. `needs_mock` phases assert `App.core.mock` and must be launched with
`--mock`; `check_consistency.py` fails the build if one is wired without it. The
shell-side scratch directory follows the same group: `/tmp/cbo_qa-<group>`, because
the `qa` phase wipes it on startup while `map3verify` reads what `map3` left in it.

The full runner sets `CBO_IT=1` and `CBO_LIVE=1` for **every** stage, so `make test`
spends provider credit whenever a key is in the environment — `make test-live` is the
provider-only subset, not the only place live calls happen. Each Rust target and each
walkthrough group gets a fresh temporary `CBO_HOME`. Real user favorites, settings,
history and restore records are not used. LÖVE tests/screenshots use separate
application save identities.

Focused MCP security checks: `cargo test --manifest-path rust/Cargo.toml --release
--lib mcp::tests`. These use temporary loopback sockets to check origin/host and
token rejection, bounded headers and connections, request deadlines, STOP, and
legacy token replacement. The LÖVE regression suite verifies that Privacy mode
does not draw the MCP token and explicit copy still returns a working URL.

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
- `make test-ui-integration`: the real UI walkthroughs only (every phase in `PHASES`).
- `make lint-consistency`: the cross-file source rules on their own; needs no GUI.
- `make test-live`: provider/embedding tests only.
- `make test-ffi`: ABI smoke test only.
- `make app`: rebuild the macOS application bundle and zip.

`make start ARGS=--shots=maps` can also run one walkthrough on its own; add
`CBO_QA_GROUP=<name>` to give it its own settings, as the runner does.

The phases that stay out of `make test` are listed, with a reason each, in `UNWIRED`
in `tools/check_consistency.py`: `art` and `perf` (art capture and machine-specific
fps sampling), `monitors100` (the 100-screen art variant of `monitors`), and
`codeagent`/`codeagentgo` (they spend API credit and need a human to click ALLOW).
Adding a phase without wiring it or listing it there fails CI — an unrun phase rots,
which is how ten assertions about a scene that no longer exists survived sixteen
commits.

Note `--shots=map3` is the phase-3 *world map* walkthrough, not the Map 3 monitor
wall; that one is `commander` / `monitors`.


## Live coding agent

Run `make test-codeagent` with `GROK_API_KEY` or `XAI_API_KEY`, localhost SSH,
and Rust available in the remote shell. This explicit test uses API credit.
It opens AI Assist, sends `write rust code for helloworld` to Grok, and enables
CODE in the test app. Review each shell operation and click ALLOW in the window.
Confined writes require `python3` on the SSH host. The checks require a `write_file` tool result,
Rust source on disk, and a successful compile/run result containing Hello World.
The source, conversation/tool trace, and screenshots remain in the isolated
LÖVE QA folder for review. Missing keys and failed runs fail the test.

`make start ARGS=--shots=codeagentgo` exercises the Go producer/consumer prompt.
For QA automation, each waiting operation is exported to `codeagent_pending.json`
in the QA folder. After reviewing that exact call, write its ID (without a newline)
to `love2d/build/codeagent-approval.txt` to simulate clicking ALLOW once. The test
never approves model commands automatically. The regression suite covers parent
traversal, sibling paths, symlink escapes, and CODE/Auto Run approval bypasses.
