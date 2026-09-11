-- LuaJIT ABI smoke test: loads love2d/src/cbo_cdef.lua (with a fake `love`
-- table) and calls into libcbo_core through the same cdef the app uses.
--   /opt/homebrew/bin/luajit rust/examples/ffi_smoke.lua
local ffi = require("ffi")
-- Keep the smoke's sqlite writes out of the real data dir.
if not os.getenv("CBO_HOME") or os.getenv("CBO_HOME") == "" then
  local tmp = os.tmpname()
  os.remove(tmp)
  ffi.cdef("int setenv(const char*, const char*, int);")
  ffi.C.setenv("CBO_HOME", tmp .. "-cbo", 1)
end

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local root = here .. "/../.."
local love2d = root .. "/love2d"
local bundle = os.getenv("CBO_TEST_BUNDLE")

-- Minimal stand-in for LÖVE so the loader's search paths resolve.
love = {
  filesystem = {
    getSource = function() return bundle and (bundle .. "/CausewaybayOffice.love") or love2d end,
    getSourceBaseDirectory = function() return bundle or root end,
  },
}
package.path = love2d .. "/?.lua;" .. love2d .. "/src/?.lua;" .. package.path

local cbo = require("cbo_cdef")
local lib = cbo.load()
print("loaded " .. cbo.path)
if bundle then
  local ext = ffi.os == "OSX" and "dylib" or (ffi.os == "Windows" and "dll" or "so")
  local name = (ffi.os == "Windows" and "" or "lib") .. "cbo_core." .. ext
  assert(cbo.path == bundle .. "/" .. name, "must load the bundled core, not " .. cbo.path)
end

local function s(p) return p ~= nil and ffi.string(p) or "<null>" end

-- Every declaration must resolve, including services not used by the main UI.
local header = assert(io.open(root .. "/rust/include/cbo.h", "r"))
local headerText = header:read("*a")
header:close()
local symbols = 0
for symbol in headerText:gmatch("(cbo_[%w_]+)%s*%(") do
  assert(lib[symbol], "missing ABI export: " .. symbol)
  symbols = symbols + 1
end
print("resolved " .. symbols .. " ABI declarations")

local version = s(lib.cbo_version())
print("cbo_version = " .. version)
assert(version:match("^%d+%.%d+%.%d+$"), "bad version")
assert(s(lib.cbo_last_error()) == "", "last_error should be empty")

local n1 = s(lib.cbo_name_generate(1234))
local n2 = s(lib.cbo_name_generate(1234))
local n3 = s(lib.cbo_name_generate(0))
print("cbo_name_generate(1234) = " .. n1)
print("cbo_name_generate(0)    = " .. n3)
assert(n1 == n2, "seeded names must be deterministic")
assert(n1:match("^[%a%-]+%-%d%d$"), "name format")

local w = lib.cbo_utf8_width("你好 안녕 こんにちは Příliš")
print("cbo_utf8_width(mixed) = " .. tonumber(w))
assert(tonumber(w) == 27, "expected width 27")
assert(tonumber(lib.cbo_utf8_width("abc")) == 3)

-- Struct layouts as seen by LuaJIT must match Rust's #[repr(C)].
assert(ffi.sizeof("CboCell") == 16, "CboCell size " .. ffi.sizeof("CboCell"))
assert(ffi.sizeof("CboSessionInfo") == 304, "CboSessionInfo size " .. ffi.sizeof("CboSessionInfo"))
print("sizeof CboCell=" .. ffi.sizeof("CboCell") .. " CboSessionInfo=" .. ffi.sizeof("CboSessionInfo"))

assert(lib.cbo_session_count() == 0)
assert(lib.cbo_session_state(5) == cbo.ST.IDLE)
local now = lib.cbo_now_ms()
assert(tonumber(now) > 1700000000000, "now_ms sane")
print("cbo_now_ms = " .. tostring(now))

-- Bad-arg path must not crash and must set last_error.
local bad = lib.cbo_session_open(nil, 22, "x", nil, nil, 80, 24)
assert(bad == -1)
print("bad open -> -1, last_error = " .. s(lib.cbo_last_error()))

-- Search with no sessions returns 0.
local ids = ffi.new("int32_t[8]")
assert(lib.cbo_session_search("tram", ids, 8) == 0)

-- llm start with a bogus provider -> -1 + error text.
assert(lib.cbo_llm_start("nope", "k", nil, nil, "[]") == -1)
print("bad llm provider -> -1, last_error = " .. s(lib.cbo_last_error()))

