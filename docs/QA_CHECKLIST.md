# QA CHECKLIST — CAUSEWAYBAY OFFICE v0.1.1

Manual acceptance script, derived from SPEC.md acceptance 1–5. Run on macOS
with Rust, LÖVE 11.5 at `~/Applications/love.app`, and a local sshd
(`System Settings > General > Sharing > Remote Login` on, or
`sudo systemsetup -setremotelogin on`). Record PASS / FAIL and notes per step.

Before starting:

```bash
cd /Volumes/nvidia/vivid/CausewaybayOffice
make version                  # prints 0.1.1
ssh -o BatchMode=yes localhost true && echo "ssh ok"   # agent/key auth must work non-interactively
```

If `ssh ok` does not print, fix that first (`ssh-add`, or put your key in
`~/.ssh/authorized_keys`); every connect test below depends on it.

---

## 1. Build, launch, test  (acceptance 1)

| # | command / action | expected |
|---|---|---|
| 1.1 | `make core` | ends with `rust/target/release/libcbo_core.dylib`, no warnings-as-errors |
| 1.2 | `make cdef && git diff --stat love2d/src/cbo_cdef.lua` | no diff (mirror is in sync with cbo.h) |
| 1.3 | `make start` | window opens: CRT power-on flash, logo fades in, Causeway Bay skyline parallax, then lobby with an empty shelf. No Lua error screen. |
| 1.4 | `make test` | `cargo test` all green; then LÖVE runs `--test` and the terminal shows `# all tests passed`, exit code 0 |
| 1.5 | `make lint` | `every Lua file compiles (N files)`; clippy clean |
| 1.6 | `make start-mock` | app opens without the core; lobby usable; connect shows a clear "core not loaded / mock" state rather than a crash |
| 1.7 | F1 | help overlay lists the keys from SPEC; Esc closes it |
| 1.8 | F11 twice | fullscreen and back; pixel scale stays integer, nothing stretched |

## 2. Real shell on localhost  (acceptance 2)

| # | action | expected |
|---|---|---|
| 2.1 | Ctrl+N, host `localhost`, port `22`, user `$USER`, leave password/key blank, Enter | card slides in (expo-out), state CONNECTING then CONNECTED within ~2 s; particle burst + jingle on success |
| 2.2 | card is focused; type `ls -la` Enter | directory listing renders, colours from `ls -G` if enabled, no garbage bytes |
| 2.3 | `top` | full-screen refresh every second, header stays pinned, `q` exits cleanly and the prompt is back |
| 2.4 | `vim /tmp/qa.txt`, `i`, type `hello office`, Esc, `:wq` | modal editing renders, cursor moves correctly, status line at bottom, file saved (`cat /tmp/qa.txt`) |
| 2.5 | `printf '\a'` | screen shake + flash (bell) |
| 2.6 | `printf '\e]0;QA TITLE\a'` | session card / terminal header shows `QA TITLE` |
| 2.7 | `seq 1 500` then scroll up (wheel or Shift+PgUp) | scrollback shows earlier lines; scroll to 0 returns to live screen |
| 2.8 | `tput colors; for i in $(seq 0 15); do tput setaf $i; printf 'C%02d ' $i; done; tput sgr0; echo` | 16 ANSI colours in the retro palette, all distinguishable |
| 2.9 | Ctrl+C while `sleep 100` runs | goes to the shell (interrupts sleep), does not close the app |
| 2.10 | `exit` | state CLOSED, card flickers / shows closed; Esc returns to lobby |

## 3. Unicode widths  (acceptance 3)

Run each in a connected session. Check with the cursor: after `echo` the
prompt must line up with the columns below, and no glyph may be drawn as a
tofu box or overlap its neighbour.

| # | command | expected columns |
|---|---|---|
| 3.1 | `echo 你好世界` | 4 glyphs, 8 cells wide, each glyph spans 2 cells (trailing cell blank, `width==0`) |
| 3.2 | `echo 안녕하세요` | 5 glyphs, 10 cells |
| 3.3 | `echo こんにちは` | 5 glyphs, 10 cells |
| 3.4 | `echo Příliš žluťoučký kůň úpěl ďábelské ódy` | 38 cells, every diacritic single-width, `ř ž ť č ů ň ě ď á é ó` correct |
| 3.5 | `echo 你好 안녕 こんにちは Příliš žluťoučký kůň` | mixed line: 4+1+4+1+10+1+6+1+9+1+3 = 41 cells; cursor lands right after `ň` |
| 3.6 | `python3 -c "print('a' + '́' + 'b')"` | combining acute merges into `a` (2 cells total, not 3) |
| 3.7 | `printf '%s\n' 你好世界 | cut -c1-2` (or `cbo_utf8_width` via the in-engine test) | core reports width 8 for `你好世界`, 38 for the Czech line |
| 3.8 | `vim` then paste `你好 안녕 こんにちは` and move the cursor across it with `l` | cursor jumps 2 cells per CJK glyph, never lands on a continuation cell |
| 3.9 | Ctrl+R, rename the session to `香港-辦公室` | name accepted (≤ 32 chars), card shows it in Unifont, search (Ctrl+K) `香港` finds it |

## 4. Sessions: three at once, search, rename, cycle, keepalive  (acceptance 4)

