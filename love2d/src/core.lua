-- Lua-friendly wrapper over the cbo_core FFI surface. Falls back to the mock
-- (src/core_mock.lua) when the dylib is missing so the whole UI can be built
-- and tested without Rust. Strings crossing the boundary are copied at once.

local ffi = require("ffi")
local cdef = require("src.cbo_cdef")

local Core = {}
Core.ST = cdef.ST
Core.ATTR = cdef.ATTR
Core.LLM = cdef.LLM
Core.MAX_SESSIONS = cdef.MAX_SESSIONS
Core.mock = false
Core.lib = nil
Core.path = nil
Core.version = "?"

local lib
local infoBuf = ffi.new("CboSessionInfo")
local idsBuf = ffi.new("int32_t[?]", cdef.MAX_SESSIONS)
local cx = ffi.new("uint16_t[1]")
local cy = ffi.new("uint16_t[1]")
local cv = ffi.new("uint8_t[1]")
local snapshots = {} -- id -> { cells = CboCell[], cap = n }
local PLACE_CAP = 256
local placeBuf = ffi.new("CboPlacement[?]", PLACE_CAP)
local imageInfoBuf = ffi.new("CboImageInfo")

local function str(v)
  if v == nil then
    return ""
  end
  if type(v) == "string" then
    return v
  end
  return ffi.string(v)
end

local function cstr(s)
  if s == nil or s == "" then
    return nil
  end
  return s
end

function Core.load(opts)
  opts = opts or {}
  if not opts.forceMock then
    local ok, res = pcall(cdef.load)
    if ok then
      lib = res
      Core.lib = lib
      Core.path = cdef.path
      Core.mock = false
      Core.version = str(lib.cbo_version())
      print("[core] loaded " .. tostring(cdef.path) .. " v" .. Core.version)
      return Core
    end
    Core.loadError = tostring(res)
    error(
      "Cannot load the SSH core. Run make core, or make start-mock for the demo.\n"
        .. Core.loadError
    )
  end
  lib = require("src.core_mock")
  lib.cbo_init()
  Core.lib = lib
  Core.mock = true
  Core.version = str(lib.cbo_version())
  return Core
end

-- Mock needs a clock; the real core runs its own threads.
function Core.update(dt)
  if Core.mock and lib.update then
    lib.update(dt)
  end
end

function Core.lastError()
  return str(lib.cbo_last_error())
end

-- Sessions -------------------------------------------------------------------

function Core.open(p)
  local id = lib.cbo_session_open(
    p.host or "",
    tonumber(p.port) or 22,
    p.user or "",
    cstr(p.password),
    cstr(p.keypath),
    p.cols or 80,
    p.rows or 24
  )
  id = tonumber(id)
  if id < 0 then
    return nil, Core.lastError()
  end
  return id
end

function Core.state(id)
  return tonumber(lib.cbo_session_state(id))
end

function Core.error(id)
  return str(lib.cbo_session_error(id))
end

function Core.info(id)
  if tonumber(lib.cbo_session_info(id, infoBuf)) ~= 0 then
    return nil
  end
  return {
    id = tonumber(infoBuf.id),
    state = tonumber(infoBuf.state),
    cols = tonumber(infoBuf.cols),
    rows = tonumber(infoBuf.rows),
    port = tonumber(infoBuf.port),
    created_ms = tonumber(infoBuf.created_ms),
    last_activity_ms = tonumber(infoBuf.last_activity_ms),
    last_ping_ms = tonumber(infoBuf.last_ping_ms),
    generation = tonumber(infoBuf.generation),
    name = ffi.string(infoBuf.name),
    host = ffi.string(infoBuf.host),
    user = ffi.string(infoBuf.user),
  }
end

function Core.count()
  return tonumber(lib.cbo_session_count())
end

