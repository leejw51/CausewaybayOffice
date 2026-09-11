# CLAUDE.md — CAUSEWAYBAY OFFICE

Retro 8-bit terminal SSH client. Rust core (`rust/`, cdylib `cbo_core`) +
LÖVE 11.5 / LuaJIT UI (`love2d/`). Read `docs/SPEC.md` before changing anything.

## The contract

* `rust/include/cbo.h` is the **source of truth** for the FFI boundary.
  `love2d/src/cbo_cdef.lua` is generated from it: after editing the header run
  `make cdef` and commit both. Never hand-edit the cdef block.
* Strings across the boundary are UTF-8, NUL-terminated. Every `const char*`
  the core returns points at a **per-call thread-local buffer**: Lua must
  `ffi.string()` it before the next core call and must never free it.
* **The core never calls Lua.** No callbacks. Lua polls from `love.update`
  every frame: session state, `cbo_term_generation` (redraw only when it
  changes), `cbo_llm_take_delta`, `cbo_term_take_bell`.
* Max 128 sessions; `cbo_session_open` returns -1 when full. Ids are reused
  only after `cbo_session_free`.
* `CboCell.width == 0` is the trailing half of a wide glyph: draw nothing.
  Colours are already resolved to 0xRRGGBB in Rust.
* Kitty graphics (`ESC _ G`) are stripped in Rust; Lua polls
  `cbo_term_placements` on generation change, decodes payloads itself and
  paints them into the terminal canvas (z < 0 under the glyphs).
* **Function calling stays in Lua.** The core converts a neutral tool list and
  message log to each provider's shape (`cbo_llm_start_tools`) and assembles
  the streamed fragments (`cbo_llm_take_calls`); it never runs a tool. The
  panel executes them, so a command is visible in the terminal and needs the
  user's approval for unrestricted shell access. CODE / AUTO RUN only skip
  ordinary file-write reviews inside the turn's fixed workspace; outside
  operations always require per-operation approval.
* **MCP is polled like everything else.** `cbo_mcp_start` binds loopback only,
  answers JSON-RPC and queues `office_send` / `office_practice` /
  `office_type` in an inbox; `love.update` drains it with `cbo_mcp_take`.
  Nothing an MCP client sends reaches the shell without the review sheet.
* Assist-page body text is drawn in **screen** space at the terminal's own
  pixel grid (`AI:pushBodySpace`), never by scaling a 16 px face by a
  fraction.

## Ownership

| path | owns |
|---|---|
| `rust/src/lib.rs` | FFI surface only, no logic |
| `rust/src/{session,ssh,term,llm,names,search}.rs` | SSH, VT100, keepalive, LLM SSE, registry, names, fuzzy search |
| `rust/src/{notes,embed}.rs` | notes table + FTS; vectors per model (OpenAI or the local n-gram fallback) |
| `rust/src/store.rs` | private JSONL records (`apikeys.jsonl`, `tools.jsonl`), mode 0600 |
| `rust/src/mcp.rs` | MCP server (JSON-RPC over loopback HTTP) + the inbox Lua drains |
| `rust/src/graphics.rs` | kitty graphics protocol: APC split, image store, placements, replies |
| `love2d/src/core.lua` | Lua-friendly wrapper over the FFI (strings, tables, errors) |
| `love2d/src/{display,fx,gfx,term_view}.lua` | rendering, CRT, tweens, fonts |
| `love2d/src/scenes/*.lua` | boot, lobby, terminal + overlays |
| `love2d/src/{sessions,config,ai}.lua` | persistence, API keys, AI panel |
| `love2d/src/tools.lua` | AI tool registry (built-ins + user command tools) and executor |
| `love2d/src/scenes/agi.lua` | AGI page: tools, API keys, playground, MCP |
| `love2d/src/test.lua` | in-engine suite (`love love2d -- --test`) |
| `love2d/src/test_ai.lua` | in-engine suite for tools, the assist page, AGI and MCP |
| `python/gen_art.py` | asset generation |
| `tools/kitty_test.py` | kitty graphics emitter, probe and C-ABI self test over localhost ssh |
| `Makefile`, `README.md`, `docs/` | build tooling, docs |

Rust: SQLite/JSONL persistence and transport, no rendering. Lua: UI and session model using Rust persistence APIs, no networking or emulation. Raw recording and remote indexing are separate opt-ins, default off; simple echoed commands are learned separately.

## Run / test

```
make core        # cargo build --release (rust/)
make start       # core + love love2d      make start-mock  # no core
make test        # cargo test + in-engine suite
make check       # lint + test — run before every commit
make cdef        # after any change to cbo.h
make package     # portable bundle into dist/    make app  # macOS .app (signed if a Developer ID is present)
```

LÖVE is not on PATH: the Makefile uses `~/Applications/love.app/Contents/MacOS/love`
(override with `LOVE=`). luajit and stylua are in `/opt/homebrew/bin`.

## Conventions

* C ABI: `cbo_<area>_<verb>` (`cbo_session_open`, `cbo_term_snapshot`,
  `cbo_llm_take_delta`), structs `CboXxx`, enums `CBO_ST_*`, `CBO_ATTR_*`,
  `CBO_LLM_*`. Return `int32_t` (0 ok / -1 error / id >= 0); errors via
  `cbo_last_error()`.
* Rust: `snake_case` modules mirroring the header sections; `unsafe` only in
  `lib.rs`; every FFI fn catches panics at the boundary.
* Lua: modules return a table `M`; scene files expose `enter/update/draw/
  keypressed/textinput`; 2-space indent, stylua-formatted (`make format`).
* Game feel lives in Lua only: easing is expo in/out, nothing cuts.
* UI session names `<first-name>-<number>`, e.g. `mary-1`; custom names persist in sessions.jsonl. The legacy core naming API remains available.
* Version of record is `VERSION` (one line); `make version` checks it.
* Commit small, run `make check` first. Do not commit `rust/target`,
  `love2d/build`, `*.love`.
