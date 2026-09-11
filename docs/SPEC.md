# CAUSEWAYBAY OFFICE — MVP spec (v0.1.0)

A retro 8-bit terminal SSH client that feels like an MSX2 / Amiga / Genesis game
but is built for real office work: ssh, coding, and an AI sidekick.
Same universe as CAUSEWAYBAY RAIDEN (/Volumes/nvidia/vivid/CausewaybayRaiden):
the rust coder hero, Wonder Boy style sprites, Causeway Bay Hong Kong backdrop.

## Layout

```
CausewaybayOffice/
  Makefile            top-level: build core, start, test, check
  VERSION
  docs/SPEC.md        this file (the contract)
  rust/               cargo crate `cbo_core` -> cdylib (libcbo_core.dylib)
    include/cbo.h     C ABI header (source of truth, mirrored in love2d/src/cbo_cdef.lua)
    src/lib.rs        FFI surface only (thin, no logic)
    src/session.rs    session registry (max 128), state machine, keepalive
    src/ssh.rs        ssh2 transport, auth (key/agent/password), pty, thread per session
    src/term.rs       VT100/xterm emulation via `vt100` crate, snapshot to CboCell grid
    src/graphics.rs   kitty graphics protocol: APC split, image store, placements, replies
    src/llm.rs        streaming chat completions: openai, anthropic, xai
    src/names.rs      memorable session names
    src/search.rs     fuzzy session search
  love2d/             LÖVE 11.5 app (LuaJIT FFI loads libcbo_core)
    main.lua conf.lua
    src/cbo_cdef.lua  ffi.cdef mirror of cbo.h + loader (searches rust/target/{release,debug})
    src/core.lua      Lua-friendly wrapper around the FFI (strings, tables, errors)
    src/display.lua   virtual resolution, pixel scale, CRT canvas (from Raiden style)
    src/fx.lua        easing (expo in/out), tweens, fades, particles, screen shake
    src/gfx.lua       palette, chroma-key sprite loader, fonts (PressStart2P + Unifont fallback)
    src/term_view.lua draws a session's CboCell grid (wide CJK cells = 2 columns)
    src/scenes/*.lua  boot -> lobby (session cards) -> terminal, overlays: connect, search, rename, settings, ai
    src/sessions.lua  session list model, persistence (love.filesystem json), auto-names
    src/ai.lua        AI panel driving cbo_llm_*
    src/config.lua    api keys (client side, saved in love save dir), env-var fallback
    src/test.lua      in-engine tests (`love . --test`)
    assets/           generated sprites/backgrounds (magenta chroma key like Raiden), fonts/
  python/gen_art.py   xAI grok-imagine-image asset generator (GROK_API_KEY)
  tools/kitty_test.py kitty graphics emitter / probe / C-ABI self test over localhost ssh
```

## Core rules

* **Rust owns**: SSH transport, terminal emulation, keepalive, LLM HTTP streaming,
  session registry, naming, search. No persistence, no rendering.
* **Lua owns**: everything visual, input, session list persistence, API key storage,
  settings, and all game-feel (tweens, particles, sound).
* **FFI contract** = `rust/include/cbo.h`. Lua mirrors it in `src/cbo_cdef.lua`.
  Change both or neither.
* Strings across the boundary are UTF-8, NUL-terminated. `const char*` returned by
  the core points to a **per-call, thread-local buffer**: copy it (ffi.string) before
  the next core call. Never free it.
* Everything is polled from `love.update` — the core never calls back into Lua.
* Max **128** sessions. `cbo_session_open` returns -1 when full.
* Session ids are small ints, reused after close only after `cbo_session_free`.
* Keepalive: core thread sends SSH keepalive every `interval` seconds (default 15),
  and Lua shows a heartbeat pulse on the session card each time `last_ping` changes.
