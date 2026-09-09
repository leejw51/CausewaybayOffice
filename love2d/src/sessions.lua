-- Session list model: live sessions (backed by the core) + saved hosts list
-- persisted to hosts.json. Auto-names via Core.nameGenerate.

local json = require("src.json")

local S = {}

S.FILE = "hosts.json"
S.list = {} -- ordered live sessions: {id, name, host, port, user, keypath, tags, createdAt}
S.byId = {}
S.hosts = {} -- saved/recent hosts: {host, port, user, keypath, lastUsed}
S.core = nil
S.counter = 0
-- Favorites are never evicted when another server is added.

function S.hostKey(h)
  return (h.user or "") .. "@" .. (h.host or "") .. ":" .. tostring(h.port or 22)
end

-- Last remote working directory: remembered per session for restore and per
-- host for the next manual connection, sent back as a `cd` once the shell
-- has settled after connecting.
S.CWD_SETTLE = 0.4 -- seconds of quiet screen before the cd is typed

function S.cwdKey(h)
  return "cwd." .. S.hostKey(h)
end

function S.lastCwd(h)
  local v = S.core and S.core.kvGet and S.core.kvGet(S.cwdKey(h)) or ""
  return v ~= "" and v or nil
end

-- `cd` line for a remembered directory. A leading space keeps it out of shell
-- history where HISTCONTROL ignores it; single quotes carry any character
-- but a quote, which is spliced in.
function S.cdCommand(path)
  if type(path) ~= "string" or path == "" or path:find("[%z\1-\31\127]") then
    return nil
  end
  if path == "~" then
    return " cd ~\n"
  end
  local quoted = "'" .. path:gsub("'", "'\\''") .. "'"
  if path:sub(1, 2) == "~/" then
    -- keep the tilde outside the quotes so the shell still expands it
    quoted = "~/'" .. path:sub(3):gsub("'", "'\\''") .. "'"
  end
  return " cd " .. quoted .. "\n"
end

