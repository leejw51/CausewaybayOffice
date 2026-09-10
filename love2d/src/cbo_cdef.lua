-- GENERATED from rust/include/cbo.h — keep in sync (make cdef).
local ffi = require("ffi")

ffi.cdef([[
/* CAUSEWAYBAY OFFICE core — C ABI. Mirrored in love2d/src/cbo_cdef.lua. */


/* session states */
enum { CBO_ST_IDLE = 0, CBO_ST_CONNECTING = 1, CBO_ST_CONNECTED = 2,
       CBO_ST_CLOSED = 3, CBO_ST_ERROR = 4 };

/* cell attr bits */
enum { CBO_ATTR_BOLD = 1, CBO_ATTR_ITALIC = 2, CBO_ATTR_UNDERLINE = 4,
       CBO_ATTR_INVERSE = 8, CBO_ATTR_BLINK = 16, CBO_ATTR_DIM = 32 };

typedef struct CboCell {
  uint32_t cp;      /* unicode code point, 0 = blank */
  uint32_t fg;      /* 0xRRGGBB */
  uint32_t bg;      /* 0xRRGGBB */
  uint8_t  attr;    /* CBO_ATTR_* */
  uint8_t  width;   /* 1 normal, 2 wide (CJK), 0 = continuation of a wide cell */
  uint8_t  _pad[2];
} CboCell;

typedef struct CboSessionInfo {
  int32_t  id;
  int32_t  state;          /* CBO_ST_* */
  uint16_t cols, rows;
  uint16_t port;
  uint16_t _pad;
  uint64_t created_ms;     /* unix ms */
  uint64_t last_activity_ms;
  uint64_t last_ping_ms;   /* last keepalive sent */
  uint64_t generation;     /* bumps whenever the screen changes */
  char     name[64];       /* UTF-8, NUL terminated */
  char     host[128];
  char     user[64];
} CboSessionInfo;

/* ---- lifecycle ---- */
void        cbo_init(void);
void        cbo_shutdown(void);           /* close sessions and flush recordings before exit */
const char* cbo_version(void);
const char* cbo_last_error(void);          /* thread-local, "" when none */

/* ---- sessions ---- */
/* Async connect. password/keypath may be NULL. NULL keypath = try agent, then ~/.ssh/id_*.
   Returns id >= 0 or -1 (limit reached / bad args; see cbo_last_error). */
int32_t     cbo_session_open(const char* host, uint16_t port, const char* user,
                             const char* password, const char* keypath,
                             uint16_t cols, uint16_t rows);
int32_t     cbo_session_state(int32_t id);
const char* cbo_session_error(int32_t id);  /* message when state == ERROR */
int32_t     cbo_session_info(int32_t id, CboSessionInfo* out);   /* 0 ok, -1 bad id */
int32_t     cbo_session_count(void);
int32_t     cbo_session_ids(int32_t* out, int32_t cap);           /* returns n */
void        cbo_session_write(int32_t id, const uint8_t* bytes, uint32_t len);
void        cbo_session_resize(int32_t id, uint16_t cols, uint16_t rows);
void        cbo_session_close(int32_t id);   /* graceful; state -> CLOSED */
void        cbo_session_free(int32_t id);    /* release slot (must be CLOSED/ERROR) */
int32_t     cbo_session_set_name(int32_t id, const char* name);
const char* cbo_session_get_name(int32_t id);
void        cbo_session_set_keepalive(int32_t id, uint32_t seconds); /* 0 = off */
int32_t     cbo_session_reconnect(int32_t id);                        /* same params */

/* ---- terminal snapshot ---- */
/* Copies cols*rows cells into out (cap = number of CboCell). Returns cells written. */
int32_t     cbo_term_snapshot(int32_t id, CboCell* out, int32_t cap);
uint64_t    cbo_term_generation(int32_t id);
int32_t     cbo_term_bracketed_paste(int32_t id); /* remote enabled DECSET 2004 */
void        cbo_term_cursor(int32_t id, uint16_t* x, uint16_t* y, uint8_t* visible);
const char* cbo_term_title(int32_t id);      /* OSC 0/2 title, "" if none */
const char* cbo_term_cwd(int32_t id);        /* remote cwd: OSC 7, else a "user@host: path" title; "" if unknown */

/* Async per-session file job. JSON request: {op: local/list/upload/download,
 * local: path, remote: path, overwrite?: bool}. Paths are literal, never shell
 * commands. One job at a time; start: 0 / -1 + last_error. Status JSON: state
 * running/done/error/cancelled, op, done/total bytes, result or error.
 * Existing destination files are never overwritten, except an upload with
 * overwrite: true, which replaces the remote file through a temp file and a
 * backup swap (the original stays intact on failure). */
/* Independent read-only stat for terminal links; result contains path, dir,
 * file. Does not replace or block the session's upload/download job. */
int32_t cbo_files_probe(int32_t id, const char *path);
const char *cbo_files_probe_status(int32_t id);
int32_t cbo_files_start(int32_t id, const char *request);
const char *cbo_files_status(int32_t id);
void cbo_files_cancel(int32_t id);
int32_t     cbo_term_take_bell(int32_t id);  /* returns bell count since last call */
/* scrollback: 0 = live screen, n = n lines up. */
void        cbo_term_scroll(int32_t id, int32_t offset);
int32_t     cbo_term_scroll_offset(int32_t id);
int32_t     cbo_term_scrollback_len(int32_t id);

/* ---- images: kitty graphics protocol (APC "ESC _ G ... ESC \") ----
   The core strips the sequences from the stream, keeps the image bytes as sent
   (PNG or raw RGB/RGBA, optionally zlib) and answers the client. Lua decodes
   and draws. Placements scroll with the text; the list is recomputed per call
   and the term generation bumps whenever it changes. */
typedef struct CboPlacement {
  uint64_t image_key;      /* unique per transmitted image; cache textures by it */
  uint32_t image_id;       /* client-chosen id (0 = anonymous) */
  uint32_t placement_id;
  int32_t  col, row;       /* top-left cell on the visible screen; may be negative */
  uint16_t cols, rows;     /* size in cells */
  int32_t  z;              /* z-index; < 0 draws under the text */
  uint32_t src_x, src_y, src_w, src_h;  /* source rectangle in image pixels */
} CboPlacement;

typedef struct CboImageInfo {
  uint64_t key;
  uint32_t width, height;  /* pixels (from s/v or the PNG header) */
  uint32_t bytes;          /* stored payload size */
  uint32_t format;         /* 24 = RGB, 32 = RGBA, 100 = PNG */
  uint32_t compressed;     /* 1 = payload is zlib (RFC 1950) */
  uint32_t _pad;
} CboImageInfo;

/* Cell size in pixels: reported to the remote (pty winsize, CSI 14/16 t) and used
   to size images that give no c/r. Default 8x16. */
void        cbo_term_set_cell_px(int32_t id, uint16_t w, uint16_t h);
/* Visible placements ordered by z. Returns n (<= cap). */
int32_t     cbo_term_placements(int32_t id, CboPlacement* out, int32_t cap);
int32_t     cbo_term_image_info(int32_t id, uint64_t key, CboImageInfo* out); /* 0 ok, -1 unknown */
/* Copies up to cap bytes of the stored payload. Returns bytes copied. */
int32_t     cbo_term_image_data(int32_t id, uint64_t key, uint8_t* out, int32_t cap);

/* ---- names / search ---- */
const char* cbo_name_generate(uint64_t seed);     /* unique among live sessions */
/* Fuzzy over name/host/user. Fills out with ids ordered by score. Returns n. */
int32_t     cbo_session_search(const char* query, int32_t* out, int32_t cap);

/* ---- llm (streaming) ---- */
enum { CBO_LLM_PENDING = 0, CBO_LLM_STREAMING = 1, CBO_LLM_DONE = 2, CBO_LLM_ERROR = 3 };
/* provider: "openai" | "anthropic" | "xai". model may be NULL for provider default.
   messages_json: [{"role":"user","content":"..."}] (system is separate).
   Returns request id >= 0 or -1. */
int32_t     cbo_llm_start(const char* provider, const char* api_key, const char* model,
                          const char* system, const char* messages_json);
int32_t     cbo_llm_state(int32_t req);
/* Drains newly streamed text since the last call (UTF-8, may be ""). */
const char* cbo_llm_take_delta(int32_t req);
const char* cbo_llm_error(int32_t req);
void        cbo_llm_cancel(int32_t req);
void        cbo_llm_free(int32_t req);

/* ---- utils ---- */
int32_t     cbo_utf8_width(const char* s);   /* display columns of a UTF-8 string */
uint64_t    cbo_now_ms(void);


/* ---- persistence: sqlite at ~/.causewaybayoffice/office.db (all local, owned by the user) ---- */
const char* cbo_data_dir(void);                       /* absolute path, created on cbo_init */
int32_t     cbo_kv_set(const char* key, const char* value);   /* settings incl. api keys ("apikey.openai") */
const char* cbo_kv_get(const char* key);              /* "" when unset */
/* hosts: JSON {id?, name, host, port, user, keypath, platform, tags, last_used_ms, use_count}.
   upsert keyed by id (if > 0) else by user@host:port. Returns id or -1. */
/* Favorites snapshot: one credential-free server per JSONL line. */
int32_t     cbo_favorites_save(const char* json); /* {"hosts":[...]} */
const char* cbo_favorites_load(void); /* same JSON object, empty when absent */

/* Sessions restored on next launch; duplicate addresses remain separate lines. */
int32_t     cbo_sessions_save(const char* json); /* {"hosts":[...]} */
const char* cbo_sessions_load(void);

/* Append display preferences to $CBO_HOME/display.jsonl (default ~/.causewaybayoffice). */
int32_t     cbo_display_save(int32_t fullscreen, const char* orientation);

/* Local non-secret field drafts/history; search returns a JSON string array. */
int32_t     cbo_input_save(const char* field, const char* value, int32_t commit);
const char* cbo_input_search(const char* field, const char* query, int32_t limit);

int32_t     cbo_host_upsert(const char* json);
int32_t     cbo_host_delete(int32_t host_id);
const char* cbo_host_get(int32_t host_id);            /* JSON or "" */
const char* cbo_host_list(void);                      /* JSON array ordered by last_used desc */
int32_t     cbo_session_set_host(int32_t id, int32_t host_id); /* link a live session to a host row */

/* ---- recording: every session's input/output, commands, ui events, ai chats ---- */
void        cbo_record_enable(int32_t on);            /* opt-in, default off; persisted in kv "record" */
int32_t     cbo_record_enabled(void);
/* kind: "ui" | "ai" | "note" | "nav". data_json is free-form. Returns event id. */
int64_t     cbo_record_event(const char* kind, const char* scene, const char* action, const char* data_json);
/* transcript text of a session (from the recording), newest max_bytes. */
const char* cbo_session_transcript(int32_t id, int32_t max_bytes);
/* JSON array of recent commands [{ts_ms, session_id, host_id, cmd}] newest first */
const char* cbo_recent_commands(int32_t host_id /* 0 = any */, int32_t limit);

/* ---- search: hybrid BM25 (sqlite FTS5) + semantic (embeddings, cosine), fused by RRF ----
   kinds_csv: any of "host,session,command,transcript,ai,event,note" or "" for all.
   Returns JSON [{kind, id, score, title, snippet, ts_ms, host_id, session_id}]. */
const char* cbo_search(const char* query, const char* kinds_csv, int32_t limit);
const char* cbo_search_bm25(const char* query, const char* kinds_csv, int32_t limit);
const char* cbo_search_semantic(const char* query, const char* kinds_csv, int32_t limit);
int32_t     cbo_embed_pending(void);                  /* rows waiting for an embedding (background) */
int32_t     cbo_embed_available(void);                /* 1 when kv "embed.enabled" = "1" and provider key is configured */

/* ---- notes: free text from the AI panel's note mode. Saved whether or not recording is
   on; indexed for BM25 at once and embedded in the background when indexing is enabled.
   Search them with cbo_search / cbo_search_bm25 and kinds_csv "note". ---- */
int64_t     cbo_note_add(const char* text, int32_t session_id);  /* returns id or -1 */
int32_t     cbo_note_delete(int64_t id);                         /* 0 ok, -1 unknown id */
const char* cbo_note_list(int32_t limit);                        /* JSON [{id, ts_ms, text, session_id}] newest first */

/* ---- patterns: learned from recorded events; drives button highlighting and assist ----
   Returns JSON [{action, count, prob}] for what the user usually does next in `scene`
   after `last_action` ("" = scene entry), plus time-of-day weighting. */
const char* cbo_suggest(const char* scene, const char* last_action, int32_t limit);
/* JSON context bundle for the AI: current scene, live sessions, recent commands, transcript tail,
   frequent hosts, suggestions. max_chars bounds the transcript part. */
const char* cbo_context(const char* scene, int32_t session_id, int32_t max_chars);
const char* cbo_stats(void);                          /* JSON: counts per table, db size, top hosts/commands */


/* ---- typing assist: what the user is typing right now, and completions for it ---- */
/* Current partial input line of a live session (from the recorder's line assembler), "" if none. */
int32_t     cbo_session_can_complete(int32_t id); /* echoed, simple prompt input only */
const char* cbo_session_typing(int32_t id);
/* Completions for a prefix: JSON [{cmd, score, source:"history"|"pattern"|"host", count, last_ms}].
   Ranked by frequency, recency, same-host boost and BM25 prefix match; host_id 0 = any. */
const char* cbo_complete(int32_t host_id, const char* prefix, int32_t limit);
/* Predicted next commands after the last executed command on this host (pattern chain), same JSON. */
const char* cbo_predict_next(int32_t host_id, int32_t limit);

]])