function Core.ids()
  local n = tonumber(lib.cbo_session_ids(idsBuf, cdef.MAX_SESSIONS))
  local t = {}
  for i = 0, n - 1 do
    t[#t + 1] = tonumber(idsBuf[i])
  end
  return t
end

function Core.write(id, s)
  if s == nil or #s == 0 then
    return
  end
  if Core.mock then
    lib.cbo_session_write(id, s, #s)
  else
    lib.cbo_session_write(id, ffi.cast("const uint8_t*", s), #s)
  end
end

function Core.resize(id, cols, rows)
  lib.cbo_session_resize(id, cols, rows)
end

function Core.close(id)
  lib.cbo_session_close(id)
end

function Core.free(id)
  lib.cbo_session_free(id)
  snapshots[id] = nil
end

function Core.setName(id, name)
  return tonumber(lib.cbo_session_set_name(id, name)) == 0
end

function Core.getName(id)
  return str(lib.cbo_session_get_name(id))
end

function Core.setKeepalive(id, seconds)
  lib.cbo_session_set_keepalive(id, seconds)
end

function Core.reconnect(id)
  return tonumber(lib.cbo_session_reconnect(id)) == 0
end

-- Terminal -------------------------------------------------------------------

-- Returns cells (CboCell[]), cols, rows, n. The array is preallocated per
-- session and only regrown when the grid grows.
function Core.snapshot(id, cols, rows)
  if not cols then
    local info = Core.info(id)
    if not info then
      return nil, 0, 0, 0
    end
    cols, rows = info.cols, info.rows
  end
  local need = cols * rows
  local s = snapshots[id]
  if not s or s.cap < need then
    s = { cells = ffi.new("CboCell[?]", need), cap = need }
    snapshots[id] = s
  end
  local n = tonumber(lib.cbo_term_snapshot(id, s.cells, s.cap))
  return s.cells, cols, rows, n
end

function Core.generation(id)
  return tonumber(lib.cbo_term_generation(id))
end

function Core.cursor(id)
  lib.cbo_term_cursor(id, cx, cy, cv)
  return tonumber(cx[0]), tonumber(cy[0]), cv[0] ~= 0
end

function Core.title(id)
  return str(lib.cbo_term_title(id))
end

-- Remote working directory as reported by the shell (OSC 7) or shown in a
-- "user@host: path" title; "" until known.
function Core.cwd(id)
  return str(lib.cbo_term_cwd(id))
end

function Core.probePath(id, path)
  if Core.mock then
    return false
  end
  return lib.cbo_files_probe(id, path) == 0
end
function Core.probeStatus(id)
  if Core.mock then
    return {}
  end
  return require("src.json").decode(str(lib.cbo_files_probe_status(id))) or {}
end

function Core.filesStart(id, request)
  if Core.mock then
    return false, "File transfers require a real SSH session"
  end
  local ok = lib.cbo_files_start(id, require("src.json").encode(request)) == 0
  return ok, not ok and Core.lastError() or nil
end
function Core.filesStatus(id)
  if Core.mock then
    return {}
  end
  return require("src.json").decode(str(lib.cbo_files_status(id))) or {}
end
function Core.filesCancel(id)
  if not Core.mock then
    lib.cbo_files_cancel(id)
  end
end

function Core.takeBell(id)
  return tonumber(lib.cbo_term_take_bell(id))
end

function Core.scroll(id, offset)
  lib.cbo_term_scroll(id, offset)
end

function Core.scrollOffset(id)
  return tonumber(lib.cbo_term_scroll_offset(id))
end

function Core.scrollbackLen(id)
  return tonumber(lib.cbo_term_scrollback_len(id))
end

-- Images (kitty graphics protocol) -------------------------------------------

-- Cell size in pixels, as the remote side sees it (winsize, CSI 14/16 t).
function Core.setCellPx(id, w, h)
  lib.cbo_term_set_cell_px(id, w, h)
end

-- Visible placements ordered by z, as plain tables (fills and returns `out`).
function Core.placements(id, out)
  out = out or {}
  local n = tonumber(lib.cbo_term_placements(id, placeBuf, PLACE_CAP))
  for i = 1, n do
    local p = placeBuf[i - 1]
    local t = out[i] or {}
    t.key = tonumber(p.image_key)
    t.image_id = tonumber(p.image_id)
    t.placement_id = tonumber(p.placement_id)
    t.col, t.row = tonumber(p.col), tonumber(p.row)
    t.cols, t.rows = tonumber(p.cols), tonumber(p.rows)
    t.z = tonumber(p.z)
    t.sx, t.sy, t.sw, t.sh =
      tonumber(p.src_x), tonumber(p.src_y), tonumber(p.src_w), tonumber(p.src_h)
    out[i] = t
  end
  for i = #out, n + 1, -1 do
    out[i] = nil
  end
  return out
end

-- { width, height, bytes, format (24 | 32 | 100), compressed } or nil.
function Core.imageInfo(id, key)
  if tonumber(lib.cbo_term_image_info(id, key, imageInfoBuf)) ~= 0 then
    return nil
  end
  return {
    key = key,
    width = tonumber(imageInfoBuf.width),
    height = tonumber(imageInfoBuf.height),
    bytes = tonumber(imageInfoBuf.bytes),
    format = tonumber(imageInfoBuf.format),
    compressed = tonumber(imageInfoBuf.compressed) ~= 0,
  }
end

-- The stored payload as a Lua string ("" when unknown).
function Core.imageData(id, key, bytes)
  bytes = bytes or (Core.imageInfo(id, key) or { bytes = 0 }).bytes
  if bytes <= 0 then
    return ""
  end
  local buf = ffi.new("uint8_t[?]", bytes)
  local n = tonumber(lib.cbo_term_image_data(id, key, buf, bytes))
  return ffi.string(buf, n)
end

-- Names / search -------------------------------------------------------------

function Core.nameGenerate(seed)
  return str(lib.cbo_name_generate(seed or os.time()))
end

function Core.search(query)
  local n = tonumber(lib.cbo_session_search(query or "", idsBuf, cdef.MAX_SESSIONS))
  local t = {}
  for i = 0, n - 1 do
    t[#t + 1] = tonumber(idsBuf[i])
  end
  return t
end

-- LLM ------------------------------------------------------------------------

-- p.tools: neutral tool list [{name, description, parameters}] (function
-- calling); the core converts it to the provider's shape.
function Core.llmStart(p)
  local json = require("src.json")
  local messages = p.messagesJson or json.encode(p.messages or {})
  local req
  if p.tools and #p.tools > 0 then
    req = tonumber(
      lib.cbo_llm_start_tools(
        p.provider or "openai",
        p.apiKey or "",
        cstr(p.model),
        p.system or "",
        messages,
        json.encode(p.tools)
      )
    )
  else
    req = tonumber(
      lib.cbo_llm_start(
        p.provider or "openai",
        p.apiKey or "",
        cstr(p.model),
        p.system or "",
        messages
      )
    )
  end
  if req < 0 then
    return nil, Core.lastError()
  end
  return req
end

-- Function calls the model made (meaningful once the request is DONE):
-- [{id, name, arguments (JSON text), args (decoded table)}].
function Core.llmTakeCalls(req)
  local json = require("src.json")
  local calls = json.decode(str(lib.cbo_llm_take_calls(req))) or {}
  for _, c in ipairs(calls) do
    c.arguments = c.arguments or "{}"
    local args = json.decode(c.arguments)
    c.args = type(args) == "table" and args or {}
  end
  return calls
end

function Core.llmState(req)
  return tonumber(lib.cbo_llm_state(req))
end

function Core.llmTakeDelta(req)
  return str(lib.cbo_llm_take_delta(req))
end

function Core.llmError(req)
  return str(lib.cbo_llm_error(req))
end

function Core.llmCancel(req)
  lib.cbo_llm_cancel(req)
end

function Core.llmFree(req)
  lib.cbo_llm_free(req)
end

-- Utils ----------------------------------------------------------------------

function Core.utf8Width(s)
  return tonumber(lib.cbo_utf8_width(s or ""))
end

function Core.nowMs()
  return tonumber(lib.cbo_now_ms())
end

function Core.stateName(st)
  for k, v in pairs(cdef.ST) do
    if v == st then
      return k
    end
  end
  return "?"
end

-- Persistent services (unavailable in the visual mock).
function Core.recordEnabled()
  return not Core.mock and lib.cbo_record_enabled() ~= 0
end

function Core.setRecording(on)
  if not Core.mock then
    lib.cbo_record_enable(on and 1 or 0)
  end
end

function Core.kvGet(key)
  return not Core.mock and str(lib.cbo_kv_get(key)) or ""
end

function Core.kvSet(key, value)
  if Core.mock then
    return false
  end
  return lib.cbo_kv_set(key, tostring(value)) == 0
end

function Core.bracketedPaste(id)
  return not Core.mock and lib.cbo_term_bracketed_paste(id) ~= 0
end

function Core.paste(id, text)
  -- Strip control bytes, including ESC, so pasted text cannot break out of
  -- the bracketed-paste envelope. Newlines and tabs remain ordinary content.
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("[%z\1-\8\11-\31\127]", "")
  if Core.bracketedPaste(id) then
    text = "\27[200~" .. text .. "\27[201~"
  end
  Core.write(id, text)
end

function Core.recentCommands(hostId, limit)
  if Core.mock then
    return {}
  end
  return require("src.json").decode(str(lib.cbo_recent_commands(hostId or 0, limit or 20))) or {}
end

function Core.shutdown()
  if not Core.mock then
    lib.cbo_shutdown()
  end
end

function Core.dataDir()
  return not Core.mock and str(lib.cbo_data_dir()) or "(mock: in memory)"
end

local function decoded(value, fallback)
  return require("src.json").decode(str(value)) or fallback
end

function Core.hostUpsert(host)
  if Core.mock then
    return nil
  end
  local id = tonumber(lib.cbo_host_upsert(require("src.json").encode(host)))
  return id > 0 and id or nil
end

function Core.setHost(id, hostId)
  return not Core.mock and lib.cbo_session_set_host(id, hostId) == 0
end

function Core.historySearch(query, kinds, limit)
  if Core.mock then
    return {}
  end
  return decoded(lib.cbo_search_bm25(query or "", kinds or "", limit or 20), {})
end

-- Notes (AI panel note mode). The mock keeps them in memory so the UI and the
-- in-engine suite work without the core; the real core writes sqlite and
-- indexes them for BM25 (at once) and semantic search (background embedder).
local mockNotes, mockNoteId = {}, 0

function Core.noteAdd(text, sessionId)
  text = (text or ""):gsub("%s+$", "")
  if text:match("^%s*$") then
    return nil, "note is empty"
  end
  if Core.mock then
    mockNoteId = mockNoteId + 1
    local note = { id = mockNoteId, ts_ms = Core.nowMs(), text = text, session_id = sessionId or 0 }
    table.insert(mockNotes, 1, note)
    return note
  end
  local id = tonumber(lib.cbo_note_add(text, sessionId or 0))
  if id < 0 then
    return nil, str(lib.cbo_last_error())
  end
  return { id = id, ts_ms = Core.nowMs(), text = text, session_id = sessionId or 0 }
end

function Core.noteDelete(id)
  if Core.mock then
    for i, n in ipairs(mockNotes) do
      if n.id == id then
        table.remove(mockNotes, i)
        return true
      end
    end
    return false
  end
  return lib.cbo_note_delete(id) == 0
end

-- Newest first.
function Core.noteList(limit)
  if Core.mock then
    local out = {}
    for i = 1, math.min(#mockNotes, limit or 200) do
      out[i] = mockNotes[i]
    end
    return out
  end
  return decoded(lib.cbo_note_list(limit or 200), {})
end

-- Search hits [{id, title, snippet, ts_ms, score, sources}]. `semantic` adds
-- the embedding pass (network, only when indexing is enabled); off = BM25.
function Core.noteSearch(query, limit, semantic)
  query = query or ""
  if query:match("^%s*$") then
    return {}
  end
  if Core.mock then
    local out = {}
    local terms = {}
    for t in query:lower():gmatch("%S+") do
      if #t > 1 then
        terms[#terms + 1] = t
      end
    end
    if #terms == 0 then
      return {}
    end
    -- Like the hybrid pass, partial matches rank rather than vanish.
    for _, n in ipairs(mockNotes) do
      local hay = n.text:lower()
      local matched = 0
      for _, t in ipairs(terms) do
        if hay:find(t, 1, true) then
          matched = matched + 1
        end
      end
      if matched > 0 and (semantic or matched == #terms) then
        out[#out + 1] = {
          kind = "note",
          id = n.id,
          title = n.text:match("[^\n]*"),
          snippet = n.text,
          ts_ms = n.ts_ms,
          score = matched / #terms,
          sources = { "bm25" },
        }
      end
    end
    table.sort(out, function(a, b)
      return a.score > b.score
    end)
    for i = #out, (limit or 50) + 1, -1 do
      out[i] = nil
    end
    return out
  end
  local fn = semantic and lib.cbo_search or lib.cbo_search_bm25
  return decoded(fn(query, "note", limit or 50), {})
end

function Core.complete(hostId, prefix, limit)
  if Core.mock then
    return {}
  end
  return decoded(lib.cbo_complete(hostId or 0, prefix or "", limit or 10), {})
end

function Core.predictNext(hostId, limit)
  if Core.mock then
    return {}
  end
  return decoded(lib.cbo_predict_next(hostId or 0, limit or 10), {})
end

function Core.typing(id)
  return not Core.mock and str(lib.cbo_session_typing(id)) or ""
end

function Core.stats()
  return not Core.mock and decoded(lib.cbo_stats(), {}) or {}
end

function Core.inputSave(field, value, commit)
  return not Core.mock and lib.cbo_input_save(field, value, commit and 1 or 0) == 0
end
function Core.inputSearch(field, query)
  if Core.mock then
    return {}
  end
  return decoded(lib.cbo_input_search(field, query or "", 8), {})
end

function Core.saveDisplay(fullscreen, orientation)
  return not Core.mock and lib.cbo_display_save(fullscreen and 1 or 0, orientation) == 0
end

function Core.favoritesLoad()
  return not Core.mock and str(lib.cbo_favorites_load()) or ""
end
function Core.favoritesSave(text)
  return not Core.mock and lib.cbo_favorites_save(text) == 0
end

function Core.sessionsLoad()
  return not Core.mock and str(lib.cbo_sessions_load()) or ""
end
function Core.sessionsSave(text)
  return not Core.mock and lib.cbo_sessions_save(text) == 0
end

function Core.canComplete(id)
  return not Core.mock and lib.cbo_session_can_complete(id) ~= 0
end

-- Private JSONL stores (<data dir>/<name>.jsonl): API keys, the AI tool
-- registry. The mock keeps them in memory so the UI and tests work without
-- the dylib. rows: array of tables. Load returns rows or nil when absent.
local mockStores = {}

function Core.jsonlSave(name, rows)
  if Core.mock then
    mockStores[name] = require("src.json").decode(require("src.json").encode(rows or {})) or {}
    return true
  end
  local ok = lib.cbo_jsonl_save(name, require("src.json").encode({ rows = rows or {} })) == 0
  return ok, not ok and Core.lastError() or nil
end

function Core.jsonlLoad(name)
  if Core.mock then
    return mockStores[name]
  end
  local raw = str(lib.cbo_jsonl_load(name))
  if raw == "" then
    return nil
  end
  local t = require("src.json").decode(raw)
  return t and t.rows or nil
end

-- MCP server (Claude Code and other clients connect to the office). The mock
-- fakes a running server; Core.mockMcpPush feeds its inbox for tests.
local mockMcp = { running = false, url = "", port = 0, requests = 0, inbox = {}, session = -1 }

function Core.mcpStart(port)
  if Core.mock then
    mockMcp.running = true
    mockMcp.port = port and port > 0 and port or 8765
    mockMcp.url = "http://127.0.0.1:" .. mockMcp.port .. "/mcp/mocktoken"
    return true
  end
  local ok = lib.cbo_mcp_start(port or 0) == 0
  return ok, not ok and Core.lastError() or nil
end

function Core.mcpStop()
  if Core.mock then
    mockMcp.running, mockMcp.url = false, ""
    return
  end
  lib.cbo_mcp_stop()
end

function Core.mcpInfo()
  if Core.mock then
    return {
      running = mockMcp.running,
      url = mockMcp.url,
      port = mockMcp.port,
      requests = mockMcp.requests,
      inbox = #mockMcp.inbox,
      session = mockMcp.session,
      last_request_ms = 0,
      last_client = "",
    }
  end
  return decoded(lib.cbo_mcp_info(), { running = false, url = "" })
end

-- Inbox items since the last call: [{id, ts_ms, kind, text, title?}].
function Core.mcpTake()
  if Core.mock then
    local items = mockMcp.inbox
    mockMcp.inbox = {}
    return items
  end
  return decoded(lib.cbo_mcp_take(), {})
end

function Core.mcpSetSession(id)
  if Core.mock then
    mockMcp.session = id or -1
    return
  end
  lib.cbo_mcp_set_session(id or -1)
end

-- Test helper (mock only): what an MCP client would have sent.
function Core.mockMcpPush(kind, text, title)
  mockMcp.requests = mockMcp.requests + 1
  mockMcp.inbox[#mockMcp.inbox + 1] =
    { id = mockMcp.requests, ts_ms = Core.nowMs(), kind = kind, text = text, title = title }
end

return Core