| # | action | expected |
|---|---|---|
| 4.1 | Ctrl+N ×3 to `localhost` | three cards on the shelf, each with a distinct auto name of the form `<adjective>-<hk-noun>-<NN>` (e.g. `neon-tram-07`); no duplicates |
| 4.2 | In each, run `echo $$` | three different PIDs (three real shells) |
| 4.3 | Ctrl+Tab, Ctrl+Tab, Ctrl+Tab | cycles 1 → 2 → 3 → 1 with a fade, focused card highlighted |
| 4.4 | Ctrl+Shift+Tab | cycles backwards |
| 4.5 | Ctrl+K, type 3 letters of one card's name | fuzzy match lists it first; Enter focuses it; Esc cancels |
| 4.6 | Ctrl+K, type the host `local` | all three match |
| 4.7 | Ctrl+R on session 2, type `build-box`, Enter | card renamed; Ctrl+K `build` finds it; name survives quit + relaunch (persistence) |
| 4.8 | Ctrl+R, type 40 characters | rejected / truncated at 32, no crash |
| 4.9 | Close one with `exit`, then Ctrl+N | new session gets a fresh name; the freed slot id is reused (check the debug id on the card if shown) |
| 4.10 | Quit the app (Cmd+Q) and `make start` | session list restored from the save dir; cards reconnect (state CONNECTING → CONNECTED) |

### Keepalive (idle > 5 min)

```bash
# terminal outside the app: watch the sshd side
sudo tcpdump -i lo0 -nn 'tcp port 22' 2>/dev/null | head -50   # optional
```

| # | action | expected |
|---|---|---|
| 4.11 | Open a session to localhost, note the time, leave it completely idle | every ~15 s the card pulses (heartbeat) |
| 4.12 | Settings (Ctrl+,) or the in-engine test: read `CboSessionInfo.last_ping_ms` twice, 20 s apart | second value > first (advances by ≈15 000 ms per tick) |
| 4.13 | After 5 min 30 s idle, press Enter in the session | prompt responds immediately; state still CONNECTED; `last_activity_ms` updates |
| 4.14 | Set keepalive to 0 in settings, idle 1 min | no pulses, `last_ping_ms` frozen; set back to 15 → pulses resume |
| 4.15 | (optional) `sshd -T | grep -i clientalive`; if you can set `ClientAliveInterval 60 / ClientAliveCountMax 1` on the test host | with keepalive on the session survives 5 min; with keepalive 0 it drops |

### 128-session limit

Run from the in-engine test or a scratch Lua snippet against the mock/real
core (each mock open is cheap; real opens against localhost are fine too but
slower):

```lua
local core = require("src.core")
local ids = {}
for i = 1, 200 do
  local id = core.session_open("localhost", 22, os.getenv("USER"), nil, nil, 80, 24)
  if id < 0 then print("refused at", i, core.last_error()); break end
  ids[#ids + 1] = id
end
assert(#ids == 128, "expected 128 sessions, got " .. #ids)
for _, id in ipairs(ids) do core.session_close(id) end
```

| # | expected |
|---|---|
| 4.16 | exactly 128 opens succeed; the 129th returns -1 and `cbo_last_error()` says the limit was reached |
| 4.17 | `cbo_session_count()` == 128; `cbo_session_ids` fills 128 distinct ids in 0..127 |
| 4.18 | close + free all; count returns to 0; opening again succeeds with a low id |
| 4.19 | the lobby with 128 cards still renders at ≥ 30 fps and scrolls |

### Resize

| # | action | expected |
|---|---|---|
| 4.20 | In a session run `tput cols; tput lines` | matches the cell grid drawn on screen |
| 4.21 | Drag the window wider / taller | `cbo_session_resize` called; `tput cols; tput lines` reflect the new grid; `top` reflows; no torn rows |
| 4.22 | Shrink the window below the initial size | grid shrinks, wide glyphs at the right edge wrap to the next line instead of being cut in half |
| 4.23 | F11 (fullscreen) with `vim` open | vim redraws to the full grid; F11 back restores |
| 4.24 | Resize repeatedly (10 times fast) | no crash, no error; final `tput cols` correct |

## 5. AI sidekick  (acceptance 5)

For each provider you have a key for (at least one must pass):

| # | action | expected |
|---|---|---|
| 5.1 | Ctrl+, open Settings, pick provider, paste key, save | key stored in `config.json` in the LÖVE save dir; masked in the UI |
| 5.2 | Ctrl+Space, type `What does 'ls -la' show? One sentence.` Enter | answer streams in token by token (state STREAMING then DONE), no freeze of the terminal behind it |
| 5.3 | Same with a wrong key | state ERROR, readable message (401 / auth), no crash |
| 5.4 | Remove the key from Settings, `export OPENAI_API_KEY=...` (or ANTHROPIC_/XAI_/GROK_) and relaunch via `make start` | env fallback works, same streamed answer |
| 5.5 | Ask something long, press Esc mid-stream | request cancelled, panel closes, later `cbo_llm_free` leaves no leak (open the panel again, it works) |
| 5.6 | Ask `Reply with exactly: 你好 안녕 こんにちは ď` | reply renders with correct widths in the panel |
| 5.7 | Switch provider in Settings and ask again | correct default model per provider (gpt-5 / claude-opus-5 / grok-4.6) shown in the panel header |

## 6. Package

| # | command | expected |
|---|---|---|
| 6.1 | `make app` | `love2d/build/CausewaybayOffice.app` and `-macos.zip`; dylib in `Contents/Frameworks` and `Contents/Resources` |
| 6.2 | `open love2d/build/CausewaybayOffice.app` | boots straight into the app (no LÖVE no-game screen); connect to localhost works from the bundle |
| 6.3 | `make clean && ls love2d/build` | build directory gone |

---

Sign-off: date, macOS version, commit hash, which providers were tested,
failures with step numbers.
