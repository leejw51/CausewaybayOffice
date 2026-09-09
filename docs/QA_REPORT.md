> The historical open items below are superseded by [the 2026-09-09 repair review](REPAIR_REPORT.md).

# QA REPORT — phase 1 (core only) — CAUSEWAYBAY OFFICE v0.1.0

Date: 2026-09-09. macOS 26.6.2 (Darwin 25.6.0), rustc/cargo 1.97.1, base commit
`f4b57ae`. Local sshd on port 22, key auth (`~/.ssh/id_ed25519`), no ssh agent.
Providers tested: xai (grok-4.6), openai (gpt-5); anthropic only via the bad-key
path (no ANTHROPIC_API_KEY in the environment).

Scope: the Rust core through the C ABI (`rust/`). `love2d/` was not touched or
run (the Lua coder was mid-change); the LÖVE in-engine suite is phase 2.

All checks below are reproducible with

```
cd rust && cargo run --release --example qa_core -- <check> [...]
# checks: unicode fullscreen resize keepalive limits blackhole errors names search
#         llm llm-cancel llm-badkey leak idle5m all   (all = everything except idle5m)
```

## Results

| # | check | command | result | notes |
|---|---|---|---|---|
| 1a | unit tests | `cargo test --release` | PASS | 28 passed (27 before, +1 search regression test) |
| 1b | clippy | `cargo clippy --release --all-targets -- -D warnings` | PASS (after fix) | **was FAIL**: 10x `missing_safety_doc` on the `unsafe extern "C"` fns in `lib.rs` + 1x `cloned_ref_to_slice_refs` in `names.rs` tests. `make lint` was red. Fixed (docs only). |
| 1c | rustfmt | `cargo fmt --check` | PASS | |
| 1d | existing smoke | `cargo run --release --example smoke` | PASS | localhost connect, CJK widths, keepalive, exit -> CLOSED |
| 2a | unicode widths | `qa_core unicode` | PASS | `echo 你好世界 안녕하세요 こんにちは Příliš žluťoučký kůň úpěl ďábelské ódy`: 14 wide glyphs each `width 2` + `width 0` continuation (cp 0), 41 narrow `width 1`; every code point round-trips exactly; every glyph's column == `cbo_utf8_width(prefix)`; line = 69 cols; `你好世界`=8, Czech pangram=38; Ř ž ť ů ň ú ě ď á ó č é all width 1 |
| 2b | combining mark | `printf 'a\xcc\x81b'` | PASS (note) | 2 cells, not 3. The cell reports `cp='a'` only: the U+0301 is folded for width but not delivered (`CboCell` has a single `cp`). Per spec; renderer will draw `a` without the accent. |
| 2c | colours / attrs | `printf '\e[1;32m...'` | PASS | bold green -> `0x7CF29A` + `ATTR_BOLD`; inverse -> fg/bg swapped (`0x0A0A1E`/`0xE8E8D0`) + `ATTR_INVERSE`; `38;5;208` -> `0xFF8700`; `38;2;255;0;128` -> `0xFF0080`; attrs reset after `\e[0m` |
| 3a | vim | `qa_core fullscreen` | PASS | alt screen hides the shell, insert mode text + `INSERT` visible, `:q!` restores the main screen (no leak of alt content), generation 4 -> 13 |
| 3b | top | `top -l 2 -n 5`, `top -s 1 -n 5` + `q` | PASS | logging mode prints; interactive (curses) draws, `q` restores the main screen with the previous output |
| 3c | ls colours | `ls --color=always -la ~`, `CLICOLOR_FORCE=1 ls -G` | PASS | 29 / 58 coloured cells, no garbage, state stays CONNECTED, no panic recorded |
| 3d | resize | `qa_core resize` | PASS | 120x40, 60x20, 200x50, 40x10: `cbo_session_info` reflects it and `tput cols; tput lines` report the new size each time; 10 rapid resizes then 100x30 -> shell reports 100/30 |
| 4a | keepalive 2 s | `qa_core keepalive` | PASS | idle 10 s: 4 pings, gaps 2002/2009/2000 ms, state CONNECTED; interval 0: `last_ping_ms` frozen for 5 s; interval 1: resumes |
| 4b | keepalive 15 s, idle 5m30s | `qa_core idle5m` | PASS | 22 pings in 330 s, every gap 15001–15008 ms; `echo` after the idle answers immediately; state CONNECTED |
| 5a | 128 limit, localhost | `qa_core limits` | PASS (env note) | open #129 -> -1, `cbo_last_error` = `session limit reached (128)`; `cbo_session_count`=128; `cbo_session_ids` = 0..127 distinct; 128 distinct auto names; close+free all -> count 0; next open gets id 0. **Environment cap**: the launchd sshd resets connections above ~42 concurrent (plain `ssh` in a loop: 5/5, 20/20, 42/45 ok, `kex_exchange_identification: Connection reset by peer`); sessions 42..127 went ERROR `ssh handshake: Failed getting banner`. They still hold their slot, so the cap is exercised. |
| 5b | 128 limit, black hole | `qa_core blackhole` (10.255.255.1) | PASS | 128 slots all CONNECTING, #129 -> -1; free while CONNECTING refused (`close it first`); close -> CLOSED immediately; free all -> count 0, slot 0 reusable; the 128 abandoned worker threads exit at the 10 s connect timeout (threads 129 -> 1) |
| 6a | wrong port | `qa_core errors` | PASS | ERROR `connect to localhost:2 failed (127.0.0.1:2: Connection refused (os error 61))` |
| 6b | unknown host | | PASS | ERROR `cannot resolve no-such-host.invalid: ... nodename nor servname provided, or not known` |
| 6c | missing keypath | | PASS | ERROR `authentication failed for alice (key /nonexistent/id_qa: Unable to extract public key from private key file: Unable to open private key file)` |
| 6d | wrong password | | PASS (note) | user without keys: ERROR `authentication failed for cbo-no-such-user (password: Authentication failed (username/password); agent: no identities found in the ssh agent; id_ed25519: ...; id_rsa: ...)` — password auth is enabled on this sshd. For `$USER` a wrong password still ends CONNECTED because the documented fallback (agent, then `~/.ssh/id_*`) succeeds. |
| 6e | close/free during CONNECTING | | PASS | CLOSED immediately, free ok, count 0 |
| 6f | double free | | PASS | second free is a no-op, `cbo_last_error` = `session 0 not open` |
| 6g | bad ids / NULLs | ids -1, 128, 999, INT_MIN, INT_MAX on every entry point; NULL `out`, NULL strings, cap 0 | PASS | no crash, no `internal panic`, sane defaults (state IDLE/0, "" strings, -1/0 returns) |
| 6h | misc | free on CONNECTED, rename | PASS | free refused (`close it first`); `香港-辦公室` accepted; 33 chars refused (`longer than 32`), 32 ok; NULL/blank refused; invalid UTF-8 host -> -1 (message says `host is required`, could be more specific) |
| 7a | names | `qa_core names` | PASS | 500 seeded names all `<adj>-<noun>-<NN>` (500 distinct); 40 sessions opened back-to-back -> 40 distinct auto names; `cbo_name_generate(0)` avoids live names. Note: two `generate(0)` calls in the same ms return the same string (seed = clock); harmless since the core names sessions itself at open. |
| 7b | search | `qa_core search` | PASS (after fix) | `tram` -> tram-jade-11, neon-tram-07, misty-peak-02(host tramway); `neon tr` -> neon-tram-07 (**was `[]`**, see bug 2); `안녕` / `香港` -> exact card; `alice@10.255` -> user@host; `""` and `"   "` -> all 6, most recent activity first; `zzzz` -> none |
| 8a | llm streaming | `qa_core llm` | PASS (xai, openai); NOT RUN (anthropic, no key) | xai: STREAMING observed, 8 deltas, DONE in 21.8 s; openai: 13 deltas, DONE in 22.2 s. Replies contain `안녕하세요` and `Příliš žluťoučký kůň úpěl ďábelské ódy` byte-exact. First text delta only after ~21 s on both: the default models reason first and the `reasoning_content` deltas are (correctly) ignored. |
| 8b | llm cancel | `qa_core llm-cancel` | PASS | xai and openai: cancelled after 3 deltas; 0 deltas in the 3 s after cancel; state settles to DONE; freed id reads as ERROR |
| 8c | llm bad key | `qa_core llm-badkey` | PASS | xai: ERROR `HTTP 400: {"code":"invalid-argument","error":"Incorrect API key provided..."}` (xai uses 400, not 401); openai: `HTTP 401: {... "code": "invalid_api_key" ...}`; anthropic: `HTTP 401: {"type":"error","error":{"type":"authentication_error","message":"API key is invalid."}}` — request shape reaches the API |
| 9 | thread / memory | `qa_core leak` | PASS | 50 x open/connect/close/free sequentially: 195 ms each, id 0 reused every time, threads 1 -> 1, RSS 27840 -> 28016 KB (+176 KB) |
| 10 | LuaJIT FFI ABI | `/opt/homebrew/bin/luajit rust/examples/ffi_smoke.lua` | PASS | dylib loads, `sizeof(CboCell)=16`, `sizeof(CboSessionInfo)=304`, width 27, bad-arg paths |
| 11 | full run | `qa_core all` | PASS | every check above (minus idle5m) in one process, sequentially |