* Terminal cells: `CboCell {cp:u32, fg:u32, bg:u32, attr:u8, width:u8}`; colors are
  0xRRGGBB already resolved against the retro palette in Rust (16 ANSI + 256 + truecolor).
  `width==0` marks the trailing half of a wide (CJK) glyph: draw nothing there.
* Unicode: UTF-8 in, code points out. Wide chars (CJK/Hangul/Kana) occupy 2 cells.
  Czech diacritics are width 1. Combining marks are merged into the base cell (Rust side).

## Session names

Auto-generated, memorable, Hong Kong flavoured: `<adjective>-<hk-noun>-<NN>`,
e.g. `neon-tram-07`, `jade-junk-42`, `dimsum-ferry-13`. Unique among live sessions.
User can rename (any UTF-8, ≤ 32 chars). Search is fuzzy over name + host + user + tags.

## LLM providers (client-side keys, never sent anywhere but the provider)

| provider  | endpoint                                    | default model      | auth header |
|-----------|---------------------------------------------|--------------------|-------------|
| openai    | https://api.openai.com/v1/chat/completions   | gpt-5              | Authorization: Bearer |
| xai       | https://api.x.ai/v1/chat/completions         | grok-4.6           | Authorization: Bearer |
| anthropic | https://api.anthropic.com/v1/messages        | claude-opus-5      | x-api-key + anthropic-version: 2023-06-01 |

All streamed (SSE). Anthropic: `content_block_delta` / `text_delta`. OpenAI/xAI:
`choices[0].delta.content`, terminated by `data: [DONE]`. Keys come from the settings
UI (saved in love save dir `config.json`) with env fallback
OPENAI_API_KEY / ANTHROPIC_API_KEY / XAI_API_KEY (GROK_API_KEY alias).

## Game feel

* Boot: CRT power-on flash, logo fades in (expo-out), Causeway Bay skyline parallax.
  The title waits for Space: no timer, no click, no other key (2026-09-10).
* Lobby: session cards on a shelf; new card slides in (expo-out), close pops out (expo-in).
  Cards pulse with the keepalive heartbeat; disconnected cards flicker red.
* Terminal: cool-retro-term style screen (`fx.retro`, Settings "CRT phosphor fx" or the
  RETRO top-bar button shown on the terminal page; "CRT tube colour" picks amber / green /
  white / off; the FONT 1x/2x status-bar button cycles the terminal zoom; PRIVACY (in the
  app-wide top bar beside FULLSCREEN / VERTICAL, and Settings "privacy: mask ids")
  draws user names, IP addresses and ports as stars for video or screen capture, keeping
  session names and computer names). Motion is calm by design: slow drift, 12 Hz grain,
  breathing brightness, no per-frame shake:
  phosphor burn-in that fades, quarter-res bloom, RGB shift, jitter, horizontal
  sync tears, static noise, a sweeping glow line and flicker, on top of the
  scanline + subtle barrel overlay. The cursor is a rust-coloured block that
  breathes and glides between cells (expo in/out, duration grows with distance),
  fading out on the way and back in on arrival, with an additive afterimage trail
  and a puff of embers; bell = screen shake + flash; connect success = particle
  burst + jingle.
* World map: saved hosts are stages on a Super-Mario-World overworld; the hero walks
  the path graph (expo-in-out per segment, cosine bob, dust puffs), hops with confetti on
  arrival, then connects (amber node while connecting, flag + jingle when online, red
  flicker + buzz on error). Nodes breathe, clouds drift, the camera pans with expo-out.
* Display: F11 / Settings toggle fullscreen (desktop) with a fade; orientation auto /
  landscape / portrait (Ctrl+O) reflows every scene: portrait stacks the AI panel below
  the terminal (>= 24 rows kept) and keeps the horizontal world map, fitted to the width
  (camera only, no separate tall route).