local M = {}
M.MAX_SESSIONS = 128
M.ST = { IDLE = 0, CONNECTING = 1, CONNECTED = 2, CLOSED = 3, ERROR = 4 }
M.ATTR = { BOLD = 1, ITALIC = 2, UNDERLINE = 4, INVERSE = 8, BLINK = 16, DIM = 32 }
M.LLM = { PENDING = 0, STREAMING = 1, DONE = 2, ERROR = 3 }

-- Find the dylib next to the source tree (dev) or inside the app bundle (release).
local function candidates()
  local ext = ffi.os == "OSX" and "dylib" or (ffi.os == "Windows" and "dll" or "so")
  local name = (ffi.os == "Windows" and "" or "lib") .. "cbo_core." .. ext
  local src = love.filesystem.getSource()
  local base = love.filesystem.getSourceBaseDirectory()
  return {
    src .. "/" .. name,
    src .. "/../rust/target/release/" .. name,
    src .. "/../rust/target/debug/" .. name,
    base .. "/" .. name,
    base .. "/../Frameworks/" .. name,
    base .. "/rust/target/release/" .. name,
    base .. "/rust/target/debug/" .. name,
    name,
  }
end

function M.load()
  local errs = {}
  for _, path in ipairs(candidates()) do
    local ok, lib = pcall(ffi.load, path)
    if ok then
      M.lib = lib
      M.path = path
      lib.cbo_init()
      return lib
    end
    errs[#errs + 1] = path .. ": " .. tostring(lib)
  end
  error("cbo_core not found. Run `make core`.\n" .. table.concat(errs, "\n"))
end

return M