-- Hosts sorted by platform (stable map order); assigns platforms first.
function S.mapHosts()
  local MG = require("src.mapgraph")
  local _, changed = MG.assignPlatforms(S.hosts)
  if changed then
    S.saveHosts()
  end
  local t = {}
  for _, h in ipairs(S.hosts) do
    t[#t + 1] = h
  end
  table.sort(t, function(a, b)
    return (a.platform or 0) < (b.platform or 0)
  end)
  return t
end

-- One stage per session, even when several sessions share one favorite server.
-- Favorite positions are persisted; extra session positions live for that session.
function S.mapStages()
  local favorites = S.mapHosts()
  local stages, used, represented = {}, {}, {}
  local function stage(h, rec, platform)
    local entry = {}
    for k, v in pairs(h) do
      entry[k] = v
    end
    entry.platform, entry._session = platform, rec
    stages[#stages + 1] = entry
    used[platform] = true
    if rec then
      rec.mapPlatform = platform
      represented[rec] = true
    end
  end
  for _, h in ipairs(favorites) do
    local first
    for _, rec in ipairs(S.list) do
      if S.hostKey(rec) == S.hostKey(h) then
        first = first or rec
        if rec.mapPlatform == h.platform then
          first = rec
          break
        end
      end
    end
    stage(h, first, h.platform)
  end
  for _, rec in ipairs(S.list) do
    if not represented[rec] then
      local p = rec.mapPlatform
      if p == nil or used[p] then
        p = 0
        while used[p] do
          p = p + 1
        end
      end
      stage(S.findHost(S.hostKey(rec)) or rec, rec, p)
    end
  end
  table.sort(stages, function(a, b)
    return a.platform < b.platform
  end)
  return stages
end

function S.findHost(key)
  for _, h in ipairs(S.hosts) do
    if S.hostKey(h) == key then
      return h
    end
  end
  return nil
end

-- Most recently used saved host (nil when none).
function S.lastUsedHost()
  local best = nil
  for _, h in ipairs(S.hosts) do
    if not best or (h.lastUsed or 0) > (best.lastUsed or 0) then
      best = h
    end
  end
  return best
end

-- Live session record for a saved host, if any (prefers connected ones).
function S.liveFor(h)
  if h._session then
    return S.byId[h._session.id] == h._session and h._session or nil
  end
  local key = S.hostKey(h)
  local found = nil
  for _, rec in ipairs(S.list) do
    if S.hostKey(rec) == key then
      if rec.state == S.core.ST.CONNECTED then
        return rec
      end
      found = found or rec
    end
  end
  return found
end

function S.forgetHost(key)
  for i, h in ipairs(S.hosts) do
    if S.hostKey(h) == key then
      table.remove(S.hosts, i)
      S.saveHosts()
      return true
    end
  end
  return false
end

function S.touchHost(key)
  local h = S.findHost(key)
  if h then
    h.lastUsed = os.time()
    S.saveHosts()
  end
end

function S.init(core, opts)
  S.core = core
  S.allowFixtures = opts and opts.allowFixtures
  S.persistSessions = opts and opts.restoreSessions
  S.restoring = false
  S.list, S.byId = {}, {}
  S.loadHosts()
end

-- Recognize only the concrete fixtures left by the old QA walkthrough.
function S.isDemoHost(h)
  return type(h) == "table"
    and type(h.host) == "string"
    and (
      h.host:match("^mock%-%d%d%.lan$") ~= nil
      or (h.host == "10.255.255.1" and h.firstSeen == 200)
      or (h.host == "nosuch.invalid" and h.firstSeen == 300)
    )
end

function S.loadHosts()
  S.hosts = {}
  local persistent = S.core and not S.core.mock
  local raw = persistent and S.core.favoritesLoad() or ""
  local missingJsonl = raw == ""
  if missingJsonl and persistent then
    raw = S.core.kvGet("ui.hosts")
  end
  local imported = raw == ""
  if imported then
    raw = love.filesystem.read(S.FILE)
  end
  local removedDemo = false
  if raw then
    local t = json.decode(raw)
    if type(t) == "table" and type(t.hosts) == "table" then
      for _, h in ipairs(t.hosts) do
        if S.isDemoHost(h) and not (S.core and S.core.mock) and not S.allowFixtures then
          removedDemo = true
        elseif
          type(h) == "table"
          and type(h.host) == "string"
          and h.host ~= ""
          and type(h.user) == "string"
          and h.user ~= ""
        then
          S.hosts[#S.hosts + 1] = {
            host = h.host,
            user = h.user,
            port = math.max(1, math.min(65535, math.floor(tonumber(h.port) or 22))),
            keypath = type(h.keypath) == "string" and h.keypath or "",
            lastUsed = tonumber(h.lastUsed) or 0,
            firstSeen = tonumber(h.firstSeen) or 0,
            platform = tonumber(h.platform),
            label = type(h.label) == "string" and h.label or nil,
            favorite = true,
          }
        end
      end
    end
  end
  if persistent and (removedDemo or imported or missingJsonl) then
    if removedDemo then
      S.core.kvSet("ui.hosts.before-fixture-cleanup", raw or "")
    end
    S.saveHosts()
  end
  table.sort(S.hosts, function(a, b)
    return (a.lastUsed or 0) > (b.lastUsed or 0)
  end)
  return S.hosts
end

function S.saveHosts()
  if S.core and not S.core.mock then
    local data = json.encode({ hosts = S.hosts })
    local ok = S.core.favoritesSave(data)
    if ok then
      ok = S.core.kvSet("ui.hosts", data)
    end
    if not ok then
      print("[sessions] Favorites save failed: " .. S.core.lastError())
    end
    return ok
  end
  local ok, err = require("src.storage").write(S.FILE, json.encode({ hosts = S.hosts }, true))
  if not ok then
    print("[sessions] save failed: " .. tostring(err))
  end
  return ok
end

function S.rememberHost(p)
  local key = S.hostKey(p)
  local old = nil
  for i, h in ipairs(S.hosts) do
    if S.hostKey(h) == key then
      old = table.remove(S.hosts, i)
      break
    end
  end
  table.insert(S.hosts, 1, {
    host = p.host,
    port = tonumber(p.port) or 22,
    user = p.user,
    keypath = p.keypath or (old and old.keypath) or "",
    lastUsed = os.time(),
    firstSeen = old and (old.firstSeen or old.lastUsed) or os.time(),
    platform = old and old.platform or p.platform, -- clicked empty stage, or existing stable slot
    favorite = true,
    label = old and old.label or nil,
  })
  S.saveHosts()
end

local firstNames = {
  "mary",
  "john",
  "emma",
  "james",
  "anna",
  "alex",
  "lily",
  "leo",
  "sara",
  "noah",
  "mia",
  "jack",
  "rose",
  "luke",
  "ella",
  "max",
}
function S.nextName()
  local seq = math.max(S.nameCounter or 0, tonumber(S.core.kvGet("sessions.name_counter")) or 0)
  local name, taken
  repeat
    seq = seq + 1
    name = firstNames[(seq - 1) % #firstNames + 1] .. "-" .. seq
    taken = false
    for _, rec in ipairs(S.list) do
      if rec.name == name then
        taken = true
        break
      end
    end
  until not taken
  S.nameCounter = seq
  S.core.kvSet("sessions.name_counter", tostring(seq))
  return name
end

-- Open a session. Returns the session record or nil, err.
function S.open(p)
  S.counter = S.counter + 1
  local id, err = S.core.open({
    host = p.host,
    port = tonumber(p.port) or 22,
    user = p.user,
    password = p.password,
    keypath = p.keypath,
    cols = p.cols or 80,
    rows = p.rows or 24,
  })
  if not id then
    return nil, err or "open failed"
  end
  local name = p.name or S.nextName()
  if not S.core.setName(id, name) then
    name = S.nextName()
    S.core.setName(id, name)
  end
  S.core.setKeepalive(id, p.keepalive or require("src.config").get().keepaliveSeconds or 15)
  local rec = {
    id = id,
    mapPlatform = p.platform,
    state = S.core.state(id),
    name = name,
    host = p.host,
    port = tonumber(p.port) or 22,
    user = p.user,
    keypath = p.keypath or "",
    tags = p.tags or {},
    createdAt = os.time(),
    lastPing = 0,
    pulse = 0,
    wantCwd = p.cwd or S.lastCwd(p),
    lastGen = -1,
    quiet = 0,
  }
  rec.cwd = rec.wantCwd
  rec.cwdArmed = rec.wantCwd == nil -- learn cwd only once the cd went out
  S.list[#S.list + 1] = rec
  S.byId[id] = rec
  if not p.noRemember then
    S.rememberHost(p)
    local hid = S.core.hostUpsert({
      host = p.host,
      port = tonumber(p.port) or 22,
      user = p.user,
      name = name,
      keypath = p.keypath or "",
    })
    if hid then
      S.core.setHost(id, hid)
      rec.hostId = hid
    end
  end
  return rec
end

-- The restore list contains only sessions that connected successfully, or were
-- restored from such a session. Closing a session explicitly removes that intent.
function S.saveRestore()
  if not S.persistSessions or S.restoring then
    return true
  end
  local hosts = {}
  for _, rec in ipairs(S.list) do
    if rec.restoreWanted and not rec.closing then
      hosts[#hosts + 1] = {
        host = rec.host,
        port = rec.port,
        user = rec.user,
        keypath = rec.keypath,
        name = rec.name,
        platform = rec.mapPlatform,
        cwd = rec.cwd,
      }
    end
  end
  local ok = S.core.sessionsSave(json.encode({ hosts = hosts }))
  if not ok then
    print("[sessions] Could not save sessions.jsonl: " .. S.core.lastError())
  end
  return ok
end
function S.restore(cols, rows)
  if not S.persistSessions then
    return
  end
  local saved = json.decode(S.core.sessionsLoad())
  if type(saved) ~= "table" or type(saved.hosts) ~= "table" then
    return
  end
  S.restoring = true
  for _, h in ipairs(saved.hosts) do
    if
      type(h) == "table"
      and type(h.host) == "string"
      and h.host ~= ""
      and type(h.user) == "string"
      and h.user ~= ""
    then
      local rec = S.open({
        host = h.host,
        port = h.port,
        user = h.user,
        keypath = type(h.keypath) == "string" and h.keypath or "",
        platform = type(h.platform) == "number" and h.platform or nil,
        name = type(h.name) == "string" and h.name ~= "" and h.name or nil,
        cwd = type(h.cwd) == "string" and h.cwd ~= "" and h.cwd or nil,
        cols = cols,
        rows = rows,
      })
      if rec then
        rec.restoreWanted = true
        if type(h.name) == "string" and h.name ~= "" then
          S.rename(rec.id, h.name)
        end
      end
    end
  end
  S.restoring = false
end

function S.get(id)
  return S.byId[id]
end

function S.index(id)
  for i, r in ipairs(S.list) do
    if r.id == id then
      return i
    end
  end
  return nil
end

function S.rename(id, name)
  local rec = S.byId[id]
  if not rec then
    return false
  end
  if S.core.setName(id, name) then
    rec.name = name
    S.saveRestore()
    return true
  end
  return false
end

-- Graceful close; the record stays until the core reports CLOSED/ERROR and
-- S.update frees the slot.
function S.close(id)
  local rec = S.byId[id]
  if not rec then
    return
  end
  rec.closing = true
  S.saveRestore()
  S.core.close(id)
end

function S.remove(id)
  local rec = S.byId[id]
  if not rec then
    return
  end
  local i = S.index(id)
  if i then
    table.remove(S.list, i)
  end
  S.byId[id] = nil
  S.saveRestore()
  S.core.free(id)
end

-- Poll state; frees closed sessions that were asked to close. `dt` decays
-- the keepalive pulse (1 -> 0 over 250 ms) so every scene that draws it
-- (lobby card, map glow, status bar) sees the same heartbeat.
function S.update(dt)
  local ST = S.core.ST
  local i = 1
  local newlyConnected, cwdChanged = false, false
  while i <= #S.list do
    local rec = S.list[i]
    local info = S.core.info(rec.id)
    if dt and rec.pulse > 0 then
      rec.pulse = math.max(0, rec.pulse - dt * 4)
    end
    if info then
      rec.state = info.state
      if info.state == ST.CONNECTED and not rec.restoreWanted then
        rec.restoreWanted, newlyConnected = true, true
      end
      rec.info = info
      if info.last_ping_ms ~= rec.lastPing and info.last_ping_ms > 0 then
        rec.lastPing = info.last_ping_ms
        rec.pulse = 1
      end
      if info.state == ST.CONNECTED and S.trackCwd(rec, info.generation, dt or 0) then
        cwdChanged = true
      end
      if rec.closing and (info.state == ST.CLOSED or info.state == ST.ERROR) then
        S.remove(rec.id)
        i = i - 1
      end
    else
      rec.state = ST.ERROR
    end
    i = i + 1
  end
  if newlyConnected or cwdChanged then
    S.saveRestore()
  end
end

-- One connected session's cwd bookkeeping. Types the remembered `cd` once
-- the screen has been quiet for CWD_SETTLE after the first output (the
-- prompt), then follows the shell's reports. Returns true when the saved
-- cwd changed.
function S.trackCwd(rec, gen, dt)
  if rec.wantCwd then
    -- A real cwd report establishes that shell startup reached its prompt.
    -- Never append an automatic command to something the user is typing.
    if S.core.typing(rec.id) ~= "" then
      rec.wantCwd, rec.cwdArmed = nil, true
      return false
    end
    if S.core.cwd(rec.id) == "" and not S.core.mock then
      return false
    end
    if gen ~= rec.lastGen then
      rec.lastGen, rec.quiet = gen, 0
    elseif gen > 0 then
      rec.quiet = rec.quiet + dt
      if rec.quiet >= S.CWD_SETTLE then
        local cmd = S.cdCommand(rec.wantCwd)
        if cmd then
          rec.cwdBeforeRestore = S.core.cwd(rec.id)
          rec.restoreGen = gen
          S.core.write(rec.id, cmd)
        end
        rec.wantCwd, rec.cwdArmed = nil, true
      end
    end
    return false
  end
  if not rec.cwdArmed then
    return false
  end
  local cwd = S.core.cwd(rec.id)
  if rec.restoreGen then
    -- A queued cd has not necessarily reached the shell yet. Do not save
    -- the old login directory while waiting for the next prompt report.
    if gen == rec.restoreGen or cwd == rec.cwdBeforeRestore then
      return false
    end
    rec.restoreGen = nil
  end
  if cwd == "" or cwd == rec.cwd then
    return false
  end
  rec.cwd = cwd
  S.core.kvSet(S.cwdKey(rec), cwd)
  return true
end

function S.count()
  return #S.list
end

-- Next/prev record relative to id (wraps).
function S.neighbor(id, dir)
  local n = #S.list
  if n == 0 then
    return nil
  end
  local i = S.index(id) or 1
  local j = ((i - 1 + (dir or 1)) % n) + 1
  return S.list[j]
end

return S