* Every transition fades exponentially; nothing cuts.
* Keys: F1 help, Ctrl+N new session, Ctrl+Tab / Ctrl+Shift+Tab cycle, Ctrl+K search,
  Ctrl+R rename, Ctrl+, settings, Ctrl+Space AI panel, F11 fullscreen, Esc = raw ESC to
  the shell, F2 / Ctrl+Esc / double-tap Esc (300 ms) back to the lobby, M world map,
  Ctrl+O orientation.
  (Ctrl+C etc. go to the terminal when a session is focused.)

## Acceptance (MVP)

1. `make core && make start` opens the app; `make test` passes (cargo test + love --test).
2. Connect to `localhost` with the ssh agent/key, run `ls`, `top`, `vim`; output renders correctly.
3. `echo 你好 안녕 こんにちは Příliš žluťoučký kůň` renders with correct widths.
4. Open 3 sessions, search by name, rename one, cycle between them; keepalive keeps
   an idle session alive > 5 min.
5. AI panel answers a question via any of the three providers with a key set in settings.


## Current implementation notes (2026-09-09 repair)

The persistence extension supersedes the MVP’s “no persistence in Rust” rule:
Rust owns SQLite recording/search/command prediction; Lua retains settings and
saved-host JSON. Recording and remote OpenAI indexing are separate opt-ins,
both off by default. A configured chat API key alone never enables indexing.
`cbo_shutdown` flushes queued recordings before exit. The C header remains the
source of truth; `make cdef` regenerates its Lua mirror.

Ctrl+Shift+K opens local history/completion/prediction. AI Ctrl+Enter opens a
review before sending input. Bracketed paste follows the remote DECSET 2004 mode.
Saved hosts reconnect by explicit selection. Live fuzzy search covers names,
hosts and users; tag editing/search is still a roadmap item. Combining marks have
correct cell width but only precomposed accents can be drawn by the current ABI.


Further implementation updates: Map2 is a searchable/filterable session grid.
Mario Map shows each live session separately (including duplicate server addresses),
plus offline favorites and empty connect stages. Portrait uses a tall route.
Two shared display toggles are always available above pages and overlays.

Settings and non-secret field drafts/history now live in SQLite. Existing Lua JSON
files are imported on first use. Favorites are maintained as an atomic JSONL snapshot
at ~/.causewaybayoffice/favorites.jsonl, with a SQLite cache. Display changes append
to display.jsonl in that directory. CBO_HOME overrides the directory for all three.
Field history excludes passwords/API keys, offers Ctrl+Space reuse, and is independent
of terminal recording and remote indexing consent.

Latest interaction requirements supersede earlier reconnect/name notes: successfully
connected sessions are saved to sessions.jsonl and automatically restored on startup,
with separate records for duplicate addresses. Explicitly closed sessions are removed.
Each record also keeps the remote working directory (`cwd`): the core reports it from
OSC 7 or a `user@host: path` title (`cbo_term_cwd`), Lua saves it per session and per
host (`cwd.<user>@<host>:<port>` in settings), and the next connection to that session or
host types a quoted `cd` once the screen has been quiet after the first prompt.
New UI names follow mary-1, john-2, etc.; custom names persist. Tests cover 100 sessions
in the UI/restore model within the existing 128-slot core.

Map panning uses drag, wheel or Shift+Arrow; Home recenters the selected stage.
Terminal completions appear as dimmed ghost text after the cursor and in the status bar;
Right arrow (no modifier) or Ctrl+Space accepts the literal-prefix completion without Enter,
and readiness comes from the echo (the typed text visible on the cursor line), not from the
prompt's last character, so emoji/word prompts work and hidden input never qualifies. A forced
orientation is remembered together with the window shape it was chosen for and drops back to
auto when that shape changes. Ctrl+Shift+Space
opens AI. Simple, visibly echoed prompt commands and their sequences are learned
locally in SQLite independently of raw recording. Ambiguous edits, hidden input and
alternate-screen input are excluded from command-only learning.

## Images (kitty graphics protocol, 2026-09-09)

