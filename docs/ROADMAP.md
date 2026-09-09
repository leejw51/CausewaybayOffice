# ROADMAP

## v0.1.0 — MVP (current)

Scope is the acceptance list in [SPEC.md](SPEC.md):

1. `make core && make start` opens the app; `make test` passes (cargo test + `love --test`).
2. Connect to `localhost` with agent/key; `ls`, `top`, `vim` render correctly.
3. `echo 你好 안녕 こんにちは Příliš žluťoučký kůň` renders with correct cell widths.
4. Three sessions open at once; search by name, rename one, cycle with Ctrl+Tab;
   keepalive holds an idle session > 5 min.
5. AI panel answers via any of openai / anthropic / xai with a key set in settings.

Plus the game feel in SPEC: CRT boot, card slide/pop, heartbeat pulse, breathing
cursor, bell shake, connect burst, expo fades everywhere.

Deliverables: `make app` produces an unsigned macOS `.app` with LÖVE and
`libcbo_core.dylib` inside; `docs/QA_CHECKLIST.md` passes end to end.

## v0.2 — a place to work

* **SFTP drawer**: slide-up file browser per session (ssh2 sftp), drag to
  upload, click to download, edit-in-place for small text files.
* **Split panes**: tmux-like horizontal/vertical splits inside one window,
  each pane its own session; Ctrl+\ / Ctrl+- to split, Ctrl+arrows to move.
* **Session groups / tags**: tag sessions (`prod`, `hk`, `gpu`), group cards on
  the shelf, search over tags, connect a whole group at once.
* **Sound design pass**: chiptune jingle per event (connect, disconnect, bell,
  keepalive tick optional), volume in settings, generated in-engine like Raiden.
* **Windows / Linux builds**: `.so` / `.dll` targets, loader already looks for
  them; CI matrix; Linux `.AppImage`, Windows zip with love.exe fused.
* Scrollback search, copy/paste with mouse selection, clickable URLs.
* Reconnect UX: exponential backoff, card shows countdown.

## v0.3 — the sidekick does things

* **AI tool use**: the sidekick proposes a command; a confirm card slides in;
  Enter runs it in the focused session, Esc discards. Output goes back to the
  model for a follow-up turn.
* **Terminal-aware context**: the last N screen lines (and optionally
  scrollback) are attached to the prompt, with a redaction pass for anything
  that looks like a secret.
* **Mosh-like roaming**: sessions survive laptop sleep / network change; core
  keeps state and replays the pty on reconnect.
* Per-session AI system prompt (host role: db box, build box, ...).
* Streaming token cost estimate in the panel.

## Ideas backlog

* Session recording / playback (asciicast).
* Port forwarding UI (local / remote / dynamic) as cards.
* Jump hosts / ProxyJump from `~/.ssh/config`; import that file as sessions.
* Themes: Causeway Bay night, Kowloon rain, Victoria Harbour dawn (palette +
  skyline only, same fonts).
* A "boss key": one tap to swap the skyline for a plain grey window.
* Gamepad navigation in the lobby (it is a game shelf after all).
* Achievements: 100 sessions opened, 24 h uptime, first `vim` exit.
* Web build (wasm core + WebSocket SSH proxy) in the Raiden `typescript/` style.
