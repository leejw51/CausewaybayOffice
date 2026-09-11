-- Mock core: same surface as the FFI lib (cbo_* functions) so src/core.lua can
-- wrap either one. Fake sessions "connect" after 0.6s, echo typed lines, answer
-- `ls`, print a CJK/Czech banner, ping every keepalive interval, and a fake LLM
-- streams lorem text. No networking, no dylib.

local ffi = require("ffi")
local utf8 = require("utf8")
require("src.cbo_cdef") -- for the CboCell / CboSessionInfo cdefs

local M = {}
M.MAX = 128

local ST = { IDLE = 0, CONNECTING = 1, CONNECTED = 2, CLOSED = 3, ERROR = 4 }
local LLM = { PENDING = 0, STREAMING = 1, DONE = 2, ERROR = 3 }

local DEFAULT_FG = 0xD0D0C8
local DEFAULT_BG = 0x101830
local RUST = 0xDB6644
local CYAN = 0x66DBF0
local GREEN = 0x73D07C
local YELLOW = 0xDED187

local sessions = {} -- id -> session
local llms = {} -- req -> request
local clock = 0
local lastErr = ""

local ADJ = {
  "neon",
  "jade",
  "dimsum",
  "misty",
  "velvet",
  "rusty",
  "golden",
  "harbour",
  "typhoon",
  "lantern",
  "bamboo",
  "crimson",
  "silver",
  "sleepy",
  "electric",
  "mango",
  "pearl",
  "lucky",
}
local NOUN = {
  "tram",
  "junk",
  "ferry",
  "noodle",
  "taxi",
  "wonton",
  "minibus",
  "pineapple",
  "dragon",
  "skyline",
  "octopus",
  "lift",
  "signboard",
  "mahjong",
  "egg-tart",
  "milk-tea",
  "cha-chaan",
}

-- Unicode East Asian Width (wide/fullwidth) — good enough for the mock.
function M.cpWidth(cp)
  if cp == 0 then
    return 0
  end
  if cp < 0x300 then
    return 1
  end
  if (cp >= 0x300 and cp <= 0x36F) or (cp >= 0x200B and cp <= 0x200F) then
    return 0
  end
  if
    (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0x303E)
    or (cp >= 0x3041 and cp <= 0x33FF)
    or (cp >= 0x3400 and cp <= 0x4DBF)
    or (cp >= 0x4E00 and cp <= 0x9FFF)
    or (cp >= 0xA000 and cp <= 0xA4CF)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE30 and cp <= 0xFE4F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x1F300 and cp <= 0x1F64F)
    or (cp >= 0x1F900 and cp <= 0x1F9FF)
    or (cp >= 0x20000 and cp <= 0x3FFFD)
  then
    return 2
  end
  return 1
end

local function strWidth(s)
  local w = 0
  for _, cp in utf8.codes(s) do
    w = w + M.cpWidth(cp)
  end
  return w
end

-- Screen model ---------------------------------------------------------------

local function newCell(cp, fg, bg, attr, width)
  return {
    cp = cp or 0,
    fg = fg or DEFAULT_FG,
    bg = bg or DEFAULT_BG,
    attr = attr or 0,
    width = width or 1,
  }
end

local function blankLine(cols)
  local l = {}
  for i = 1, cols do
    l[i] = newCell(0)
  end
  return l
end

local function newScreen(cols, rows)
  local s = {
    cols = cols,
    rows = rows,
    lines = {},
    scrollback = {},
    cx = 0,
    cy = 0,
    fg = DEFAULT_FG,
    bg = DEFAULT_BG,
    attr = 0,
  }
  for r = 1, rows do
    s.lines[r] = blankLine(cols)
  end
  return s
end

