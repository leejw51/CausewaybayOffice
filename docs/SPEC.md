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

The terminal toolbar exposes Upload and Download. Local file drops and the Mac
file chooser infer the remote destination from the current cwd and basename.
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
