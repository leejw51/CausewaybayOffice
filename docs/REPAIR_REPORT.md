# Repair and verification - 2026-09-09

The interrupted implementation now builds and starts. The immediate compile failure
was caused by non-ASCII Rust string byte escapes; the affected test fixtures now use
byte strings. The unfinished persistence/assistance implementation was completed,
connected to the Lua UI, and checked through the actual C ABI.

## Resulting behavior

- Mario Map has real session stages and empty connection slots. Every live session
  has its own stage, including duplicate addresses. Ten-stage pagination and invalid
  saved positions are repaired. Portrait has a tall world with drag/wheel/Shift+Arrow
  panning; Home recenters the selected stage.
- Map2 displays all sessions and offline favorites, with live search and state filters.
- Both maps ease into a selected session with exponential camera zoom and pull back
  onto the same session on return. Map2 has a moving selection frame and explicit
  Disconnect menu. User disconnects close/reopen a black pixel-stepped aperture,
  preserving favorites and recording disconnect intent before the animation ends.
- Two display toggles remain available above every page and dialog.
- New servers become favorites automatically. Favorites are maintained as JSONL.
- Successfully connected sessions automatically reconnect after restart, retaining
  independent names such as mary-1 or custom names. Explicit close removes a session
  from restoration. Passwords are excluded. Tests cover 100 sessions in the UI and
  restore model, within the existing 128-slot core.
- Non-secret fields remember input in SQLite and offer live suggestions. Ctrl+Space
  reuses a suggestion. Terminal command learning records simple echoed prompt commands
  and their sequences; completion appends only the missing suffix, never Enter.
- Settings, learned fields and optional recordings use office.db. Favorites and
  sessions use favorites.jsonl and sessions.jsonl; display changes append to
  display.jsonl. All live under ~/.causewaybayoffice, or CBO_HOME when overridden.
- Legacy settings/hosts JSON is imported. Known old QA mock hosts are removed with
  the original list backed up in SQLite. QA and mock runs use separate storage.

## Correctness and security repairs

- Real-core loading fails explicitly instead of silently substituting a mock.
  Packaged applications also search their bundled library locations.
- Recording is opt-in and disabling it stops already active recorders. Enabling it
  attaches to existing sessions. Shutdown flushes pending writes.
- OpenAI indexing requires separate consent; a configured chat API key does not
  activate history uploads. Remote search no longer holds the shared database lock.
- Database/files use private permissions. Favorites/session snapshots use locked,
  atomic replacement; display JSONL appends are locked. Credential fields are
  excluded from learned input and session/favorite snapshots.
- SSH host-key updates are serialized across processes and written atomically.
  Stale connection workers cannot publish over reused sessions. Keys/agent precede
  password authentication.
- AI output and multiline paste have a review path. Bracketed paste follows the
  remote terminal mode; pasted control escapes are removed. A review binds to the
  original session record, preventing accidental sends to a reused slot.
- Provider redirects are disabled. Cancellation stops UI publication immediately;
  terminal deltas are drained correctly. Oversized streams are bounded and premature
  EOF reports an error instead of success.
- Recorder queues and transcript windows are bounded. Pruning preserves the newest
  raw data that fits the configured cap. Embedding response ordering/dimensions are
  validated and query caching is bounded.
- Fixed terminal color double inversion/brightening, UTF-8 paste limits, scrolling
  lists and several map/UI input and layout errors.
- AI chat now exposes AI CHAT, SEND and KEY controls, chooses an available provider
  when the default has no key, and keeps chat input/paste from reaching SSH.
  Portrait chat stacks below the terminal; horizontal chat docks beside it.
  Cycling sessions starts a fresh chat context so an answer cannot target another
  host. Live testing sent a prompt and received its response through the actual UI.

## Verification

The complete `make test` run passed all 15 stages. It exercised 60 Rust unit tests,
all seven Rust integration targets, documentation tests, all 69 C ABI declarations,
305 LÖVE regressions, and four real SSH UI walkthroughs. Two Anthropic live checks
were explicitly skipped because ANTHROPIC_API_KEY was absent. OpenAI/xAI streaming
and cancellation, provider authentication failures and OpenAI embeddings ran live.

The real UI walkthrough verified two separate localhost map stages, vertical layout,
panning, an empty-stage connection form, JSONL favorites, SQLite field reuse, and
echoed-command completion without execution. Camera transitions selected the exact
session in both maps, returned to the same stage, and disconnected through the
aperture while retaining the other session and favorite. The live AI panel sent
and received a provider response and verified both portrait/landscape layouts.
Separate application processes verified
automatic reconnection and custom-name persistence, then explicit-close persistence.

Formatting, Lua compilation and Clippy with warnings denied were also checked.
See [TESTING.md](TESTING.md) for commands and coverage. The full run's original logs
and machine-readable report are under
`love2d/build/test-results/20260909-175016-32094/`.
The macOS app/zip were rebuilt, and the packaged dylib passed the ABI/persistence
smoke test with all 69 declarations resolved from the bundle itself.

## Remaining limits

This is a code review and regression repair, not a formal security certification.
SSH still uses trust on first use; there is no first-connection fingerprint approval
dialog. Password-only servers require credentials again after restart.

Command-only learning deliberately skips ambiguous edits, wrapped lines and inputs
without a recognized echoed prompt. It cannot reliably reconstruct arbitrary shell
or fullscreen application state. Explicit raw recording can contain remote secrets;
neither recordings nor command arguments are encrypted or automatically redacted.
The default 512 MB recorder cap covers raw I/O, not all SQLite indexes/history;
the 8 MB pending queue can drop new recording items under sustained disk pressure.

Combining marks have correct cell width but the current single-codepoint rendering
ABI does not draw every decomposed accent. SFTP, splits, roaming and tag editing
remain roadmap items. The 100-session verification uses the mock transport for
capacity/UI/restore tests; real SSH checks cover multiple concurrent connections,
not a sustained 100-server load test.