local function scrollUp(s)
  s.scrollback[#s.scrollback + 1] = table.remove(s.lines, 1)
  if #s.scrollback > 2000 then
    table.remove(s.scrollback, 1)
  end
  s.lines[#s.lines + 1] = blankLine(s.cols)
end

local function newline(s)
  s.cx = 0
  s.cy = s.cy + 1
  if s.cy >= s.rows then
    s.cy = s.rows - 1
    scrollUp(s)
  end
end

local function putCp(s, cp)
  local w = M.cpWidth(cp)
  if w == 0 then
    return
  end
  if s.cx + w > s.cols then
    newline(s)
  end
  local line = s.lines[s.cy + 1]
  line[s.cx + 1] = newCell(cp, s.fg, s.bg, s.attr, w)
  if w == 2 then
    line[s.cx + 2] = newCell(0, s.fg, s.bg, s.attr, 0)
  end
  s.cx = s.cx + w
end

local function backspace(s)
  if s.cx > 0 then
    local line = s.lines[s.cy + 1]
    local c = line[s.cx]
    if c and c.width == 0 and s.cx > 1 then
      line[s.cx] = newCell(0)
      s.cx = s.cx - 1
    end
    line[s.cx] = newCell(0)
    s.cx = s.cx - 1
  end
end

local function puts(s, str, fg, attr)
  local sfg, sattr = s.fg, s.attr
  s.fg = fg or sfg
  s.attr = attr or sattr
  for _, cp in utf8.codes(str) do
    if cp == 10 then
      newline(s)
    elseif cp == 13 then
      s.cx = 0
    else
      putCp(s, cp)
    end
  end
  s.fg, s.attr = sfg, sattr
end

-- Sessions -------------------------------------------------------------------

local function nowMs()
  return math.floor(clock * 1000)
end

local function findFree()
  for id = 0, M.MAX - 1 do
    if not sessions[id] then
      return id
    end
  end
  return -1
end

local function prompt(sess)
  puts(sess.screen, sess.user .. "@" .. sess.host:gsub("%..*$", ""), GREEN, 1)
  puts(sess.screen, ":", DEFAULT_FG)
  puts(sess.screen, "~", CYAN, 1)
  puts(sess.screen, "$ ", DEFAULT_FG)
  sess.gen = sess.gen + 1
end

local FAKE_LS = {
  { "Cargo.toml", YELLOW, 0 },
  { "src", CYAN, 1 },
  { "target", CYAN, 1 },
  { "README.md", DEFAULT_FG, 0 },
  { "love2d", CYAN, 1 },
  { "docs", CYAN, 1 },
  { "python", CYAN, 1 },
  { "VERSION", DEFAULT_FG, 0 },
}

local function runCommand(sess, line)
  local s = sess.screen
  local cmd, rest = line:match("^%s*(%S+)%s*(.*)$")
  if not cmd then
    -- empty line
  elseif cmd == "ls" then
    local x = 0
    for _, f in ipairs(FAKE_LS) do
      local pad = f[1] .. string.rep(" ", 14 - #f[1])
      if x + 14 > s.cols then
        newline(s)
        x = 0
      end
      puts(s, pad, f[2], f[3])
      x = x + 14
    end
    newline(s)
  elseif cmd == "echo" then
    puts(s, rest .. "\n")
  elseif cmd == "clear" then
    for r = 1, s.rows do
      s.lines[r] = blankLine(s.cols)
    end
    s.cx, s.cy = 0, 0
    sess.placements = {}
    sess.images = {}
  elseif cmd == "exit" or cmd == "logout" then
    puts(s, "logout\n", DEFAULT_FG, 32)
    sess.state = ST.CLOSED
    return
  elseif cmd == "bell" then
    sess.bells = sess.bells + 1
  elseif cmd == "pwd" then
    puts(s, (sess.cwd or ("/home/" .. sess.user)) .. "\n")
  elseif cmd == "cd" then
    local dir = rest:gsub("'", ""):match("^(%S*)")
    if dir == "" or dir == "~" then
      sess.cwd = nil
    elseif dir:sub(1, 1) == "/" then
      sess.cwd = dir
    else
      sess.cwd = (sess.cwd or ("/home/" .. sess.user)) .. "/" .. dir
    end
  elseif cmd == "uname" then
    puts(s, "Darwin\n")
  elseif cmd == "whoami" then
    puts(s, sess.user .. "\n")
  elseif cmd == "date" then
    puts(s, os.date("%a %b %d %H:%M:%S HKT %Y") .. "\n")
  elseif cmd == "banner" then
    puts(s, "你好 안녕 こんにちは Příliš žluťoučký kůň\n", YELLOW)
  elseif cmd == "icat" then
    -- a 64x32 RGBA sprite: rust square, cyan diagonal, yellow frame
    local w, h = 64, 32
    local px = {}
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local r, g, b = 0xB7, 0x41, 0x0E
        if x < 2 or y < 2 or x >= w - 2 or y >= h - 2 then
          r, g, b = 0xE8, 0xC5, 0x47
        elseif math.abs(x - y * 2) < 3 then
          r, g, b = 0x3F, 0xC1, 0xC9
        end
        px[#px + 1] = string.char(r, g, b, 255)
      end
    end
    M.mock_image_show(sess.id, { width = w, height = h, format = 32, data = table.concat(px) })
    newline(s)
  elseif cmd == "top" then
    puts(s, "Processes: 412 total, 2 running, 410 sleeping\n", CYAN, 1)
    puts(s, "  PID COMMAND      %CPU MEM\n", DEFAULT_FG, 8)
    puts(s, "  512 love         12.4 180M\n")
    puts(s, "  731 cbo_core      1.1  22M\n")
    puts(s, "  900 rust-analyzer 8.8 900M\n")
  else
    puts(s, "zsh: command not found: " .. cmd .. "\n", RUST)
  end
end

local function feed(sess, bytes)
  local s = sess.screen
  local i = 1
  local n = #bytes
  while i <= n do
    local b = bytes:byte(i)
    if b == 13 or b == 10 then
      newline(s)
      local line = sess.lineBuf
      sess.lineBuf = ""
      runCommand(sess, line)
      if sess.state == ST.CONNECTED then
        prompt(sess)
      end
      i = i + 1
    elseif b == 127 or b == 8 then
      if #sess.lineBuf > 0 then
        -- drop last utf8 char
        local cut = #sess.lineBuf
        while cut > 1 and sess.lineBuf:byte(cut) >= 0x80 and sess.lineBuf:byte(cut) < 0xC0 do
          cut = cut - 1
        end
        sess.lineBuf = sess.lineBuf:sub(1, cut - 1)
        backspace(s)
      end
      i = i + 1
    elseif b == 3 then -- ctrl-c
      puts(s, "^C\n")
      sess.lineBuf = ""
      prompt(sess)
      i = i + 1
    elseif b == 12 then -- ctrl-l
      runCommand(sess, "clear")
      prompt(sess)
      i = i + 1
    elseif b == 27 then
      -- swallow CSI / SS3 sequences
      local j = i + 1
      local c = bytes:sub(j, j)
      if c == "[" or c == "O" then
        j = j + 1
        while j <= n and not bytes:sub(j, j):match("[%a~]") do
          j = j + 1
        end
      end
      i = j + 1
    elseif b < 32 then
      i = i + 1
    else
      -- one utf8 sequence
      local len = 1
      if b >= 0xF0 then
        len = 4
      elseif b >= 0xE0 then
        len = 3
      elseif b >= 0xC0 then
        len = 2
      end
      local ch = bytes:sub(i, i + len - 1)
      sess.lineBuf = sess.lineBuf .. ch
      puts(s, ch)
      i = i + len
    end
  end
  sess.gen = sess.gen + 1
  sess.lastActivity = nowMs()
end

local function greet(sess)
  local s = sess.screen
  puts(s, "Last login: " .. os.date("%a %b %d %H:%M:%S") .. " on ttys004\n", DEFAULT_FG, 32)
  puts(s, "  CAUSEWAYBAY OFFICE mock host  ", DEFAULT_FG, 8)
  puts(s, " [" .. sess.host .. "]\n", CYAN)
  puts(s, "你好 안녕 こんにちは Příliš žluťoučký kůň\n", YELLOW)
  puts(s, "type: ls  echo  top  banner  bell  clear  exit\n", DEFAULT_FG, 32)
  prompt(sess)
end

function M.cbo_init() end

function M.cbo_version()
  return "mock-0.1.1"
end

function M.cbo_last_error()
  return lastErr
end

function M.cbo_session_open(host, port, user, password, keypath, cols, rows)
  local id = findFree()
  if id < 0 then
    lastErr = "session limit reached"
    return -1
  end
  if not host or host == "" then
    lastErr = "empty host"
    return -1
  end
  cols = math.max(2, cols or 80)
  rows = math.max(1, rows or 24)
  sessions[id] = {
    id = id,
    host = host,
    port = port or 22,
    user = user or "guest",
    password = password,
    keypath = keypath,
    state = ST.CONNECTING,
    connectAt = clock + 0.6,
    screen = newScreen(cols, rows),
    name = "",
    gen = 1,
    bells = 0,
    lineBuf = "",
    images = {},
    placements = {},
    imageKey = 0,
    created = nowMs(),
    lastActivity = nowMs(),
    lastPing = 0,
    keepalive = 15,
    nextPing = 0,
    scroll = 0,
    err = "",
  }
  if host == "fail.invalid" then
    sessions[id].failAt = clock + 0.8
    sessions[id].connectAt = math.huge
  end
  return id
end

function M.cbo_session_state(id)
  local s = sessions[id]
  return s and s.state or -1
end

function M.cbo_session_error(id)
  local s = sessions[id]
  return s and s.err or "bad id"
end

function M.cbo_session_info(id, out)
  local s = sessions[id]
  if not s then
    return -1
  end
  out.id = id
  out.state = s.state
  out.cols = s.screen.cols
  out.rows = s.screen.rows
  out.port = s.port
  out.created_ms = s.created
  out.last_activity_ms = s.lastActivity
  out.last_ping_ms = s.lastPing
  out.generation = s.gen
  ffi.copy(out.name, s.name:sub(1, 63))
  ffi.copy(out.host, s.host:sub(1, 127))
  ffi.copy(out.user, s.user:sub(1, 63))
  return 0
end

function M.cbo_session_count()
  local n = 0
  for _ in pairs(sessions) do
    n = n + 1
  end
  return n
end

function M.cbo_session_ids(out, cap)
  local n = 0
  for id = 0, M.MAX - 1 do
    if sessions[id] and n < cap then
      out[n] = id
      n = n + 1
    end
  end
  return n
end

function M.cbo_session_write(id, bytes, len)
  local s = sessions[id]
  if not s or s.state ~= ST.CONNECTED then
    return
  end
  if type(bytes) ~= "string" then
    bytes = ffi.string(bytes, len)
  end
  feed(s, bytes)
end

function M.cbo_session_resize(id, cols, rows)
  local s = sessions[id]
  if not s then
    return
  end
  local sc = s.screen
  cols, rows = math.max(2, cols), math.max(1, rows)
  if sc.cols == cols and sc.rows == rows then
    return
  end
  -- naive: pad/crop lines, keep the cursor in range
  for r = 1, math.max(rows, #sc.lines) do
    local line = sc.lines[r] or blankLine(cols)
    for c = #line + 1, cols do
      line[c] = newCell(0)
    end
    for c = #line, cols + 1, -1 do
      line[c] = nil
    end
    sc.lines[r] = line
  end
  while #sc.lines > rows do
    if sc.cy >= rows then
      sc.scrollback[#sc.scrollback + 1] = table.remove(sc.lines, 1)
      sc.cy = sc.cy - 1
    else
      table.remove(sc.lines)
    end
  end
  sc.cols, sc.rows = cols, rows
  sc.cx = math.min(sc.cx, cols - 1)
  sc.cy = math.min(sc.cy, rows - 1)
  s.gen = s.gen + 1
end

function M.cbo_session_close(id)
  local s = sessions[id]
  if s and s.state ~= ST.ERROR then
    s.state = ST.CLOSED
    s.gen = s.gen + 1
  end
end

function M.cbo_session_free(id)
  local s = sessions[id]
  if s and (s.state == ST.CLOSED or s.state == ST.ERROR) then
    sessions[id] = nil
  end
end

function M.cbo_session_set_name(id, name)
  local s = sessions[id]
  if not s then
    return -1
  end
  if type(name) ~= "string" then
    name = ffi.string(name)
  end
  if utf8.len(name) == nil or utf8.len(name) > 32 then
    lastErr = "name too long"
    return -1
  end
  s.name = name
  return 0
end

function M.cbo_session_get_name(id)
  local s = sessions[id]
  return s and s.name or ""
end

function M.cbo_session_set_keepalive(id, seconds)
  local s = sessions[id]
  if s then
    s.keepalive = seconds
    s.nextPing = clock + seconds
  end
end

function M.cbo_session_reconnect(id)
  local s = sessions[id]
  if not s then
    return -1
  end
  s.state = ST.CONNECTING
  s.connectAt = clock + 0.6
  s.err = ""
  s.screen = newScreen(s.screen.cols, s.screen.rows)
  s.lineBuf = ""
  s.gen = s.gen + 1
  return 0
end

-- Terminal -------------------------------------------------------------------

function M.cbo_term_snapshot(id, out, cap)
  local s = sessions[id]
  if not s then
    return 0
  end
  local sc = s.screen
  local n = 0
  local off = s.scroll
  local total = #sc.scrollback
  for r = 1, sc.rows do
    local src = r - off
    local line
    if src >= 1 then
      line = sc.lines[src]
    else
      line = sc.scrollback[total + src]
    end
    for c = 1, sc.cols do
      if n >= cap then
        return n
      end
      local cell = line and line[c]
      local o = out[n]
      if cell then
        o.cp, o.fg, o.bg, o.attr, o.width = cell.cp, cell.fg, cell.bg, cell.attr, cell.width
      else
        o.cp, o.fg, o.bg, o.attr, o.width = 0, DEFAULT_FG, DEFAULT_BG, 0, 1
      end
      n = n + 1
    end
  end
  return n
end

function M.cbo_term_generation(id)
  local s = sessions[id]
  return s and s.gen or 0
end

function M.cbo_term_cursor(id, x, y, visible)
  local s = sessions[id]
  if not s then
    x[0], y[0], visible[0] = 0, 0, 0
    return
  end
  x[0], y[0] = s.screen.cx, s.screen.cy
  visible[0] = (s.scroll == 0 and s.state == ST.CONNECTED) and 1 or 0
end

function M.cbo_term_title(id)
  local s = sessions[id]
  return s and (s.user .. "@" .. s.host) or ""
end

function M.cbo_term_cwd(id)
  local s = sessions[id]
  return s and s.cwd or ""
end

function M.cbo_term_take_bell(id)
  local s = sessions[id]
  if not s then
    return 0
  end
  local n = s.bells
  s.bells = 0
  return n
end

function M.cbo_term_scroll(id, offset)
  local s = sessions[id]
  if s then
    s.scroll = math.max(0, math.min(offset, #s.screen.scrollback))
    s.gen = s.gen + 1
  end
end

function M.cbo_term_scroll_offset(id)
  local s = sessions[id]
  return s and s.scroll or 0
end

function M.cbo_term_scrollback_len(id)
  local s = sessions[id]
  return s and #s.screen.scrollback or 0
end

-- Images (kitty graphics protocol). The mock shell's `icat` command stores a
-- generated sprite and places it at the cursor, exactly like the core does
-- for a real `ESC _ G a=T ... ESC \` sequence.

function M.cbo_term_set_cell_px(id, w, h)
  local s = sessions[id]
  if s then
    s.cellW, s.cellH = w, h
  end
end

function M.cbo_term_placements(id, out, cap)
  local s = sessions[id]
  if not s then
    return 0
  end
  local top = #s.screen.scrollback - s.scroll
  local n = 0
  for _, p in ipairs(s.placements) do
    local row = p.line - top
    if row + p.rows > 0 and row < s.screen.rows and n < cap then
      local o = out[n]
      o.image_key, o.image_id, o.placement_id = p.key, p.image_id, p.placement_id
      o.col, o.row, o.cols, o.rows, o.z = p.col, row, p.cols, p.rows, p.z
      o.src_x, o.src_y, o.src_w, o.src_h = 0, 0, p.image.width, p.image.height
      n = n + 1
    end
  end
  return n
end

function M.cbo_term_image_info(id, key, out)
  local s = sessions[id]
  local im = s and s.images[tonumber(key)]
  if not im then
    return -1
  end
  out.key, out.width, out.height = key, im.width, im.height
  out.bytes, out.format, out.compressed = #im.data, im.format, im.compressed and 1 or 0
  return 0
end

function M.cbo_term_image_data(id, key, out, cap)
  local s = sessions[id]
  local im = s and s.images[tonumber(key)]
  if not im then
    return 0
  end
  local n = math.min(#im.data, cap)
  require("ffi").copy(out, im.data, n)
  return n
end

-- Store an image and place it at the cursor; returns the key. Used by the
-- mock `icat` command and by tests (format 24/32 raw or 100 PNG).
function M.mock_image_show(id, image)
  local s = sessions[id]
  if not s then
    return nil
  end
  local sc = s.screen
  s.imageKey = s.imageKey + 1
  local key = s.imageKey
  s.images[key] = image
  local cw, ch = s.cellW or 8, s.cellH or 16
  local cols = image.cols or math.max(1, math.ceil(image.width / cw))
  local rows = image.rows or math.max(1, math.ceil(image.height / ch))
  s.placements[#s.placements + 1] = {
    key = key,
    image = image,
    image_id = image.id or 0,
    placement_id = 0,
    line = #sc.scrollback + sc.cy,
    col = sc.cx,
    cols = cols,
    rows = rows,
    z = image.z or 0,
  }
  for _ = 2, rows do
    newline(sc)
  end
  sc.cx = math.min(sc.cols - 1, sc.cx + cols)
  s.gen = s.gen + 1
  return key
end

-- Names / search -------------------------------------------------------------

local function liveNames()
  local t = {}
  for _, s in pairs(sessions) do
    t[s.name] = true
  end
  return t
end

function M.cbo_name_generate(seed)
  seed = tonumber(seed) or 0
  local taken = liveNames()
  for tries = 0, 500 do
    local x = (seed + tries * 7919) % 2147483647
    local a = ADJ[(x % #ADJ) + 1]
    local n = NOUN[(math.floor(x / #ADJ) % #NOUN) + 1]
    local num = math.floor(x / 97) % 100
    local name = string.format("%s-%s-%02d", a, n, num)
    if not taken[name] then
      return name
    end
  end
  return "session-" .. tostring(seed)
end

local function fuzzyScore(q, s)
  q, s = q:lower(), s:lower()
  if q == "" then
    return 1
  end
  local pos = s:find(q, 1, true)
  if pos then
    return 100 - pos
  end
  local qi, score, last = 1, 0, 0
  for i = 1, #s do
    if qi <= #q and s:sub(i, i) == q:sub(qi, qi) then
      score = score + (i == last + 1 and 3 or 1)
      last = i
      qi = qi + 1
    end
  end
  if qi <= #q then
    return 0
  end
  return score
end

function M.cbo_session_search(query, out, cap)
  if type(query) ~= "string" then
    query = ffi.string(query)
  end
  local hits = {}
  for id, s in pairs(sessions) do
    local sc = fuzzyScore(query, s.name .. " " .. s.host .. " " .. s.user)
    if sc > 0 then
      hits[#hits + 1] = { id = id, score = sc }
    end
  end
  table.sort(hits, function(a, b)
    if a.score == b.score then
      return a.id < b.id
    end
    return a.score > b.score
  end)
  local n = 0
  for _, h in ipairs(hits) do
    if n >= cap then
      break
    end
    out[n] = h.id
    n = n + 1
  end
  return n
end

-- LLM ------------------------------------------------------------------------

local LOREM =
  "Sure. First, check the process list:\n\n  ps aux | grep love\n\nThen tail the log while you reproduce it:\n\n  tail -f ~/Library/Logs/cbo.log\n\nIf the socket is stuck, `lsof -i :22` shows who holds it. 香港加油 — ship it before the typhoon signal goes up. Příliš žluťoučký kůň úpěl ďábelské ódy."

-- The core hands Lua the calls as JSON where `arguments` is itself a JSON
-- *string*; build that through the encoder instead of escaping a literal.
local function mockCalls(calls)
  local json = require("src.json")
  local rows = {}
  for i, c in ipairs(calls) do
    rows[i] = { id = c.id, name = c.name, arguments = json.encode(c.args) }
  end
  return json.encode(rows)
end

function M.cbo_llm_start(provider, apiKey, model, system, messagesJson)
  return M.cbo_llm_start_tools(provider, apiKey, model, system, messagesJson, nil)
end

-- The fake model. The last user message decides the answer:
--   "screen"        -> a read_screen tool call (needs the tool to be offered)
--   "define a tool" -> a define_tool call that adds `disk_usage`
--   "cbo_ping"      -> the exact text CBO_PONG (the playground's ping)
--   "hello"         -> a greeting before the lorem text
-- A request whose last message is a tool result streams the lorem answer, so
-- the UI's whole tool loop runs without a network.
--
-- The message list is decoded rather than pattern-matched: an assistant turn
-- carries the model's own text (brackets, quotes, newlines), which no regex
-- over the raw JSON can reliably step over.
function M.cbo_llm_start_tools(provider, apiKey, model, system, messagesJson, toolsJson)
  local req = 0
  while llms[req] do
    req = req + 1
  end
  provider = type(provider) == "string" and provider or ffi.string(provider)
  local text = LOREM
  local calls = "[]"
  local messages = type(messagesJson) == "string" and require("src.json").decode(messagesJson)
    or nil
  local lastMsg = type(messages) == "table" and messages[#messages] or nil
  if type(lastMsg) == "table" and lastMsg.role == "user" then
    local q = tostring(lastMsg.content or ""):lower()
    if q:find("cbo_ping") then
      text = "CBO_PONG"
    elseif q:find("hello") then
      text = "Hi. " .. LOREM
    end
    if toolsJson then
      if q:find("screen") and toolsJson:find('"read_screen"') then
        calls = mockCalls({
          { id = "call_mock_1", name = "read_screen", args = { lines = "10" } },
        })
        text = ""
      elseif q:find("define a tool") and toolsJson:find('"define_tool"') then
        calls = mockCalls({
          {
            id = "call_mock_2",
            name = "define_tool",
            args = {
              name = "disk_usage",
              description = "disk usage of a path",
              command = "du -sh {path}",
              params = "path",
            },
          },
        })
        text = ""
      end
    end
  end
  llms[req] = {
    provider = provider,
    model = model,
    text = text == "" and ""
      or ("[" .. provider .. "/" .. tostring(model or "default") .. "] " .. text),
    calls = calls,
    pos = 0,
    state = LLM.PENDING,
    startAt = clock + 0.4,
    pending = {},
    err = "",
  }
  return req
end

function M.cbo_llm_take_calls(req)
  local r = llms[req]
  return r and r.calls or "[]"
end

function M.cbo_llm_state(req)
  local r = llms[req]
  return r and r.state or LLM.ERROR
end

function M.cbo_llm_take_delta(req)
  local r = llms[req]
  if not r then
    return ""
  end
  local d = table.concat(r.pending)
  r.pending = {}
  return d
end

function M.cbo_llm_error(req)
  local r = llms[req]
  return r and r.err or "bad request id"
end

function M.cbo_llm_cancel(req)
  local r = llms[req]
  if r and r.state < LLM.DONE then
    r.state = LLM.ERROR
    r.err = "cancelled"
  end
end

function M.cbo_llm_free(req)
  llms[req] = nil
end

-- Utils ----------------------------------------------------------------------

function M.cbo_utf8_width(s)
  if type(s) ~= "string" then
    s = ffi.string(s)
  end
  return strWidth(s)
end

function M.cbo_now_ms()
  return nowMs()
end

-- Mock-only: advance fake time. Called from Core.update.
function M.update(dt)
  clock = clock + dt
  for _, s in pairs(sessions) do
    if s.state == ST.CONNECTING then
      if s.failAt and clock >= s.failAt then
        s.state = ST.ERROR
        s.err = "connect: host unreachable (mock)"
        s.gen = s.gen + 1
      elseif clock >= s.connectAt then
        s.state = ST.CONNECTED
        s.lastActivity = nowMs()
        s.nextPing = clock + s.keepalive
        greet(s)
      end
    elseif s.state == ST.CONNECTED and s.keepalive > 0 and clock >= s.nextPing then
      s.lastPing = nowMs()
      s.nextPing = clock + s.keepalive
    end
  end
  for _, r in pairs(llms) do
    if r.state == LLM.PENDING and clock >= r.startAt then
      r.state = LLM.STREAMING
      r.acc = 0
    elseif r.state == LLM.STREAMING then
      r.acc = (r.acc or 0) + dt * 60 -- chars per second
      local n = math.floor(r.acc)
      if n > 0 then
        r.acc = r.acc - n
        local from = r.pos + 1
        local to = math.min(#r.text, r.pos + n)
        -- do not split utf8 sequences
        while to < #r.text and r.text:byte(to + 1) >= 0x80 and r.text:byte(to + 1) < 0xC0 do
          to = to + 1
        end
        if to >= from then
          r.pending[#r.pending + 1] = r.text:sub(from, to)
          r.pos = to
        end
        if r.pos >= #r.text then
          r.state = LLM.DONE
        end
      elseif #r.text == 0 then
        r.state = LLM.DONE -- a pure tool-call turn has no text
      end
    end
  end
end

-- Test helper: reset all state.
function M.reset()
  sessions, llms, clock, lastErr = {}, {}, 0, ""
end

return M