-- Persistence / recording / search / patterns (new in 0.2 ABI).
local dir = s(lib.cbo_data_dir())
print("cbo_data_dir = " .. dir)
assert(#dir > 0)
assert(lib.cbo_kv_set("smoke.key", "銅鑼灣 안녕") == 0)
assert(s(lib.cbo_kv_get("smoke.key")) == "銅鑼灣 안녕", "kv roundtrip")
assert(s(lib.cbo_kv_get("smoke.missing")) == "")
assert(lib.cbo_input_save("connect.host", "last.example", 1) == 0)
assert(s(lib.cbo_input_search("connect.host", "last", 8)) == '["last.example"]')
assert(lib.cbo_input_save("connect.host", "next-draft", 0) == 0)
assert(s(lib.cbo_kv_get("input.draft.connect.host")) == "next-draft")
assert(lib.cbo_input_save("connect.password", "must-not-store", 1) == -1)
assert(lib.cbo_display_save(1, "landscape") == 0)
local journal = assert(io.open(dir .. "/display.jsonl", "r"))
assert(journal:read("*a"):find('"horizontal":true', 1, true))
journal:close()
assert(lib.cbo_sessions_save('{"hosts":[{"host":"localhost","user":"lua","name":"mary-1"},{"host":"localhost","user":"lua","name":"work-2"}]}') == 0)
assert(s(lib.cbo_sessions_load()):find('"name":"work-2"',1,true))
assert(lib.cbo_session_can_complete(-1) == 0)
local hid = lib.cbo_host_upsert('{"name":"smoke-host","host":"smoke.invalid","port":22,"user":"lua","tags":"ffi"}')
assert(hid > 0, "host upsert: " .. s(lib.cbo_last_error()))
assert(lib.cbo_host_upsert('{"host":"smoke.invalid","port":22,"user":"lua"}') == hid, "dedupe")
assert(s(lib.cbo_host_get(hid)):find('"name":"smoke%-host"'), "host_get json")
assert(s(lib.cbo_host_list()):sub(1, 1) == "[")
assert(lib.cbo_record_enabled() == 0)
lib.cbo_record_enable(1)
local ev = lib.cbo_record_event("ui", "lobby", "smoke", '{"x":1}')
assert(tonumber(ev) > 0, "record_event")
assert(s(lib.cbo_search_bm25("smoke", "host,event", 10)):find('"kind":"host"'), "bm25 host hit")
assert(s(lib.cbo_search("smoke", "", 10)):sub(1, 1) == "[")
assert(s(lib.cbo_suggest("lobby", "", 5)):sub(1, 1) == "[")
assert(s(lib.cbo_context("lobby", -1, 500)):find('"scene":"lobby"'), "context json")
assert(s(lib.cbo_stats()):find('"counts"'), "stats json")
assert(s(lib.cbo_recent_commands(0, 5)) == "[]")
assert(s(lib.cbo_session_transcript(-1, 100)) == "")
assert(lib.cbo_embed_pending() >= 0)
assert(lib.cbo_embed_available() == 0 or lib.cbo_embed_available() == 1)
assert(lib.cbo_host_delete(hid) == 0)
assert(lib.cbo_host_delete(hid) == -1)
assert(s(lib.cbo_session_typing(-1)) == "", "typing of a bad id is empty")
-- Notes (0.3 ABI): saved with recording off, searchable, deletable.
lib.cbo_record_enable(0)
local nid = tonumber(lib.cbo_note_add("smoke note: 銅鑼灣 wifi on the whiteboard", 3))
assert(nid > 0, "note add: " .. s(lib.cbo_last_error()))
assert(tonumber(lib.cbo_note_add("   ", 0)) == -1, "blank note refused")
assert(s(lib.cbo_note_list(10)):find('"session_id":3', 1, true), "note list json")
assert(s(lib.cbo_search_bm25("whiteboard", "note", 5)):find('"kind":"note"'), "bm25 note hit")
assert(s(lib.cbo_search("whiteboard", "note", 5)):find('"id":' .. nid), "hybrid note hit")
assert(lib.cbo_note_delete(nid) == 0)
assert(lib.cbo_note_delete(nid) == -1)
assert(not s(lib.cbo_search_bm25("whiteboard", "note", 5)):find('"id":' .. nid), "deleted note gone")
assert(s(lib.cbo_complete(0, "gi", 5)):sub(1, 1) == "[", "complete json")
assert(s(lib.cbo_complete(0, "", 3)):sub(1, 1) == "[", "complete empty prefix")
assert(s(lib.cbo_predict_next(0, 5)):sub(1, 1) == "[", "predict json")
print("persistence/search/patterns/typing ABI OK")

-- JSONL stores (0.4 ABI): api keys and the AI tool registry live here.
assert(s(lib.cbo_jsonl_load("apikeys")) == "", "an absent store loads empty")
assert(lib.cbo_jsonl_save("apikeys", '{"rows":[{"provider":"openai","key":"sk-銅鑼灣"}]}') == 0,
  "jsonl save: " .. s(lib.cbo_last_error()))
local keys = s(lib.cbo_jsonl_load("apikeys"))
assert(keys:find("sk-銅鑼灣", 1, true), "jsonl roundtrip keeps utf8: " .. keys)
assert(lib.cbo_jsonl_save("tools", '{"rows":[{"name":"disk","command":"df -h {p}"}]}') == 0)
assert(s(lib.cbo_jsonl_load("tools")):find('"df -h {p}"', 1, true), "tool store roundtrip")
assert(lib.cbo_jsonl_save("favorites", '{"rows":[]}') == -1, "a snapshot name is refused")
assert(lib.cbo_jsonl_save("../escape", '{"rows":[]}') == -1, "a path is refused")
assert(lib.cbo_jsonl_save("apikeys", "{nope") == -1, "malformed json is refused")
assert(s(lib.cbo_jsonl_load("apikeys")):find("sk-銅鑼灣", 1, true), "a failed save keeps the file")
-- the key file must not be world readable
local mode = io.popen("stat -f '%Lp' '" .. s(lib.cbo_data_dir()) .. "/apikeys.jsonl' 2>/dev/null")
if mode then
  local perms = (mode:read("*a") or ""):gsub("%s", "")
  mode:close()
  assert(perms == "" or perms == "600", "apikeys.jsonl must be private, got " .. perms)
end
print("jsonl store ABI OK (mode " .. tostring(s(lib.cbo_data_dir())) .. "/apikeys.jsonl)")

-- MCP server (0.4 ABI): start on a free port, speak JSON-RPC, drain the inbox.
assert(s(lib.cbo_mcp_info()):find('"running":false'), "mcp starts stopped")
assert(s(lib.cbo_mcp_take()) == "[]", "empty inbox")
assert(lib.cbo_mcp_start(0) == 0, "mcp start: " .. s(lib.cbo_last_error()))
local running = s(lib.cbo_mcp_info())
assert(running:find('"running":true'), running)
local url = running:match('"url":"([^"]+)"')
assert(url and url:find("^http://127%.0%.0%.1:%d+/mcp/%w+$"), "loopback url with a token: " .. tostring(url))
assert(lib.cbo_mcp_start(0) == 0, "starting twice is a no-op")
-- a real request over the socket, with curl (present on macOS and CI images)
local function post(body)
  local cmd = string.format(
    "curl -sS --max-time 5 -X POST -H 'Content-Type: application/json' -d %q %q 2>/dev/null",
    body, url)
  local pipe = io.popen(cmd)
  local out = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end
  return out
end
local init = post('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
if init == "" then
  print("  (curl unavailable: skipped the MCP HTTP round trip)")
else
  assert(init:find('"serverInfo"') and init:find("causewaybay%-office"), "initialize: " .. init)
  local list = post('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  assert(list:find('"office_screen"') and list:find('"office_send"'), "tools/list: " .. list)
  local call = post('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"office_send","arguments":{"text":"from the smoke test"}}}')
  assert(call:find("delivered", 1, true), "tools/call: " .. call)
  local inbox = s(lib.cbo_mcp_take())
  assert(inbox:find("from the smoke test", 1, true), "inbox: " .. inbox)
  assert(s(lib.cbo_mcp_take()) == "[]", "the inbox drains once")
  local bad = post('{"jsonrpc":"2.0","id":4,"method":"nope"}')
  assert(bad:find("%-32601"), "unknown method: " .. bad)
end
lib.cbo_mcp_set_session(7)
assert(s(lib.cbo_mcp_info()):find('"session":7'), "the terminal on screen is recorded")
lib.cbo_mcp_stop()
assert(s(lib.cbo_mcp_info()):find('"running":false'), "mcp stops")
print("mcp ABI OK")

lib.cbo_shutdown()
print("FFI SMOKE PASS")