`ESC _ G <k=v,...>;<base64> ESC \` sequences are split out of the byte stream
in Rust before the VT parser sees them (`graphics.rs`), so payloads never reach
the cell grid. The core keeps images as sent (PNG, or raw RGB/RGBA with `s`/`v`,
optionally zlib `o=z`, chunked with `m=1`), answers the client
(`ESC _ G i=<id>;OK ESC \` or `ECODE:msg`, honouring `q`), and refuses
non-direct media (`t=f/t/s`) with `EBADF` so `kitten icat` streams instead.
Actions: `q` query, `t` transmit, `T` transmit+display, `p` put by `i`/`I`,
`d` delete (`a/A`, `i/I`, `n/N`, `c`, `p`, `z`). Frames, animation and unicode
placeholders (`U=1`) are ignored. Deviation from kitty: re-transmitting an
existing image id does not remove what the old image already shows; the old
image just loses its id and is freed once nothing shows it, so tools that use
a fixed id on every run keep their earlier pictures on screen.

Placements on the main screen are anchored to an absolute line
(`scroll_base + scrollback length`) so they move with the text, reappear when
scrolling up and are forgotten once past the 5000-line scrollback; on the
alternate screen they are anchored to rows and dropped when it is left.
`ESC[2J` / `ESC[3J` delete the placements on the live screen. After a display
the cursor moves to the cell after the image's bottom-right (scrolling if it
runs past the bottom) unless `C=1`. Image sizes without `c`/`r` come from the
cell size Lua reports through `cbo_term_set_cell_px` (8x16), which is also the
pty's pixel winsize and the answer to `CSI 14 t` / `CSI 16 t`.

Lua polls `cbo_term_placements` whenever the generation changes, fetches new
payloads with `cbo_term_image_info` / `cbo_term_image_data` (keyed by
`image_key`, cached per view for 60 s after last use), decodes them (PNG via
`love.image`, zlib via `love.data.decompress`, raw through an ImageData
pointer) and paints them into the terminal canvas: z < 0 between the cell
backgrounds and the glyphs, z >= 0 over the glyphs, so the CRT shader applies.
Per session the core keeps at most 128 MB of image data (oldest unplaced
images evicted first) and refuses images over 64 MB.


## Terminal files and cwd (2026-09-09)

Bash, zsh and fish get temporary per-session OSC 7 integration when their SSH
shell starts; user startup files are not modified. Directory restoration waits
for a cwd report and quiet prompt, cancels if the user types, and does not save
the old login directory while the restoration command is queued.

The terminal toolbar exposes Upload and Download. Upload opens `scenes/pick.lua`,
a LÖVE-drawn local file picker fed by the core's async `local` listing job; no
system dialog is used (an `osascript` chooser from a worker thread stalled the
app). Local file drops and the picker infer the remote destination from the
current cwd and basename.
Cmd/Ctrl-click or right-click on a filename in rendered output infers a download;
selection handles unquoted spaces. Quoted/escaped names and compiler line suffixes
are parsed as literal paths, never evaluated. A compact transfer sheet defaults
downloads to Downloads and shows progress/cancel while keeping the terminal visible.
Ctrl+Shift+F opens the optional two-pane browser. Rust performs bounded async jobs
on a separate authenticated SFTP connection, preserves existing destinations, and
attempts to remove incomplete files on error/cancel. Regular files only for now.

The terminal includes a persistent current-folder row below its toolbar. It
updates from the live shell report and copies the full path when clicked.
DOWNLOAD (or Ctrl+Shift+D) now arms a one-shot picking mode: the next plain click
on a filename starts the transfer. Active button styling, hover underline/hand
cursor, and a filename/status hint identify the target. Blank clicks keep the
mode active; Esc or another DOWNLOAD click cancels without sending shell input.

## Lobby layouts and text containment (2026-09-09)

The lobby is Map 1 (world map) or Map 2 (searchable session grid), selected by
the shared header controls and persisted as `lobbyView`. Map 2 is the default.
Boot, terminal return shortcuts, and disconnect all resolve to the current
lobby. There is no third lobby destination. Map 2 wraps filter controls with
the window; Escape clears its search and filters.

Text fields reserve cursor space and preserve the parent's clipping rectangle.
Single-line labels truncate at Unicode boundaries with an ellipsis; Help wraps
its columns and scrolls. Dialogs size their content to their actual frame.

## Notes, AI context and AUTO NOTE (2026-09-10)

* **Notes** live in sqlite (`notes` + `notes_fts`, schema v4) regardless of the
  recording opt-in: they are deliberate input. ABI: `cbo_note_add`,
  `cbo_note_delete`, `cbo_note_list`; search through `cbo_search*` with kind
  `note`. Deleting a note removes its FTS row and vector.
* **Vectors per model.** `embeddings.model` decides which rows a search sees.
  With "OpenAI indexing" on and a key, `text-embedding-3-small` (background
  worker). Otherwise `local-ngram-v1`: signed feature hashing of words, word
  bigrams and character trigrams into 512 dims, L2-normalised, computed in
  process. It finds near spellings, inflections and shared fragments, not
  paraphrases. A provider switch leaves the other model's rows pending, so the
  worker re-embeds. Offline notes get their local vector on insert.
* **Hybrid always.** `cbo_search` fuses BM25 and the vector pass with RRF in
  every configuration; a failing remote pass degrades to BM25.
* **AI panel** (`scenes/ai.lua`): chat and notes modes (Shift+Tab). Chat
  bubbles carry COPY and X (drop from context), CLEAR ALL empties it. Note
  bubbles carry READ (full-screen `scenes/note.lua`: COPY, TERM, DEL), COPY and
  X (delete). PASTE saves the clipboard as a note. FIND: BM25 as you type,
  Enter runs the hybrid pass. Esc leaves FIND before it closes the panel.
* **Notes feed the chat.** `AI:send` runs the question through the note search
  (hybrid, 5 hits, 600 chars each) and appends the hits to the system prompt;
  the user bubble shows "+N notes".
* **AUTO NOTE** (terminal bar, hidden below 520 virtual px like RENAME):
  `Term:screenText` (visible rows, trailing blanks dropped) → `AI:autoNote`.
  With a key: a separate LLM request with `AI.AUTO_SYSTEM` summarises; the note
  is header + summary + `--- screen ---` + capture (clipped to 1500 chars).
  Without a key, on error or on Esc: header + capture. The chat request and the
  auto-note request are independent.
* **Mock core** keeps notes in memory with a term-overlap search so the UI and
  the in-engine suite work without the dylib.
* **HOT NOTE** (terminal bar): `Term:toggleHotNotePick` arms picking, a
  filename click resolves the path against the shell folder and pushes
  `scenes/hotnote.lua`, which downloads the file (file job, `op: download`)
  into `<save dir>/hotnotes/<time>-<name>`, edits it (`HotNote.Editor`, a
  pure line/cursor model) and on Esc / DONE / Ctrl+S uploads with
  `overwrite: true`. The core writes the upload to `.<name>.cbo-hot`, renames
  the original to `.<name>.cbo-bak`, renames the temp into place and removes
  the backup (SFTP v3 has no overwriting rename); the original is restored if
  the swap fails. Unchanged files are not uploaded. Refused: > 512 KB, NUL
  bytes, invalid UTF-8.
* **NEW NOTE**: `Term:newNote` needs a known shell folder and pushes the
  same overlay with `create = true`; the overlay starts an empty dirty
  editor on `<cwd>/<fruit><n>.txt` (`HotNote.randomName`, n from 0) and
  uploads without `overwrite`; a taken name steps n and retries up to
  twenty times, so an existing file is never replaced. The note buttons have
  no width threshold: the tab strip wraps rows instead.

## AI tools, the AGI page and MCP (2026-09-11)

* **Function calling.** `cbo_llm_start_tools` takes a neutral tool list
  `[{name, description, parameters}]` and a message log that may carry
  assistant `tool_calls` and `{"role":"tool", tool_call_id, content}` results.
  Rust converts both to the provider's shape (OpenAI/xAI `tools` +
  `tool_calls`; Anthropic `input_schema`, `tool_use` and `tool_result` blocks,
  with consecutive results merged into one user message) and assembles the
  streamed fragments; `cbo_llm_take_calls` returns `[{id, name, arguments}]`
  once the stream is DONE. The core never executes anything.
* **Registry** (`love2d/src/tools.lua`). Eight built-ins: `read_screen`,
  `run_command`, `write_file`, `search_notes`, `save_note`, `define_tool`, `remove_tool`,
  `list_tools`. A user tool is a shell template with `{param}` placeholders,
  expanded with single-quote shell quoting. Rows live in
  `<data dir>/tools.jsonl`. Every change is saved at once and each request is
  built from the live registry, so `define_tool` (the model) and the AGI page
  (the user) both take effect without a relaunch; a `tools.jsonl` edited by
  hand is re-read the next time the AGI page opens.
* **Approval.** `run_command` and every user tool type into the terminal
  through the scene's own write, then wait for an explicit per-job completion
  marker from the shell. The command runs with `eval` to retain shell state;
  split `printf` markers avoid matching the command's echo and separate
  fresh output from older terminal text. Silence never
  completes a command, and after 30 seconds the panel says it is still running.
  STOP cancels the loop and sends Ctrl+C to that job's original session. The panel
  shows ALLOW / SKIP (Ctrl+Y approves) for unrestricted shell access, including
  when `cfg.aiAutoRun` is on. The loop runs
  at most `AI.MAX_TOOL_ROUNDS` rounds per question.
* **AGI page** (`scenes/agi.lua`), from the panel header, the context menu or
  Ctrl+G (labelled SETUP in the assistant). TOOLS lists the harness with ADD / EDIT / DEL / ON-OFF and the
  AUTO RUN and TOOLS switches. KEYS sets, changes and removes an API key per
  provider (masked; an environment key is labelled and cannot be "removed")
  and its model. PLAYGROUND sends a prompt, PING or a TOOLS TEST and reports
  provider, latency, the stream and any function call. MCP starts/stops the
  server and shows the URL and the `claude mcp add` line.
* **API keys** are written to `<data dir>/apikeys.jsonl` (one
  `{provider, key}` per line, mode 0600) as well as SQLite, and that file
  wins on load, so a key can be edited or deleted with a text editor.
* **MCP server** (`rust/src/mcp.rs`): JSON-RPC 2.0 over
  `POST http://127.0.0.1:<port>/mcp/<token>`, loopback only, token generated
  with 256 bits of OS randomness into kv `mcp.token`. Legacy 16-character tokens
  are replaced on startup, so existing clients must copy the new connection URL.
  Entropy failure prevents startup. Host must match the loopback endpoint; a
  supplied Origin must match its HTTP origin (native clients may omit Origin).
  Requests have a 16 KiB total header limit, at most 64 headers, a 4 MiB body
  limit, and a 15-second absolute read deadline. Authentication occurs before
  body allocation. At most 16 connections run concurrently; STOP interrupts
  pending readers. Privacy mode masks tokens in both displayed connection
  strings, while explicit copy actions retain the actual credential. QA logs
  redact tokens regardless of Privacy mode.
  `office_screen`, `office_cwd`, `office_sessions`,
  `office_notes_search` and `office_note_add` are answered in Rust;
  `office_send`, `office_practice` and `office_type` queue an inbox item that
  `love.update` drains and delivers to the terminal's assist page. Terminal
  input from a client always goes through the review sheet. The point is
  cost: Claude Code already runs on the user's plan, so it can read the
  screen and answer in the page without spending the office's own API credit.
* **Coding practice.** A fenced code block in an answer gets COPY, RUN
  (review sheet) and PRACTICE. Practice uses a local input field: Enter checks
  the line and never writes to SSH. Targets wrap without losing spaces or
  Unicode; long targets scroll under the pointer and READ opens the full code.
  The matched prefix is green and a mismatch shows a correction hint. Completion
  returns to the preserved chat draft; RUN remains an optional reviewed action.
  Esc/STOP exits practice. Clicking the composer or terminal selects keyboard
  focus; Ctrl+Shift+Space and the TERM/CHAT button switch it too.
* **Simple assistant UI.** NOTES, SETUP and terminal/chat focus stay in the
  header, with CLEAR when there is history. The composer wraps up to four rows
  at the terminal font size, shows a placeholder, and changes SEND to STOP while
  working. EXPLAIN/FIX start common tasks. SETUP groups tools, keys, playground
  and MCP. Provider headings say API; MCP explains that questions are asked in
  the external client and chat SEND continues to use the selected API.
* **Turn lifecycle.** Every request rebuilds the enabled tools. Cancellation
  drops the stream immediately so late calls cannot run; tool cancellation
  records results for the conversation. MCP items wait for an active tool turn
  to finish so they cannot split call/result pairs. A new question may run at
  most six tool rounds, then receives a final request without tools.
* **Assist body text** is drawn in screen space at the terminal's glyph size
  (`cfg.aiTermFont`, default on), so chat, code and practice lines match the
  grid exactly instead of being a fractionally resampled 16 px face.


## Coding agent through the terminal (2026-09-11)

Open AI Assist, select a provider, and ask for a program (for example, "write
rust code for helloworld"). The agent inspects the folder and compiler, writes
source with `write_file`, compiles/runs with `run_command`, and uses diagnostics
to repair failures. Code requests are actions; explanation-only requests remain
text. CODE enables automatic in-workspace file writes. RUN approves an ordinary
file write; ALLOW approves one operation with access beyond the workspace.

`write_file(path, content, overwrite=false)` sends source bytes through the
connected terminal as bounded encoded chunks. Confined writes use a fixed
`python3 -I` helper that opens descendant directories by descriptor with
`O_NOFOLLOW`; symlink directories cannot redirect writes outside the workspace.
Python/dir-fd support is required and failures never fall back to an unrestricted
write. An explicitly approved outside write uses the shell transport. Parent directories
are created, temporary files are private, and the destination is published only
after all chunks succeed. Existing files are protected by default; overwrite
must be explicitly requested by the tool call. The approval bubble shows the
path and source, not the encoded transport. Maximum source size is 64 KiB.
Cancellation or a failed write may leave the named temporary file for inspection.

The workspace is the shell folder at SEND time, fixed through the tool loop.
Lexical traversal and sibling prefixes cannot gain automatic outside access.
Outside file writes and every arbitrary shell/custom command require per-operation
approval, even with CODE or AUTO RUN enabled. A shell command or generated program
has unrestricted SSH-user access; the application does not pretend that `cd` or
prompt instructions sandbox it. Access approval is limited to that operation and
does not expand the workspace. Trusted runtime files needed by the fixed writer
are not agent-directed workspace reads.

The main action is ALLOW/RUN while waiting, STOP while executing, and SEND when
idle. A pinned activity line reports planning, tool summaries, file-write steps,
result processing, and completion; the workspace is shown below it. New tool
steps scroll into view, while manual scrolling lets users read earlier output.

Command completion markers now include success/failure, so a compile error is
returned as a failed tool result. Source text is never mistaken for shell input.
`make test-codeagent` is an opt-in live Grok + localhost SSH test: it sends the
exact example prompt with no canned source/tool calls, verifies source on disk
and successful compiler/program output, and saves `codeagent_report.json` and
screenshots in the LÖVE QA save directory. It uses a fresh project folder and
requires deliberate approvals. `--shots=codeagentgo` tests the Go producer/consumer
request using the same harness.