## Bugs found and fixed (rust/)

1. **`make lint` / clippy red** — `rust/src/lib.rs`: the 10 `pub unsafe extern "C"`
   functions had no `# Safety` doc section (`clippy::missing_safety_doc`), and a
   test in `names.rs` tripped `cloned_ref_to_slice_refs`. Fixed with doc comments
   and `std::slice::from_ref`; no behaviour change, `cbo.h` untouched.
2. **Fuzzy search treated a space as a literal character** — `rust/src/search.rs`:
   `cbo_session_search("neon tr")` returned nothing because `score()` needed the
   `' '` to be a subsequence of the name. Now the query is split on whitespace,
   every term must match some field and the per-term best scores add up.
   In the same change the name bonus went from 5 to 15 so that a word-start hit
   on a *name* (`neon-tram-07` for `tram`) outranks a prefix hit on a *host*
   (`tramway.hk`); the spec calls the name the primary field. Regression test
   `search::tests::name_hits_outrank_host_hits_and_terms_split_on_space`.

## Observations (no change made)

* Localhost cannot host 128 concurrent SSH sessions on this machine: the
  launchd sshd resets connections above ~42. The cap is verified with the
  black-hole host instead. Not a core issue.
* Reasoning models (gpt-5, grok-4.6) send 20 s of `reasoning_content` before
  the first `content` delta. The core ignores those, so the UI sees
  STREAMING with no text for that long; the AI panel should show a "thinking"
  state while `cbo_llm_state == STREAMING` and no delta has arrived yet.
* A combining mark is folded into the base cell's width but the cell can only
  carry one `cp`, so the mark itself is not rendered. Acceptable for the MVP;
  a `CboCell` change would be needed to draw it.
* `cbo_session_open` with a non-UTF-8 host reports `host is required`; a
  distinct "not UTF-8" message would be friendlier.
* A wrong password does not fail the connect when a working key is in
  `~/.ssh` (documented fallback order). If the UI wants "password means
  password only", the core would need a flag; not in the header today.
* `cbo_name_generate(0)` is clock-seeded at ms resolution: two calls in the
  same ms return the same name. The core names sessions itself at open (with
  the taken-list), so this only matters if Lua pre-generates names.

## Not run

* Anthropic live streaming (no `ANTHROPIC_API_KEY`); the bad-key path did
  reach the API and returned its 401 body.
* Everything under `love2d/` (phase 2): in-engine suite, `make cdef` diff,
  lobby with 128 cards, window resize, settings/AI panel.

---

# QA REPORT — phase 2 (LÖVE UI) — CAUSEWAYBAY OFFICE v0.1.0

Date: 2026-09-09. Same machine as phase 1 (macOS 26.6.2, portrait 1080x1920
display, so windows clamp to 1080 px wide), LÖVE 11.5, real core
`rust/target/release/libcbo_core.dylib` (mock only where stated), sshd on
localhost with key auth, provider openai / gpt-5 (XAI_API_KEY also present).

Everything below is reproducible without a human at the keyboard:

```
make test-love                                  # in-engine suite, 164 checks (was 121)
love love2d --shots=qa                          # checklist walkthrough on localhost, 54 checks, qa_*.png
love love2d --shots=verify                      # second launch: the key saved by `qa` survived
love love2d --shots=limit                       # 128 sessions against 10.255.255.1 + lobby fps
love love2d --shots=perf                        # 3 sessions scrolling `yes`, fps sampled
love love2d --mock --shots=mock                 # MOCK CORE badge, connect without a core
love love2d --shots=art                         # README screenshots
```

Each phase prints `[qa] PASS|FAIL|INFO …`, writes `qa_<phase>.log` and the
screenshots into `~/Library/Application Support/LOVE/causewaybayoffice/`,
and exits 1 on any failure. `qa` also makes the shell write evidence files
under `/tmp/cbo_qa/` (`tput*.txt`, `ime.txt`, `paste.txt`, `qa.txt`,
`pid[123].txt`, `insert.txt`) so the terminal side can be checked with
`cat`/`xxd` afterwards. Screenshots are taken with
`love.graphics.captureScreenshot`; the scripted runs turn vsync off because
a window that never becomes frontmost gets no frames from macOS otherwise
(that stall is what made the first attempts hang at frame 1).

## Results

| # | check | how | result | notes |
|---|---|---|---|---|
| 1.3 | boot -> lobby | `qa`: scene names at 1.3 s / 3.9 s, `qa_boot.png`, `qa_lobby_empty.png` | PASS | CRT power-on line, key art, title drops in, lobby with empty shelf; no Lua error |
| 1.4 | in-engine suite | `make test-love` | PASS | 164 checks (43 new: unicode matrix, native grid, AI reflow/thinking/insert, zoom chords) |
| 1.5 | lint | `make lint-lua`, `luajit -bl` GSET scan, `stylua --check love2d` | PASS | every Lua file compiles, **no global assignments anywhere**, formatting clean |
| 1.6 | mock mode | `--mock --shots=mock`, `qa_mock_lobby.png` / `qa_mock_terminal.png` | PASS | `MOCK CORE` badge top-right, connect + terminal work against the mock; badge absent with the real core (checked in `qa`) |
| 1.7 | F1 help | `qa_help.png`, Esc closes | PASS | lists every SPEC key incl. the new Ctrl+= / Ctrl+- and Shift+PgUp rows |
| 1.8 / 4.23 | F11 fullscreen and back | `qa`: `App.keypressed("f11")` twice with vim open | PASS (env note) | grid == core grid both ways, `vim` redraws, `D.fullscreen` flips; **macOS did not actually switch a background (non-frontmost) window to fullscreen in the scripted run** (`love.window.getFullscreen()` stayed false, size stayed 1080x800), so the pixel-scale-after-fullscreen check is only covered by the resize tests below |
| 2.1 | connect dialog, typed `localhost`, Enter | `qa`: `App.push("connect")` + textinput, `qa_connect.png`, `qa_lobby_one.png` | PASS | CONNECTED within 2.5 s, card slid in, spark burst on connect |
| **grid** | terminal density (lead bug 1) | `qa`: scene grid, `cbo_session_info`, `tput cols; tput lines > /tmp/cbo_qa/tput1.txt` | **PASS (was FAIL: 36x20 / 62x20)** | **125x40 at 1080x800 with the bezel on**, status bar `125x40 1x`, `tput` says `125x40`; 133x45 bezel off; 125x58 at 1080x1080 (1920x1080 requested, display clamps); 95x26 at 800x500; unit test: 1920x1080 -> 225x53, 1280x800 -> 156x45 |
| **zoom** | terminal zoom 1x/2x | `qa`: Ctrl+= then Ctrl+-, Settings row, `qa_zoom2.png`, `/tmp/cbo_qa/tput_zoom2.txt` | PASS | 2x -> 62x20 and the shell agrees (`zoom 2x: 62x20`), back to 125x40; persisted as `termZoom` in config.json; glyphs stay crisp (integer screen positions, nearest filter) |
| 2.2 | `ls -la` | `qa_terminal_ls.png` | PASS | listing renders at 125 cols, no garbage bytes, Korean month names from the locale render |
| 2.3 | `top -s 1`, `q` | `qa_top.png` | PASS | full-screen refresh, header pinned, prompt back after `q` |
| 2.4 | vim, `i`, text, one Esc, `:wq` | `qa_vim_insert.png`, `cat /tmp/cbo_qa/qa.txt` | PASS | `-- INSERT --` shown, single Esc stays in the terminal (raw ESC to vim), file contains `hello office` |
| Esc Esc | double-tap chord | `qa`: two `escape` within one frame | PASS (note) | goes to the lobby. Note: the first ESC already reached zsh as a meta prefix, so the next typed letter is eaten by ZLE once (`echo` -> `cho`) — inherent to "Esc = raw ESC"; the script clears it with `space, ^U` |
| 2.5 | bell | `printf '\a'`, `Term.bells` delta, shake/flash | PASS | exactly 1 bell counted, shake + white flash |
| 2.6 | OSC title | `printf '\e]0;QA TITLE\a'`, `cbo_term_title` | PASS | `QA TITLE` |
| 2.7 | scrollback | `seq 1 500`, wheel x2, Shift+PgUp, `qa_scrollback.png` | PASS (after fix) | wheel -> offset 24, Shift+PgUp -> 64, `^ 64/…` badge; **Shift+PgUp/PgDn scrollback was missing** (went to the shell as `\e[5~`), added |
| 2.8 | 16 colours | `tput setaf 0..15` in `qa_terminal_unicode.png` | PASS | C00..C15 in the retro palette, all distinct (C00 is black on the terminal bg, as ANSI black should be) |
| 2.9 | Ctrl+C | `\x03` through `Term:write` (keys test `ctrl+c` -> `\x03`, `perf` sends it after the flood) | PASS | reaches the shell, the app keeps running |
| 3.1–3.7 | unicode widths (real core) | `qa`: one `echo` per string, `docs/screenshots/unicode.png` (= `qa_terminal_unicode.png`) | PASS | 你好世界 / 香港銅鑼灣 / 안녕하세요 / 세션 이름 / こんにちは / 東京タワー / ｶﾀﾅ (halfwidth, 1 cell each) / Příliš žluťoučký kůň úpěl ďábelské ódy / the mixed line: every glyph visible, wide glyphs exactly 2 cells, no tofu, no overlap, cursor lands after the last glyph. Right-edge wrap: `printf "%0$((cols-1))d" 0; echo 香港銅鑼灣 …` leaves column 124 blank and puts 香 whole on the next row |
| unicode (headless) | matrix in `src/test.lua` | `make test-love` | PASS | (a) Unifont advance 16 px for all 26 wide glyphs, 8 px for every Czech letter and ｶﾀｶﾅ; (b) term_view paints each string: ink in both halves of every wide glyph, background column right after every glyph, canvas exactly cells*8 wide, glyph != .notdef box; (c) `App.textinput` -> `Core.write` bytes equal the UTF-8 hex literals for all 8 strings, both as one IME string and key-by-key; (d) rename to 세션 이름 + search `세션`, and 香港銅鑼灣 + `銅鑼`; (e) config.json and hosts.json round-trip all 8 strings byte-exact |
| IME | CJK text input path | `qa`: `cat > /tmp/cbo_qa/ime.txt`, `App.textinput("你好")`, `("안녕")`, Enter, ^D, then `xxd` | PASS | `e4bda0 e5a5bd ec9588 eb8595 0a` on screen and in the file (`qa_terminal_ime_xxd.png`) |
| paste | Cmd+V | clipboard set, `keypressed("v", gui)` | PASS | `/tmp/cbo_qa/paste.txt` = `PASTED_OK` |
| 3.9 | Korean rename + search | Ctrl+R -> `빌드-상자 香港`, Ctrl+K `상자`, `qa_search_korean.png`, `qa_lobby_three.png` | PASS | name accepted by the core, tab strip / card / search row render it in Unifont, search lists it first |
| 4.1–4.2 | three sessions | `qa`: Ctrl+N x3 typed, `echo $$ > pid[123].txt` | PASS | 3 cards, distinct `adj-noun-NN` names (`neon-aberdeen-03`, `shiny-har-gow-63`, …), three different PIDs |
| 4.3–4.4 | Ctrl+Tab / Ctrl+Shift+Tab | `qa_cycle_1.png` | PASS | 3 -> 1 -> 2 -> 3 with the slide, then back to 2 |
| 4.5–4.6 | fuzzy search | Ctrl+K `neo ab` (3 letters + space + 2 letters of card 1), then `local` | PASS | multi-word query ranks session 1 first (`qa_search_multiword.png`); host query lists all 3 |
| 4.8 | 40-char rename | typed 40 x `x` | PASS | field truncates at 32 (`32/32` counter), no crash |
| 4.9 | Delete close + free | lobby, Delete on card 3, Ctrl+N again | PASS (after fix) | card pops out (`qa_lobby_closing.png`), count 3 -> 2 in both the list and `cbo_session_count`, the new session gets the freed id back and **slides in** (`qa_lobby_reused.png`) — **was a bug**: `Lobby.anim` kept the popped card's `{scale=0, alpha=0}` under the reused id so the new card was invisible |
| 4.10 | persistence | hosts.json after `qa`; `verify` phase after relaunch | PASS | localhost remembered; see 5.1 |
| 4.11–4.12 | keepalive | status bar countdown `15s keepalive` -> `5s …`, `last_ping_ms` advances, `qa_status_keepalive.png` | PASS | countdown visible in the status bar and `hb Ns` on the card (card text no longer collides with `ONLINE` — fixed) |
| 4.16–4.18 | 128 limit in the UI | `limit`: 128 x `Sessions.open` to 10.255.255.1, 129th through the connect dialog | PASS | 128 opens in 7 ms, all CONNECTING; dialog shows `! session limit reached (128)` in alarm red with a shake (`qa_limit_dialog.png`); count stays 128; close+free all -> 0; next open gets id 0 |
| 4.19 | lobby with 128 cards | `limit`: `qa_limit_lobby*.png`, fps | PASS | 249 fps scrolled to the last card (364 unscrolled, vsync off) |
| 4.20–4.22, 4.24 | window resize reflow | `qa`: `love.window.setMode` 1280x800 / 1920x1080 / 800x500 / 10 fast resizes, `tput` files | PASS (after fix) | every size: scene grid == `cbo_session_info` == `tput` (`tput_1280.txt`, `tput_final.txt` = 125x40); **fixed**: `D.sync()` resized the display but never re-laid-out the scene, so programmatic/OS size changes left the session at the old grid |
| **AI reflow** | Ctrl+Space (lead bug 2) | `qa`: resize counter during / after the 0.32 s slide, `tput_ai.txt` | **PASS (was FAIL)** | no `cbo_session_resize` while the panel slides, exactly one at the end: 125 -> **80x40** (the panel yields width so 80 columns survive), shell says `80x40`; Esc closes and restores 125x40 |
| **AI thinking** | reasoning model, no delta for ~20 s (lead bug 3) | `qa_ai_thinking.png` at 1.5 s | **PASS (was FAIL)** | bubble `thinking..  1s (Esc cancels)` with animated dots, elapsed seconds, mascot hopping; Esc -> `Core.llmCancel`; hint row switches to `Esc cancel` |
| 5.2 | streamed answer | gpt-5, 538 chars, `qa_ai_answer.png` | PASS | STREAMING -> DONE, terminal keeps rendering underneath |
| AI scroll | long answer | wheel over the panel, PgDn x3, `qa_ai_scrolled.png` | PASS (after fix) | scroll target now clamped to the content every frame and sticks to the bottom while streaming; Ctrl+Home/End added |
| AI insert | Ctrl+Enter | answer with 4 fenced blocks -> `cat > insert.txt` | PASS (after fix) | **only the code-block bodies** (233 of 538 chars) reach the shell: `lsof -nP -iTCP -sTCP:LISTEN`, `netstat -anv -p tcp | grep LISTEN`, … (`qa_ai_inserted.png`); plain answers go whole |
| 5.1 | settings key | Ctrl+, edit `openai key`, type a fake key, Enter; `verify` phase after relaunch | PASS | masked `sk-********7890` in the row and while editing (`qa_settings*.png`), stored in config.json, survives a restart, cleared again afterwards; env keys show `from XAI_API_KEY` |
| perf (UI) | 3 sessions scrolling `yes` | `perf` stage A: `yes | head -c 5000000` in all 3 at once, fps sampled every 250 ms, `qa_perf_yes.png`; stage B: 200 x 5 MB per session for 4 s | PASS (UI) | **fps min 137 / avg 300 (vsync off) during the burst, 187 canvas redraws in 2 s**, F1 opened instantly while scrolling; UI side meets the > 50 fps bar without further profiling (generation-gated redraw + run-batched `love.graphics.print`) |
| **perf (core)** | sessions survive the flood | same run: session state after stage A / B | **FAIL — open, rust/** | **2 of 3 sessions (stage A) and 3 of 3 (stage B) end in `ERROR connection lost: transport read`** while plain `ssh localhost 'yes | head -c 200000000' | wc -c` returns all 200 MB. The core's read loop (`rust/src/ssh.rs`) drops the channel under sustained output; reproducible with a single `yes | head -c 5000000`. Not fixed here (rust/ belongs to the core coder); the UI shows the error in the status bar and on the card |
| quality | per-frame allocations / globals / errors | review + `luajit -bl` | PASS (after fix) | term_view: glyph-run buffer reused, row closure hoisted, no table per frame; `fx.drawCRT` no longer builds a table per call; terminal scene reuses its CRT option tables; overlays composite through one persistent canvas; no globals; every Core call that can fail (`open`, `info`, `llmStart`) is checked |

## Open (not fixed in this phase)

* **Core drops the SSH transport under sustained output** (`connection lost:
  transport read`): 3 sessions each running `yes | head -c 5000000` lose 2 of
  3 connections within ~1 s, the 1 GB loop loses all 3. sshd is fine (plain
  `ssh` streams 200 MB). Needs a fix in `rust/src/ssh.rs` (read loop / channel
  window handling); `love love2d --shots=perf` reproduces it and will go green
  once the core holds.
* F11 could not be exercised on this machine from a scripted (background)
  window; the grid/core agreement after a fullscreen toggle is covered by the
  resize path only.

## Bugs found and fixed (love2d/)

1. **Terminal grid unusable (36x20 / 62x20 at 1080x800)** — the grid was
   drawn at the UI pixel scale `D.s` (2x). `term_view` now draws in screen
   pixels at `D.termZoom` (1x by default, 2x via Ctrl+= / Ctrl+- or
   Settings > terminal zoom, saved in config.json), the scene keeps its
   chunky chrome, and `cbo_session_resize` is called exactly when the grid
   changes (resize, bezel toggle, zoom, AI panel). 125x40 at 1080x800 with
   the bezel.
2. **AI panel covered the terminal** — the session was resized at the start
   of the slide (and the panel had no minimum width guard: `setScissor` with
   a negative width crashed the app mid-slide). Now the panel slides over the
   old grid and the session is resized once at the end of the tween; the
   panel width yields so the terminal keeps 80 columns; Esc restores.
3. **No feedback for reasoning models** — 20 s of STREAMING with nothing to
   show. Added the thinking bubble (dots, elapsed seconds, hopping mascot,
   Esc cancels), scroll clamping + PgUp/PgDn/Ctrl+Home/End, and Ctrl+Enter
   inserting only fenced code blocks.
4. **`D.sync()` never re-laid-out the scene** after a size change it detected
   itself (setMode, OS-driven resizes), so the session kept the old grid.
5. **Reused session id inherited the popped card's animation** — the new
   card was invisible. `Lobby` now forgets animations of ids that are gone.
6. **Shift+PgUp / Shift+PgDn** were sent to the shell; they page the
   scrollback now (plain PgUp still goes to the shell for less/vim).
7. **Overlays popped in**: the frame faded but the rows inside were drawn at
   full alpha. Overlays are composited through a canvas with their alpha.
8. **Lobby card / status bar text collisions** — `125x40 hb 1s` ran into
   `ONLINE` on the card, and a long core error ran under `UTF-8 125x40 …` in
   the status bar; both are now clipped to the room they have.
9. **Connect / --demo opened sessions with the wrong grid** (virtual-px
   based) and relied on the first layout to fix it; they use
   `App.termGrid()` now.
10. `--shots` is now a set of scripted phases in `src/shots.lua` (art / qa /
    verify / limit / perf / mock) and the in-engine suite grew the unicode
    matrix, native-grid, AI reflow/thinking/insert and zoom tests.

## Observations (no change made)

* macOS keeps the window at the display width (1080) so 1280x800 and
  1920x1080 could only be verified in the unit tests (`Term.grid`), not on
  screen; likewise F11 was not honoured for a non-frontmost window.
* The first Esc of the double-tap reaches the shell as a raw ESC (by spec);
  zsh then treats the next key as a meta sequence once.
* The AI chat text is Unifont at the UI scale (2x), so the panel shows ~20
  characters per line at 1080 px; drawing the chat at the terminal zoom would
  double that and is a candidate for phase 3.
* Uncommitted Rust work from the core coder (`rust/src/llm.rs` test-only
  endpoint override, `rust/src/term.rs` unicode tests, `rust/tests/`, new
  `test-integration` / `test-ffi` Makefile targets) was present in the tree
  and is in the dylib these results were taken with; it was left untouched.

---

# QA REPORT — phase 3 (world map, navigation, hero anchoring, display modes) — CAUSEWAYBAY OFFICE v0.1.0

Date: 2026-09-09. Same machine as phases 1-2 (macOS 26.6.2, portrait
1080x1920 display, LÖVE 11.5, real core `rust/target/release/libcbo_core.dylib`,
sshd on localhost with key auth). Commits under test: `b72422f` (lobby hero
anchoring, terminal back navigation) and `48f6f4c` (world map, display modes).
The uncommitted Rust work present in the tree (`fuzzy.rs`, `db.rs`, `embed.rs`,
… from the core coder) was left untouched; the dylib was rebuilt from it by
`make check`.

Everything is reproducible without a human at the keyboard:

```
make check                                      # lint + cargo tests + in-engine suite, 235 checks (was 208)
love love2d --shots=hero6                       # 6 consecutive + 6 spaced lobby frames diffed
love love2d --shots=nav ; love love2d --shots=nav2         # back navigation, Esc to shell, toast, status bar widths
love love2d --shots=map3 ; love love2d --shots=map3verify  # world map matrix (~60 s), platform stability after restart
love love2d --shots=display3                    # F11 / Settings / Ctrl+O / portrait 1080x1920 / resize storm
love love2d --shots=qa|verify|limit|perf|art|portrait|map|display|hero, --mock --shots=mock   # phase 2 regression
```

The phase 3 phases live in `love2d/src/shots_p3.lua` (dispatched from
`shots.lua`); same conventions (`[qa] PASS|FAIL|INFO`, `qa_<phase>.log`,
`qa_*.png` in `~/Library/Application Support/LOVE/causewaybayoffice/`, exit 1
on any failure). Every screenshot named below was opened and read.

## Results

| # | check | how | result | notes |
|---|---|---|---|---|
| A1 | lobby hero: 6 consecutive frames | `hero6`: `captureScreenshot` from six successive `love.draw` calls, sprite-mask diff | PASS | whole hero identical across the 6 frames (0.0005 of masked px differ = the parallax behind one-frame-only pixels) |
| A2 | lobby hero: 6 spaced frames (1 s, both cycle frames) | `hero6`: frames 0.17 s apart, compared on the pixels *both* strip frames paint; hands band measured from the strip itself | PASS (after fix) | feet/chair (bottom 34%) 0.000, below-hands 0.000, **head/torso above the hands 0.000 (was 0.04-0.08 per 10% band: the AI frames drift ~1 px everywhere)**; hands band animates (0.14); exactly 2 distinct frames; drawn at integer px on all 614 draws |
| A3 | hero strip shape | unit: `hero.n == 2`, anchors within 1 px, bottom 30% identical, top 45% identical, hands animate | PASS | `lockAbove = 0.45` added next to `lockBelow = 0.66` |
| A4 | map hero strips anchored | unit: `hero_walk` (4 -> kept frames) and `hero_map_idle` (2) feet anchors coincide within 1 px, on the cell bottom | PASS | |
| A5 | map hero on a flat segment | `map3`: every update sampled on the harbourfront segment 2 -> 1 (`y == 0.189` both ends) | PASS | feet line constant, `y = feet + cosine bob` exactly, the value handed to `drawAnchored` within the bob of the platform line on 600 draws, floored to integers by `drawAnchored` |
| B1 | click `< LOBBY` | `nav`: `App.mousepressed` on the button rect | PASS | `fx.transitioning` true at once, `fade.a` 0.5 at 0.2 s, lobby at 0.8 s |
| B2 | F2 | `nav` | PASS | same fade |
| B3 | Ctrl+Esc | `nav` | PASS | same fade |
| B4 | Esc Esc (< 300 ms) | `nav`: two `escape` in one frame | PASS | same fade; the first Esc reaches zsh as a meta prefix (documented in phase 2), the script clears it |
| B5 | right-click menu > Back | `nav`: right click on the grid, `menu` overlay, Enter on item 1 | PASS | |
| B6 | single Esc = 0x1b to the shell, stays | `nav`: `cat -v > /tmp/cbo_qa/esc.txt`, Esc, `x`, Enter, ^D | PASS | file is exactly `^[x\n` (`qa_nav_status_640.png` shows `^[x` echoed); scene stays `terminal` |
| B7 | Esc with the AI panel open | `nav` | PASS | panel closes, scene stays, `esc.txt` unchanged (nothing sent to the shell) |
| B8 | first-entry toast once, never after a restart | `nav` (seenTermHint reset first, `qa_nav_toast.png`), five re-entries, `nav2` after relaunch | PASS | toast on the first entry only; `config.seenTermHint` true in config.json; no toast on any later entry or after the restart |
| B9 | status bar `F2 lobby` down to 640 px | `nav`: 1080x800 / 800x500 / 640x400, `statusRight` + `statusRightX > statusLeftEnd`; unit test at the same three sizes | PASS | `UTF-8 75x20 1x F2 lobby F1 help` at 640 (`qa_nav_status_640.png`), right block clear of `keepalive / idle / ONLINE` at every width |
| C1 | map from the lobby button and key M | `map3`: click on the `MAP` rect, then `m` | PASS | both start a fade |
| C2 | stable platform indices across restart | `map3`: hosts.json carries `platform`, `loadHosts()` reproduces them; `map3verify` after relaunch compares `/tmp/cbo_qa/platforms.txt` (11 hosts) | PASS | localhost 0, 10.255.255.1 1, nosuch.invalid 2 (first-seen order), mock-01..09 3..11; unchanged after the restart |
| C3 | paging with 9+ hosts | `map3`: 3 + 9 `mock-NN.lan` -> `pages == 2`, `]` / `[`, `< >` buttons drawn (`qa_map3_page2.png`) | PASS | the map opens on the last-used host's page (page 2); walking on another page fades the hero in on that page's first stage (`hero.page`, `alpha 0 -> 1`) |
| C4 | BFS shortest on the designer graph | `map3` + unit: all 100 pairs vs Floyd-Warshall on `assets/map_nodes.json` (10 platforms, 12 edges), 2 -> 8 uses the 1-7 branch | PASS | |
| C5 | walking: polyline, timing, easing, dust, facing | `map3`: 599 sampled updates on 3 -> 2 -> 1 | PASS | on the polyline (< 0.5 px), expoInOut progress monotonic, facing = `MG.facing(dx)` on every sample, segment 1 = 0.729 s for 192 px (formula 0.729), 9 dust puffs for a 1.19 s walk (~9.9 expected) |
| C6 | camera | `map3` (landscape: map 510x287 vs view 510x286, nothing to pan), `display3` forced portrait at 1080x800 (map 287 tall vs 270 view) | PASS | hero never off-screen; in the panning case the camera followed the hero 0 -> 17 px monotonically (expo approach) |
| C7 | arrival | `map3` at `walkDuration + 0.05 s` (`qa_map3_arrived.png`) | PASS | `hop` state, exactly 24 confetti, label pop scale 0.83 -> 1 |
| C8 | fresh connect: localhost | `map3`: no live session, `qa_map3_connecting.png` | PASS (after fix) | amber pulsing node after the hop, `connect` jingle, flag planted, spark burst, terminal scene 0.6 s after CONNECTED, exactly one session. **Was: the connecting node alternated the yellow "selected" and grey frames, no amber** |
| C9 | black hole 10.255.255.1 | `map3`: Enter on its stage | PASS | still `connecting` (amber) at 5 s, `error` + red flicker + error text after the core's 10 s connect timeout (the timeout starts after the ~1 s walk + hop), hero stays on the node, failed session closed (count back to 1) — `qa_map3_blackhole_amber.png` / `_error.png` |
| C10 | unresolvable nosuch.invalid | `map3` | PASS | `error` within 3 s: `cannot resolve nosuch.invalid: …`, red node (`qa_map3_unresolvable.png`), hero stays, session closed |
| C11 | click a node with a live session | `map3`: click on the online node | PASS | focuses the live session (terminal id == its id), session count unchanged |
| C12 | Enter / R / Del (confirm) | `map3` | PASS | Enter walks, R opens `rename`, Del opens `FORGET HOST?` (Esc keeps the host; Enter forgets it: gone from `hosts.json` and from the map) |
| C13 | keepalive glow pulse | `map3`: keepalive set to 2 s, `rec.pulse` sampled every map update (`qa_map3_glow.png`) | PASS (after fix) | pulse reaches 1.00 and **decays on the map (it only decayed inside the lobby's update before, so the glow latched at full after the first ping)**; drawn as three fading rings now |
| C14 | hover thumbnail | `map3`: `mousemoved` over the online node (`qa_map3_hover.png`) | PASS (tweaked) | label shows the live canvas; thumbnail enlarged 40 -> 60 px tall / 180 wide (a 1000x640 grid at 40 px was a black box) |
| C15 | fps on the map with 3 sessions | `map3`: 5 samples over 1 s, vsync off (`qa_map3_three.png`) | PASS | min 541 (>= 55) |
| C16 | Esc mid-walk | `map3`: Esc while the hero walks on page 1 | PASS (after fix) | lobby; **no session opened by the dead scene** — the hop -> connect timer and the connect -> terminal settle are cancelled in `leave()` now (unit test too) |
| D1 | F11 both ways | `display3`: `App.keypressed("f11")` twice with a session open | PASS | fullscreen 1080x1920 -> grid 125x110 == core, back to 125x40 == core, `config.display` follows; this time macOS did honour the request from the scripted window (`qa_display3_f11.png`) |
| D2 | Settings > display both ways | `display3`: `adjust` on the display row twice | PASS | same grid/core agreement, row text `fullscreen (desktop) (F11)` (`qa_display3_settings_fs.png`) |
| D3 | Ctrl+O cycle + persistence | `display3`: `App.cycleOrientation` x3 (chord verified in the unit test) | PASS | auto -> landscape -> portrait -> auto, `config.json` orientation follows each step, `D.portrait` effective flag right at 1080x800, grid == core after each, AI docks below when forced portrait (`qa_display3_forced_portrait.png`) |
| D4 | portrait 800x1400 | `portrait` phase (phase 2 regression) | PASS | 2 columns, AI below with 44 rows, map fits the width (770) |
| D5 | portrait 1080x1920 | `display3`: `setMode(1080,1920)` -> macOS gives 1080x1813, ui scale 2, content 510x872 | PASS (after fix) | 2 columns, AI below with 55 rows == core, status bar `F2 lobby`, map fits the width and is fully visible; **the map background was blank here** (see fix 1); **settings value `xai*** from XAI_API_KEY` ran past the frame** (fix 5) — `qa_display3_p1080_*.png` |
| D6 | overlays in portrait | `display3`: connect / search / rename / settings / help at 1080x1813 | PASS | all inside the window (`UI.frame` clamps to `vw - 8`, `menu` clamps itself); text clipped to the frame after fix 5 |
| D7 | landscape unchanged from phase 2 | unit: `Term.grid` 1080x800 = 125x40, 1920x1080 = 225x53; `display3` final 1080x800 = 125x40 | PASS | |
| D8 | resize storm alternating orientation | `display3`: 10 x `setMode` 710x1010 / 1020x720 …, then 1080x800 | PASS | grid == core, landscape again |
| E1 | phase 2 phases | `qa` 0 failures (54 checks, gpt-5 answer 657 chars, F11 honoured: 1080x1920 / 125x110), `verify`, `limit`, `perf`, `--mock mock`, `art`, `portrait`, `map`, `display`, `hero`: all 0 failures | PASS (after fix) | first `qa` run: **wheel over the scrollback did nothing** (fix 11) and the AI step 401'd on a fake key an earlier unpaired `qa` had left in config.json (`verify` clears it); a second run overlapped with the cargo ssh integration tests and produced timing failures — do not run the two on one sshd at once |
| E2 | unicode matrix | `make test-love` (a-e of the phase 2 matrix) + `qa` echo lines (`qa_terminal_unicode.png`) | PASS | unchanged |
| E3 | `make check` | lint-lua / stylua clean, in-engine suite 235/235, `cargo test --release` (see E4) | **PARTIAL** | `lint-rust` (clippy `-D warnings`) and `cargo fmt --check` are red on the **uncommitted core work in the tree** (`src/record.rs` enum_variant_names, `src/lib.rs:651` redundant_closure, unformatted `lib.rs`) — outside this phase (rust/ untouched), listed under Open |
| E4 | cargo tests | `cargo test --release` (unit 47 passed; `ssh_localhost` 9 passed, `names_search`, `llm`, ffi ABI suites passed in the session's first `make check`) | **FAIL (rust/, not this phase)** | the uncommitted `tests/db.rs` fails `pruning_keeps_io_under_max_mb` (8 of 9 pass; it also died with SIGTERM once while LÖVE walkthroughs were being restarted). Under Open |
| F1 | per-frame allocations in map.lua | review | PASS (after fix) | `dirs`, placeholder colour tables, hints, state-colour table hoisted; info rows and buttons reuse buffers; the undirected edge list is built once in `Map.new` (was rebuilt with a `drawn` set per frame); page-button closures created once |
| F2 | particle pool bounds | unit: 5000 dust puffs over a simulated 10-minute walk -> <= 4 alive; 100 confetti bursts -> exactly `fx.MAX_PARTICLES` | PASS (after fix) | pool capped at 512, oldest dropped |
| F3 | timers cancelled on scene exit | unit + `map3` C16 | PASS (after fix) | `fx.after` returns a cancellable handle; the map keeps its handles and cancels them in `leave()` |
| F4 | hosts.json not written per frame | unit: `saveHosts` counted over 120 updates + 5 draws | PASS | one write when a platform is assigned, none afterwards; the other writes are on connect (`touchHost`), remember, forget |

## Bugs found and fixed (love2d/)

1. **World map background blank after F11 / any `setMode`** — `G.sprite`
   returned the raw `Canvas` for anything larger than 65536 px (the 510x287
   map is 146k) and LÖVE does not keep canvas contents across a mode change.
   Once the map had been shown, toggling fullscreen or resizing the window
   left the platforms and paths floating on navy (`qa_display3_p1080_map.png`
   before the fix). Every sprite is baked to an `Image` now; the per-pixel
   chroma clean-up stays limited to small sprites. Unit test draws the map
   sprite before and after `love.window.setMode` (alpha 1 -> 0 before the fix).
2. **Map timers outlived the scene** — `arrive()` scheduled the hop -> connect
   and the CONNECTED -> terminal switch with `fx.after`, which had no cancel;
   Esc during the hop still opened a session, Esc during the 0.6 s settle
   still switched to the terminal. `fx.after` returns a handle, `fx.cancel`
   accepts it, `Map:after` wraps it and `Map:leave()` cancels everything.
3. **Keepalive glow never pulsed on the map** — `rec.pulse` was decayed in the
   lobby's update only, so on the map (and in the terminal status bar) it
   latched at 1 after the first ping. The decay moved into
   `Sessions.update(dt)`; every scene shares one heartbeat.
4. **Connecting node was not amber** — it alternated the yellow "selected" and
   grey frames. It is the grey disc tinted amber, pulsing 0.6..1.0 (STYLE 7.3).
5. **Settings value overflowed the frame** in portrait (`xai********p9u3 from
   XAI_API_KEY`); values are clipped to the frame width.
6. **Lobby hero head/torso shimmered** — `lockBelow = 0.66` pinned the legs
   and chair but the AI-generated second frame drifts ~1 px everywhere above
   that (4-8% of the pixels in every 10% band from the hair down). `lockAbove`
   added: rows above 45% copy frame 1 too, so only the hands/keyboard band
   animates. Unit + `hero6` checks.
7. **Ctrl+N did nothing on the map** although the empty-platform text says
   "Ctrl+N connects one": Ctrl+N / N open the connect dialog; `^N new` in the
   hints.
8. Camera target used the hero's bobbing `y`, so on a panning (portrait) map
   the camera inherited the 2 px bob; it follows the feet line (`hero.by`) now.
9. Portrait info panel: hints/page buttons were pinned to the bottom of a
   900 px panel at 800x1400, far from the text; they sit under the rows now.
   The empty-platform line is truncated like the others; a label that would
   collide with the header hangs under its node instead.
10. Particle pool capped (512), per-frame tables hoisted in `map.lua`, terminal
    tab-strip icon table created once, `statusRight/statusRightX/statusLeftEnd`
    exposed for tests.
11. **Scrollback wheel stolen by the context menu** (b72422f): `Term:wheelmoved`
    opened the menu whenever the *physical* cursor's y was above the tab strip —
    including a cursor parked above or beside the window, where `my < 0` —
    so wheel scrolling did nothing until the mouse was moved into the grid.
    The menu now needs the cursor inside the window and over the tab strip.
    The `qa` script parks the cursor on the grid before its wheel checks.
12. `qa` script: the AI wait is 60 s (gpt-5 reasons 20-40 s before the first
    delta; at 40 s Esc cancelled the request instead of closing the panel and
    every later grid check inherited the 80-column layout).

## Open (not fixed in this phase)

* `make check` is red at `lint-rust` / `fmt-check` because of the uncommitted
  core work in `rust/` (clippy: `record.rs:30` variant `OscEsc` ends with the
  enum's name, `lib.rs:651` redundant closure `db::with(|c| db::host_list(c))`;
  `cargo fmt` would reformat `lib.rs`). Nothing in this phase touches `rust/`;
  the Lua side of `make check` (lint-lua, 235 in-engine checks) is green.
* `cargo test --release`: the uncommitted `rust/tests/db.rs` fails
  `pruning_keeps_io_under_max_mb` (8/9 pass); the pre-existing suites pass.
* Commit `2ec9c66` added persistence/search declarations to `cbo.h` /
  `cbo_cdef.lua` that the built dylib does not export yet; nothing in Lua
  calls them, so the FFI load is unaffected (checked: every phase loads
  `libcbo_core.dylib v0.1.0`).

## Observations (no change made)

* The core's connect timeout is 10 s from `TcpStream::connect_timeout`; on the
  map that clock starts after the walk + hop, so a black-hole stage shows amber
  for ~11 s from the click. Fine, documented here so nobody "fixes" the 10 s.
* At 1080x800 landscape the 16:9 map (510x287) is one pixel taller than the
  view, so there is effectively no camera pan in landscape; the pan is
  exercised in forced portrait (`display3`) and on short portrait windows.
* macOS caps a 1080x1920 window at 1080x1813 (menu bar); portrait checks at
  "1080x1920" were run at that size, fullscreen gives the full 1080x1920.
* `captureScreenshot` grabs the end of the frame, so a scripted shot taken in
  the same step as a state change shows the changed state; the phase 3 scripts
  take their shots in their own steps where it matters.
* The string concatenations in `drawInfo` / `drawLabel` (`"key " .. keyTxt`,
  `os.date`) still allocate per frame; harmless at this size, could be cached
  on selection change if the map ever draws many labels.
* Map hero source frames: `hero_walk` keeps the frames within 6% of the median
  bbox; `hero_map_idle` keeps its two frames. Both anchor within 1 px.
