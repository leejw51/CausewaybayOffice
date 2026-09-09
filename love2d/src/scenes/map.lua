-- World map: Super-Mario-World-style overworld. Every saved host is a stage
-- on a platform; the hero walks the path graph to a node and connects.
--
-- Keys: arrows / WASD move along the paths, Enter walks + connects, Tab cycles
-- stages, R rename, Del forget host, [ ] (or Shift+Left/Right) page,
-- Esc / M / F2 back to the lobby. Mouse: hover shows the label (+ live
-- thumbnail), click walks there.
--
-- Geometry: the 16:9 map is scaled to cover the view (landscape). Portrait
-- keeps the very same horizontal map and only fits the camera: the map is
-- scaled to the width, centred in the view above a taller info panel. The
-- camera follows the hero with an exponential ease whenever the map is
-- larger than the view.

local UI = require("src.ui")
local Keys = require("src.keys")
local MG = require("src.mapgraph")

local Map = {}
Map.__index = Map

local HEADER_H = 30
local INFO_H = 80 -- landscape info panel
local INFO_H_PORTRAIT = 96
local NODE = 28
local HERO_W = 22
local HOP_T = 0.24
local CONNECT_SETTLE = 0.6

-- Node frames in map_node.png: unvisited / online / error / selected
local NF = { unvisited = 1, online = 2, error = 3, selected = 4 }

-- Constant tables hoisted out of update/draw (no per-frame allocation).
local DIRS = {
  left = { -1, 0 },
  a = { -1, 0 },
  right = { 1, 0 },
  d = { 1, 0 },
  up = { 0, -1 },
  w = { 0, -1 },
  down = { 0, 1 },
  s = { 0, 1 },
}
local PLACEHOLDER_COL = { "gray", "lgreen", "alarm", "yellow" } -- by NF index
local HINTS = {
  { "Enter", "walk+connect" },
  { "Shift+arrows", "pan" },
  { "Home", "center" },
  { "R", "rename" },
  { "Del", "forget" },
  { "[ ]", "page" },
  { "^N", "new" },
  { "G", "Map 2" },
}
local STATE_COL = { none = "gray", connecting = "amber", online = "lgreen", error = "alarm" }
local AMBER = { 0.96, 0.62, 0.16 }
local Lobby -- required lazily (lobby requires nothing from here, but keep it one-way at load)

local function clear(t)
  for i = #t, 1, -1 do
    t[i] = nil
  end
end

function Map.new(app, params)
  local s = setmetatable({}, Map)
  s.app = app
  s.params = params or {}
  s.t = 0
  s.nodes = MG.load()
  s.hosts = app.sessions.mapStages()
  s.slotHost = {} -- page -> slot -> host
  s.page = 0
  s.pages = 1
  s.sel = 1 -- 1-based platform index on the current page
  s.hover = nil
  s.lift = {} -- platform -> {y}
  s.labelPop = { s = 1 }
  s.hero = { slot = 1, x = 0, y = 0, facing = 1, state = "idle", frameT = 0, alpha = 1 }
  s.cam = { x = 0, y = 0 }
  s.pending = nil -- { key, id, slot }
  s.errors = {} -- key -> message
  s.flags = {} -- key -> { t }
  s.passwords = {} -- key -> password typed this session (never saved)
  s.buttons = {}
  s.missing = {}
  s.timers = {} -- fx.after handles, cancelled in leave()
  s.gone = false
  s.rowTxt, s.rowCol = {}, {} -- info panel rows (reused every frame)
  -- undirected edge list once (drawPaths walks it every frame)
  s.edges = {}
  local seen = {}
  for a, nbs in pairs(s.nodes.adj) do
    for _, b in ipairs(nbs) do
      local lo, hi = math.min(a, b), math.max(a, b)
      local k = lo * 1000 + hi
      if not seen[k] then
        seen[k] = true
        s.edges[#s.edges + 1] = { lo, hi }
      end
    end
  end
  table.sort(s.edges, function(p, q)
    return p[1] * 1000 + p[2] < q[1] * 1000 + q[2]
  end)
  s.pagePrev = function()
    s:setPage(s.page - 1)
  end
  s.pageNext = function()
    s:setPage(s.page + 1)
  end
  s.btnPrev = { x = 0, y = 0, w = 16, h = 12, fn = s.pagePrev }
  s.btnNext = { x = 0, y = 0, w = 16, h = 12, fn = s.pageNext }
  s:indexHosts()
  local last = app.sessions.lastUsedHost()
  if s.params.selectKey then
    last = app.sessions.findHost(s.params.selectKey) or last
  end
  if last and last.platform then
    s.page = MG.page(last.platform)
    s.sel = MG.slot(last.platform) + 1
  end
  local newest = s.params.select and app.sessions.get(s.params.select)
    or app.sessions.list[#app.sessions.list]
  for _, stage in ipairs(s.hosts) do
    if newest and stage._session == newest and not s.params.selectKey then
      s.page, s.sel = MG.page(stage.platform), MG.slot(stage.platform) + 1
    end
  end
  s.hero.slot = s.sel
  s.hero.page = s.page
  return s
end

function Map:indexHosts()
  self.slotHost = {}
  local maxP = -1
  for _, h in ipairs(self.hosts) do
    local p = h.platform or 0
    maxP = math.max(maxP, p)
    local pg, sl = MG.page(p), MG.slot(p) + 1
    self.slotHost[pg] = self.slotHost[pg] or {}
    self.slotHost[pg][sl] = h
  end
  self.pages = math.max(1, MG.page(math.max(0, maxP)) + 1)
  local lastPage = self.slotHost[self.pages - 1] or {}
  local full = true
  for i = 1, MG.PER_PAGE do
    if not lastPage[i] then
      full = false
      break
    end
  end
  if full then
    self.pages = self.pages + 1
  end
end

function Map:hostAt(slot, page)
  local t = self.slotHost[page or self.page]
  return t and t[slot] or nil
end

function Map:enter()
  self:layout()
  self:placeHero(true)
end

-- Scene timer: fires only while the scene is alive (see leave()).
function Map:after(delay, fn)
  local h = self.app.fx.after(delay, function()
    if not self.gone then
      fn()
    end
  end)
  self.timers[#self.timers + 1] = h
  return h
end

-- Leaving cancels everything scheduled by the scene: the hop -> connect timer,
-- the connect -> terminal settle, the label pop. A walk never continues on a
-- dead scene and no session is opened after Esc.
function Map:leave()
  self.gone = true
  self.pending = nil
  self.drag = nil
  for _, h in ipairs(self.timers) do
    self.app.fx.cancel(h)
  end
  clear(self.timers)
  self.hero.path = nil
  if self.hero.state == "walk" or self.hero.state == "hop" then
    self.hero.state = "idle"
  end
end

-- Sprites ---------------------------------------------------------------------

function Map:strips()
  if self.sp then
    return self.sp
  end
  local G = self.app.G
  local sp = {
    node = G.strip("map_node", 4, NODE, NODE, { mode = "each" }),
    walk = G.strip("hero_walk", 4, HERO_W, nil, { mode = "anchor", deviant = 0.06 }),
    idle = G.strip("hero_map_idle", 2, HERO_W, nil, { mode = "anchor", pick = 2 }),
    flag = G.strip("map_flag", 2, 16, nil, { mode = "anchor" }),
    dust = G.strip("particle_dust", 4, 8, 8, { mode = "each" }),
    confetti = G.strip("particle_confetti", 4, 8, 8, { mode = "each" }),
    cloud = G.strip("map_cloud", 2, 64, nil, { mode = "each" }),
  }
  self.missing = {}
  for name, st in pairs(sp) do
    if st.placeholder then
      self.missing[#self.missing + 1] = name
    end
  end
  table.sort(self.missing)
  if not G.exists("map_causeway") then
    table.insert(self.missing, 1, "map_causeway")
  end
  self.sp = sp
  return sp
end

-- Layout ------------------------------------------------------------------------

-- Pure layout maths (tested): returns map size, view rect and info panel.
function Map.fit(vw, vh, portrait)
  local W, H = 16, 9
  if portrait then
    -- same map, fitted: width-bound normally, height-bound on a short window
    local viewH = math.max(60, vh - HEADER_H - INFO_H_PORTRAIT - 16)
    local k = math.min(vw / W, viewH / H)
    return {
      mapW = math.ceil(W * k),
      mapH = math.ceil(H * k),
      viewX = 0,
      viewY = HEADER_H,
      viewW = vw,
      viewH = viewH,
      infoY = HEADER_H + viewH,
      infoH = vh - HEADER_H - viewH,
      portrait = true,
    }
  end
  local viewH = vh - HEADER_H - INFO_H
  local k = math.max(vw / W, viewH / H)
  local mapW, mapH = math.ceil(W * k), math.ceil(H * k)
  return {
    mapW = mapW,
    mapH = mapH,
    viewX = 0,
    viewY = HEADER_H,
    viewW = vw,
    viewH = viewH,
    infoY = HEADER_H + viewH,
    infoH = INFO_H,
    portrait = false,
  }
end

function Map:layout()
  local D = self.app.D
  self.L = Map.fit(D.vw, D.vh, D.portrait)
  self.mapImg = nil
  self:snapCamera()
end

function Map:resize()
  self:layout()
  -- Reproject the current walk when orientation changes mid-session.
  if self.hero.path then
    for _, point in ipairs(self.hero.path) do
      point.x, point.y = self:nodeMapPos(point.slot)
    end
    self:beginSegment()
  end
  self:placeHero(true)
end

-- Platform position in map px (before the camera).
function Map:nodeMapPos(slot)
  local p = self.nodes.platforms[slot]
  if not p then
    return 0, 0
  end
  return p.x * self.L.mapW, p.y * self.L.mapH
end

function Map:cameraTarget()
  local L = self.L
  if self.manualPan then
    return self:clampCamera(self.cam.x, self.cam.y)
  end
  local hx, hy = self.hero.x, self.hero.by or self.hero.y
  if self.focusSlot then
    hx, hy = self:nodeMapPos(self.focusSlot)
  end
  local cx = math.floor(hx - L.viewW / 2 + 0.5)
  local cy = math.floor(hy - L.viewH / 2 + 0.5)
  cx = math.max(0, math.min(cx, L.mapW - L.viewW))
  cy = math.max(0, math.min(cy, L.mapH - L.viewH))
  if L.mapW <= L.viewW then
    cx = math.floor((L.mapW - L.viewW) / 2)
  end
  if L.mapH <= L.viewH then
    cy = math.floor((L.mapH - L.viewH) / 2)
  end
  return cx, cy
end

function Map:clampCamera(x, y)
  local L = self.L
  local function bound(value, size, view)
    if size <= view then
      return math.floor((size - view) / 2)
    end
    return math.max(0, math.min(size - view, value))
  end
  return bound(x, L.mapW, L.viewW), bound(y, L.mapH, L.viewH)
end
function Map:pan(dx, dy)
  self.manualPan, self.focusSlot = true, nil
  self.cam.x, self.cam.y = self:clampCamera(self.cam.x + dx, self.cam.y + dy)
  self.hover = nil
end
function Map:recenter()
  self.manualPan, self.drag, self.focusSlot = false, nil, self.sel
  self:snapCamera()
end

function Map:snapCamera()
  self.cam.x, self.cam.y = self:cameraTarget()
end

-- Map px -> content px.
function Map:toScreen(mx, my)
  return mx - self.cam.x + self.L.viewX, my - self.cam.y + self.L.viewY
end

function Map:placeHero(snap)
  local x, y = self:nodeMapPos(self.hero.slot)
  self.hero.x, self.hero.y = x, y
  self.hero.by = y
  if snap then
    self:snapCamera()
  end
end

-- State of a stage: "none" | "connecting" | "online" | "error"
function Map:stageState(host)
  if not host then
    return "none"
  end
  local key = self.app.sessions.hostKey(host)
  local rec = self.app.sessions.liveFor(host)
  local ST = self.app.core.ST
  if rec then
    if rec.state == ST.CONNECTED then
      return "online", rec
    elseif rec.state == ST.CONNECTING then
      return "connecting", rec
    elseif rec.state == ST.ERROR then
      return "error", rec
    end
  end
  if self.errors[key] then
    return "error", nil
  end
  return "none", nil
end

-- Walking ------------------------------------------------------------------------

function Map:startWalk(target)
  self.manualPan, self.focusSlot = false, nil
  local hero = self.hero
  if hero.state ~= "idle" or target == hero.slot then
    if target == hero.slot and hero.state == "idle" then
      self:arrive(target)
    end
    return false
  end
  if hero.page ~= self.page then
    -- another page: the hero fades in on the page's first stage
    hero.page = self.page
    hero.slot = 1
    hero.alpha = 0
    self.app.fx.tween(hero, { alpha = 1 }, 0.4, "expoOut")
    self:placeHero(false)
  end
  local path = MG.bfs(self.nodes, hero.slot, target)
  if not path then
    self.app.fx.shake(1, 0.1)
    return false
  end
  local points = {}
  for i, slot in ipairs(path) do
    local x, y = self:nodeMapPos(slot)
    points[i] = { x = x, y = y, slot = slot }
  end
  hero.state = "walk"
  hero.path = points
  hero.seg = 1
  hero.segT = 0
  hero.target = target
  hero.dustT = 0
  hero.walkT = 0
  self:beginSegment()
  self.app.audio.play("click")
  return true
end

function Map:beginSegment()
  local hero = self.hero
  local a, b = hero.path[hero.seg], hero.path[hero.seg + 1]
  if not b then
    return self:arrive(hero.target)
  end
  local dx, dy = b.x - a.x, b.y - a.y
  local len = math.sqrt(dx * dx + dy * dy)
  hero.segLen = len
  hero.segDur = MG.segmentDuration(len)
  hero.segSteps = MG.steps(len)
  hero.segT = 0
  hero.facing = MG.facing(dx)
end

function Map:arrive(slot)
  local hero = self.hero
  hero.state = "hop"
  hero.hopT = 0
  hero.slot = slot
  hero.path = nil
  self:placeHero(false)
  self.sel = slot
  local sp = self:strips()
  local sx, sy = self:toScreen(hero.x, hero.y)
  self.app.fx.confettiBurst(sx, sy - 12, 24, sp.confetti, 150)
  self.labelPop.s = 0.6
  self.app.fx.tween(self.labelPop, { s = 1 }, 0.32, "backOut")
  self.app.audio.play("select")
  self:after(HOP_T, function()
    if hero.state == "hop" then
      hero.state = "idle"
    end
    self:connect(slot)
  end)
end

-- Connecting ---------------------------------------------------------------------

-- Empty stages are real connection slots, never synthetic servers.
function Map:newConnection()
  if not self:hostAt(self.sel) then
    return self:activate(self.sel)
  end
  self.app.push("connect", { fromTerminal = true })
end

function Map:activate(slot)
  if self:hostAt(slot) then
    return self:startWalk(slot)
  end
  if self.gone or self.pending or self.hero.state ~= "idle" then
    return
  end
  local platform = self.page * MG.PER_PAGE + slot - 1
  self.app.push("connect", {
    platform = platform,
    onOpen = function(rec)
      if self.gone then
        return
      end
      self.hosts = self.app.sessions.mapStages()
      self:indexHosts()
      local p = rec.mapPlatform or platform
      self.page, self.sel = MG.page(p), MG.slot(p) + 1
      self.hero.slot, self.hero.page = self.sel, self.page
      self:placeHero(true)
      self.pending = { key = self.app.sessions.hostKey(rec), id = rec.id, slot = self.sel, t = 0 }
    end,
  })
end

function Map:connect(slot)
  local app = self.app
  self.sel = slot
  local host = self:hostAt(slot)
  if not host then
    return self:activate(slot)
  end
  local S = app.sessions
  local key = S.hostKey(host)
  local live = S.liveFor(host)
  if live and (live.state == app.core.ST.CONNECTED or live.state == app.core.ST.CONNECTING) then
    S.touchHost(key)
    app.audio.play("select")
    app.switch("terminal", { id = live.id })
    return
  end
  self.errors[key] = nil
  local cols, rows = app.termGrid()
  local rec, err = S.open({
    host = host.host,
    port = host.port,
    user = host.user,
    keypath = host.keypath,
    password = self.passwords[key],
    cols = cols,
    rows = rows,
    keepalive = app.cfg.get().keepaliveSeconds,
  })
  if not rec then
    self:fail(key, err or "open failed")
    return
  end
  self.pending = { key = key, id = rec.id, slot = slot, t = 0 }
  self.hosts = S.mapStages()
  self:indexHosts()
end

function Map:selectionFocus()
  local x, y = self:toScreen(self:nodeMapPos(self.sel))
  return {
    x = self.app.fx.clamp(x / self.app.D.vw, 0, 1),
    y = self.app.fx.clamp(y / self.app.D.vh, 0, 1),
  }
end

function Map:fail(key, msg)
  self.errors[key] = msg
  self.app.audio.play("error")
  self.app.fx.shake(3, 0.25)
  self.flicker = { key = key, t = 0 }
end

function Map:update(dt)
  self.t = self.t + dt
  local app = self.app
  local hero = self.hero
  local fx = app.fx
  self.refreshT = (self.refreshT or 0) + dt
  if self.refreshT >= 0.25 then
    self.refreshT = 0
    self.hosts = app.sessions.mapStages()
    self:indexHosts()
    self.page = math.min(self.page, self.pages - 1)
  end

  -- walk
  if hero.state == "walk" and hero.path then
    hero.segT = hero.segT + dt
    hero.walkT = hero.walkT + dt
    local a, b = hero.path[hero.seg], hero.path[hero.seg + 1]
    local u = fx.clamp(hero.segT / hero.segDur, 0, 1)
    local e = fx.ease.expoInOut(u)
    hero.x = a.x + (b.x - a.x) * e
    hero.by = a.y + (b.y - a.y) * e -- feet line (camera follows this, not the bob)
    hero.y = hero.by + MG.bob(u, hero.segSteps)
    hero.dustT = hero.dustT + dt
    if hero.dustT >= 0.12 then
      hero.dustT = hero.dustT - 0.12
      local sx, sy = self:toScreen(hero.x, hero.y)
      fx.dustPuff(sx - hero.facing * 6, sy, self:strips().dust, hero.facing)
    end
    if u >= 1 then
      hero.seg = hero.seg + 1
      if hero.path[hero.seg + 1] then
        self:beginSegment()
      else
        self:arrive(hero.target)
      end
    end
  elseif hero.state == "hop" then
    hero.hopT = hero.hopT + dt
  end

  -- camera (expo ease; no pan when the map fits the view)
  local tx, ty = self:cameraTarget()
  self.cam.x = fx.approach(self.cam.x, tx, dt, 8)
  self.cam.y = fx.approach(self.cam.y, ty, dt, 8)

  -- hover lift
  for slot in pairs(self.nodes.adj) do
    local l = self.lift[slot]
    if not l then
      l = { y = 0, on = false }
      self.lift[slot] = l
    end
    local on = (self.hover == slot)
    if on ~= l.on then
      l.on = on
      fx.tween(l, { y = on and 2 or 0 }, 0.18, "expoOut")
    end
  end

  -- pending connect
  if self.pending then
    local p = self.pending
    p.t = p.t + dt
    local rec = app.sessions.get(p.id)
    local ST = app.core.ST
    if not rec then
      self.pending = nil
    elseif rec.state == ST.CONNECTED then
      if not p.done then
        p.done = true
        self.flags[p.key] = { t = 0 }
        app.audio.play("connect")
        local sx, sy = self:toScreen(self:nodeMapPos(p.slot))
        fx.sparkBurst(sx, sy - 10, 24, app.G.strip("particle_spark", 4, 16, 16), 130)
        self:after(CONNECT_SETTLE, function()
          self.pending = nil
          app.switch("terminal", { id = rec.id })
        end)
      end
    elseif rec.state == ST.ERROR then
      local msg = app.core.error(rec.id)
      self.pending = nil
      app.sessions.close(rec.id)
      self:fail(p.key, msg)
      if msg:find("authentication failed", 1, true) and not self.passwords[p.key] then
        local key, slot = p.key, p.slot
        app.push("password", {
          title = "PASSWORD",
          prompt = key,
          onSubmit = function(pw)
            self.passwords[key] = pw
            self.errors[key] = nil
            self:connect(slot)
          end,
        })
      end
    end
  end
  for _, f in pairs(self.flags) do
    f.t = f.t + dt
  end
  if self.flicker then
    self.flicker.t = self.flicker.t + dt
    if self.flicker.t > 2.1 then
      self.flicker = nil
    end
  end
  -- keep live thumbnails fresh
  for _, rec in ipairs(app.sessions.list) do
    app.view(rec.id):update(dt)
  end
end

-- Input --------------------------------------------------------------------------

function Map:toLobby()
  self.app.audio.play("select")
  self.app.switch("lobby")
end

-- Neighbour of `from` best matching a direction vector.
function Map:neighbourToward(from, dx, dy)
  local best, bestDot = nil, 0.3
  local fx0, fy0 = self:nodeMapPos(from)
  for _, nb in ipairs(self.nodes.adj[from] or {}) do
    local nx, ny = self:nodeMapPos(nb)
    local vx, vy = nx - fx0, ny - fy0
    local len = math.sqrt(vx * vx + vy * vy)
    if len > 0 then
      local dot = (vx * dx + vy * dy) / len
      if dot > bestDot then
        best, bestDot = nb, dot
      end
    end
  end
  return best
end

function Map:setPage(p)
  p = math.max(0, math.min(self.pages - 1, p))
  if p ~= self.page then
    self.page = p
    self.app.audio.play("click")
    self.app.fx.flash(0.1, 1, 1, 1, 0.2)
  end
end

function Map:renameSelected()
  local app = self.app
  local host = self:hostAt(self.sel)
  if not host then
    return
  end
  local _, rec = self:stageState(host)
  if rec then
    app.push("rename", { id = rec.id })
  else
    app.push("rename", { hostKey = app.sessions.hostKey(host), initial = host.label or host.host })
  end
end

function Map:forgetSelected()
  local app = self.app
  local host = self:hostAt(self.sel)
  if not host then
    return
  end
  local key = app.sessions.hostKey(host)
  app.push("menu", {
    title = "FORGET HOST?",
    items = {
      {
        "Forget " .. key,
        function()
          app.sessions.forgetHost(key)
          self.hosts = app.sessions.mapStages()
          self:indexHosts()
          app.audio.play("close")
        end,
      },
      { "Cancel", nil },
    },
  })
end

function Map:keypressed(key, m)
  local app = self.app
  local chord = Keys.appChord(key, m)
  if m.shift and DIRS[key] then
    local dir = DIRS[key]
    return self:pan(dir[1] * 40, dir[2] * 40)
  elseif key == "home" then
    return self:recenter()
  end
  if chord == "lobby" or key == "escape" or key == "m" then
    return self:toLobby()
  elseif chord == "help" then
    return app.push("help")
  elseif chord == "settings" then
    return app.push("settings")
  elseif chord == "search" then
    return app.push("search")
  elseif key == "g" then
    return app.switch("map2")
  elseif chord == "new" or key == "n" then
    return self:newConnection()
  elseif chord == "rename" or key == "r" then
    return self:renameSelected()
  elseif chord == "quit" then
    love.event.quit()
    return
  elseif key == "delete" or key == "backspace" then
    return self:forgetSelected()
  elseif key == "return" or key == "kpenter" or key == "space" then
    self:activate(self.sel)
    return
  elseif key == "tab" then
    local n = #self.nodes.platforms
    for _ = 1, n do
      self.sel = (self.sel % n) + 1
      if self:hostAt(self.sel) then
        break
      end
    end
    self.manualPan, self.focusSlot = false, self.sel
    app.audio.play("click")
    return
  elseif key == "[" or key == "pageup" then
    return self:setPage(self.page - 1)
  elseif key == "]" or key == "pagedown" then
    return self:setPage(self.page + 1)
  end
  local dir = DIRS[key]
  if dir then
    local nb = self:neighbourToward(self.sel, dir[1], dir[2])
    if nb then
      self.sel = nb
      self.manualPan, self.focusSlot = false, self.sel
      app.audio.play("click")
    else
      app.fx.shake(1, 0.08)
    end
  end
end

function Map:nodeAt(mx, my)
  for slot = 1, #self.nodes.platforms do
    local sx, sy = self:toScreen(self:nodeMapPos(slot))
    if math.abs(mx - sx) <= NODE / 2 + 4 and math.abs(my - (sy - 6)) <= NODE / 2 + 8 then
      return slot
    end
  end
  return nil
end

function Map:mousemoved(mx, my)
  if self.drag then
    self:pan(self.drag.x - mx, self.drag.y - my)
    self.drag.x, self.drag.y = mx, my
    return
  end
  if my < self.L.infoY then
    self.hover = self:nodeAt(mx, my)
  else
    self.hover = nil
  end
end

function Map:mousepressed(mx, my, b)
  if my >= HEADER_H and my < self.L.infoY and (b == 2 or b == 3) then
    self.drag = { x = mx, y = my, button = b }
    return
  end
  if b ~= 1 then
    return
  end
  for _, bt in ipairs(self.buttons) do
    if UI.inside(mx, my, bt.x, bt.y, bt.w, bt.h) then
      self.app.audio.play("click")
      bt.fn()
      return
    end
  end
  if my < HEADER_H or my >= self.L.infoY then
    return
  end
  local slot = self:nodeAt(mx, my)
  if slot then
    self.sel = slot
    self:activate(slot)
  else
    self.drag = { x = mx, y = my, button = b }
  end
end
function Map:mousereleased(_, _, b)
  if self.drag and self.drag.button == b then
    self.drag = nil
  end
end

function Map:wheelmoved(dx, dy)
  self:pan(-dx * 48, -dy * 48)
end

-- Drawing -------------------------------------------------------------------------

function Map:drawBackground()
  local app = self.app
  local G = app.G
  local L = self.L
  local ox, oy = -self.cam.x + L.viewX, -self.cam.y + L.viewY
  if G.exists("map_causeway") then
    if not self.mapImg or self.mapImgW ~= L.mapW then
      self.mapImg = G.sprite("map_causeway", L.mapW, L.mapH, { noChroma = true })
      self.mapImgW = L.mapW
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(self.mapImg, math.floor(ox), math.floor(oy))
  else
    -- procedural overworld: sky, sea, rolling hills
    local W, H = L.mapW, L.mapH
    for i = 0, 5 do
      local k = i / 5
      love.graphics.setColor(0.10 + 0.12 * k, 0.16 + 0.16 * k, 0.32 + 0.22 * k, 1)
      love.graphics.rectangle("fill", ox, oy + math.floor(H * i / 6), W, math.ceil(H / 6) + 1)
    end
    love.graphics.setColor(0.12, 0.30, 0.45, 1)
    love.graphics.rectangle("fill", ox, oy + math.floor(H * 0.82), W, H)
    local hills =
      { { 0.55, 0.22, 0.40, 0.18 }, { 0.68, 0.30, 0.52, 0.24 }, { 0.80, 0.36, 0.60, 0.30 } }
    for hi, hc in ipairs(hills) do
      love.graphics.setColor(hc[2], hc[3], hc[4], 1)
      for x = 0, W, 4 do
        local y = H * hc[1]
          + math.cos(x / (60 + hi * 25) + hi) * 14
          + math.sin(x / (23 + hi * 7)) * 5
        love.graphics.rectangle("fill", ox + x, oy + math.floor(y), 4, H)
      end
    end
    G.ui("map_causeway.png", ox + 8, oy + 8, "magenta", 0.8)
  end
  -- drifting clouds (two shapes, parallax 0.6)
  local sp = self:strips()
  for i = 1, 5 do
    local cw = sp.cloud.fw
    local speed = 6 + i * 2.5
    local x = ((self.t * speed + i * 173) % (L.mapW + cw * 2)) - cw
    local y = 12 + (i * 37) % math.max(1, math.floor(L.mapH * 0.35))
    G.drawFrame(sp.cloud, ((i - 1) % sp.cloud.n) + 1, ox * 0.6 + x, oy * 0.6 + y, 1, 0.75)
  end
end

function Map:drawPaths()
  local G = self.app.G
  for _, e in ipairs(self.edges) do
    local ax, ay = self:toScreen(self:nodeMapPos(e[1]))
    local bx, by = self:toScreen(self:nodeMapPos(e[2]))
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    local n = math.max(2, math.floor(len / 10))
    for i = 1, n - 1 do
      local u = i / n
      G.color("beige", 0.85)
      love.graphics.rectangle(
        "fill",
        math.floor(ax + dx * u) - 1,
        math.floor(ay + dy * u) - 1,
        3,
        3
      )
      G.color("rust_dark", 0.6)
      love.graphics.rectangle(
        "fill",
        math.floor(ax + dx * u) - 1,
        math.floor(ay + dy * u) + 2,
        3,
        1
      )
    end
  end
end

function Map:nodeFrame(slot, host)
  local state = self:stageState(host)
  if state == "online" then
    return NF.online
  elseif state == "connecting" then
    return NF.unvisited -- drawn with the amber pulse in drawNodes
  elseif state == "error" then
    return NF.error
  elseif slot == self.sel then
    return NF.selected
  end
  return NF.unvisited
end

function Map:drawNodes()
  local app = self.app
  local G = app.G
  local sp = self:strips()
  Lobby = Lobby or require("src.scenes.lobby")
  local ST = app.core.ST
  for slot = 1, #self.nodes.platforms do
    local host = self:hostAt(slot)
    local sx, sy = self:toScreen(self:nodeMapPos(slot))
    local lift = (self.lift[slot] and self.lift[slot].y) or 0
    local breathe = 1 + 0.02 - 0.02 * math.cos(self.t * math.pi + slot)
    local state, rec = self:stageState(host)
    local key = host and app.sessions.hostKey(host)
    -- keepalive glow pulse: three rings expanding + fading as the pulse decays
    if rec and rec.pulse and rec.pulse > 0 then
      local r = NODE / 2 + 4 + (1 - rec.pulse) * 8
      for ring = 0, 2 do
        love.graphics.setColor(0.45, 0.82, 0.49, (0.55 - ring * 0.15) * rec.pulse)
        local rr = r + ring * 2
        love.graphics.rectangle("line", sx - rr + 0.5, sy - 8 - rr + 0.5, rr * 2 - 1, rr * 2 - 1)
      end
    end
    local flick = self.flicker and self.flicker.key == key
    local frame = self:nodeFrame(slot, host)
    if flick and Lobby.ledFrame(G, ST, ST.ERROR, self.flicker.t) ~= G.LED.error then
      frame = NF.unvisited
    end
    love.graphics.push()
    love.graphics.translate(sx, sy - 8 - lift)
    love.graphics.scale(breathe, breathe)
    local a = host and 1 or 0.55
    -- connecting: amber, pulsing 0.6..1.0 (STYLE 7.3) over the unvisited disc
    local amber = (state == "connecting" and not flick) and (0.8 + 0.2 * math.sin(self.t * 6)) or 0
    if sp.node.placeholder then
      -- procedural platform: a rounded plate coloured by state
      G.color(PLACEHOLDER_COL[frame], a)
      if amber > 0 then
        love.graphics.setColor(AMBER[1], AMBER[2], AMBER[3], a * amber)
      end
      love.graphics.rectangle("fill", -14, -6, 28, 12)
      G.color("rust_dark", a)
      love.graphics.rectangle("fill", -14, 4, 28, 3)
    else
      G.drawFrame(sp.node, frame, -NODE / 2, -NODE / 2, 1, a)
      if amber > 0 then
        love.graphics.setColor(AMBER[1], AMBER[2], AMBER[3], 0.75 * amber)
        love.graphics.draw(sp.node.img, sp.node.quads[frame], -NODE / 2, -NODE / 2)
      end
    end
    love.graphics.pop()
    -- state LED
    if host then
      local led = G.LED.off
      if state == "online" then
        led = G.LED.on
      elseif state == "connecting" then
        led = Lobby.ledFrame(G, ST, ST.CONNECTING, self.t)
      elseif state == "error" then
        led = Lobby.ledFrame(G, ST, ST.ERROR, self.t)
      end
      G.drawFrame(G.ledStrip(8), led, sx + NODE / 2 - 6, sy - NODE / 2 - 8 - lift, 1, 1)
    end
    -- planted flag on online stages (waves)
    if state == "online" then
      local f = self.flags[key]
      local plant = f and math.min(1, f.t / 0.3) or 1
      local wave = 1 + math.floor(self.t * 4) % sp.flag.n
      G.drawAnchored(
        sp.flag,
        wave,
        sx - 12,
        sy - 12 - lift - (1 - app.fx.ease.expoOut(plant)) * 16,
        1,
        plant
      )
    end
  end
end

function Map:drawHero()
  local G = self.app.G
  local sp = self:strips()
  local hero = self.hero
  if hero.page ~= self.page then
    return
  end
  local sx, sy = self:toScreen(hero.x, hero.y)
  local hop = 0
  if hero.state == "hop" then
    local u = math.min(1, hero.hopT / HOP_T)
    hop = math.sin(u * math.pi) * 10
  end
  local feetY = sy - 8 - hop
  if hero.state == "walk" then
    local frame = 1 + math.floor(hero.walkT * 8) % sp.walk.n
    G.drawAnchored(sp.walk, frame, sx, feetY, hero.facing, hero.alpha)
  else
    local frame = 1 + math.floor(self.t * 2) % sp.idle.n
    G.drawAnchored(sp.idle, frame, sx, feetY, hero.facing, hero.alpha)
  end
end

function Map:stageName(host)
  if not host then
    return "+ Connect server"
  end
  local _, rec = self:stageState(host)
  return require("src.config").nodeName(host, rec)
end

function Map:drawLabel(slot, pop)
  local app = self.app
  local G = app.G
  local host = self:hostAt(slot)
  if not host then
    return
  end
  local sx, sy = self:toScreen(self:nodeMapPos(slot))
  local name = self:stageName(host)
  local line = app.sessions.hostKey(host)
  local state, rec = self:stageState(host)
  local key = app.sessions.hostKey(host)
  local err = self.errors[key] or (state == "error" and rec and app.core.error(rec.id)) or nil
  local pad = 14
  local thumb = (self.hover == slot) and rec and app.view(rec.id).canvas or nil
  local w = math.min(
    self.L.viewW - 16,
    math.min(360, math.max(180, G.textWidth(name) + pad * 2, G.uiWidth(line) + pad * 2))
  )
  local contentW = w - pad * 2
  local h = pad * 2 + 16 + 6 + 8 + (err and 16 or 0) + (thumb and 70 or 0)
  local x = math.floor(math.max(8, math.min(sx - w / 2, self.L.viewW - w - 8)))
  local y = math.floor(sy - NODE / 2 - 12 - h)
  if y < 60 then
    y = math.floor(sy + NODE / 2 + 8)
  end
  y = math.max(60, math.min(y, self.L.infoY - h - 8))
  self.labelBounds = { x = x, y = y, w = w, h = h, padding = pad }
  love.graphics.push("all")
  love.graphics.translate(x + w / 2, y + h)
  love.graphics.scale(pop, pop)
  love.graphics.translate(-w / 2, -h)
  G.frame(0, 0, w, h, 1)
  UI.clip(pad, pad, contentW, h - pad * 2)
  G.text(UI.fit(name, contentW, true), pad, pad, "white")
  UI.label(line, pad, pad + 22, contentW, state == "error" and "alarm" or "cyan")
  local yy = pad + 38
  if err then
    UI.label(err, pad, yy, contentW, "alarm")
    yy = yy + 16
  end
  if thumb then
    local pw, ph = thumb:getDimensions()
    local tw, th = contentW, 60
    local k = math.min(tw / pw, th / ph)
    G.panel(pad, yy, tw, th, "black", "dblue")
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.draw(
      thumb,
      pad + math.floor((tw - pw * k) / 2),
      yy + math.floor((th - ph * k) / 2),
      0,
      k,
      k
    )
  end
  love.graphics.pop()
end

local function fmtDur(sec)
  sec = math.max(0, math.floor(sec))
  if sec >= 3600 then
    return string.format("%dh%02dm", math.floor(sec / 3600), math.floor(sec % 3600 / 60))
  end
  return string.format("%dm%02ds", math.floor(sec / 60), sec % 60)
end

function Map:drawInfo()
  local app = self.app
  local G = app.G
  local L = self.L
  local vw = app.D.vw
  local y = L.infoY
  love.graphics.setColor(0.10, 0.12, 0.31, 0.97)
  love.graphics.rectangle("fill", 0, y, vw, L.infoH)
  G.color("rust")
  love.graphics.rectangle("fill", 0, y, vw, 1)
  local host = self:hostAt(self.sel)
  local state, rec = self:stageState(host)
  local col = STATE_COL[state]
  local rowsEnd = y + 34
  local bw = require("src.lobby_views").disconnect(
    app,
    self.buttons,
    rec,
    vw - 8,
    y + 4,
    self:selectionFocus()
  )
  UI.label(
    "STAGE " .. self.sel .. "  page " .. (self.page + 1) .. "/" .. self.pages,
    8,
    y + 6,
    vw - bw - 24,
    "rust"
  )
  local name = self:stageName(host)
  G.text(
    UI.fit(name, L.portrait and vw - bw - 24 or math.floor(vw * 0.5) - 16, true),
    8,
    y + 16,
    "white"
  )
  if host then
    local key = app.sessions.hostKey(host)
    local keyTxt = (host.keypath and host.keypath ~= "") and host.keypath or "agent / ~/.ssh/id_*"
    local rows, cols = self.rowTxt, self.rowCol
    clear(rows)
    clear(cols)
    rows[1], cols[1] = key, "cyan"
    rows[2], cols[2] = "key " .. keyTxt, "gray"
    rows[3], cols[3] =
      "last " .. (host.lastUsed and os.date("%Y-%m-%d %H:%M", host.lastUsed) or "never"), "gray"
    rows[4], cols[4] = "keepalive " .. tostring(app.cfg.get().keepaliveSeconds or 15) .. "s", "gray"
    if rec and rec.info and rec.info.created_ms > 0 then
      rows[#rows + 1] = "uptime " .. fmtDur((app.core.nowMs() - rec.info.created_ms) / 1000)
      cols[#cols + 1] = "lgreen"
    end
    local err = self.errors[key] or (state == "error" and rec and app.core.error(rec.id)) or nil
    if err then
      rows[#rows + 1] = "! " .. err
      cols[#cols + 1] = "alarm"
    end
    if L.portrait then
      -- stacked, state first
      G.ui(state:upper(), 8, y + 34, col)
      local ry = y + 46
      for i, txt in ipairs(rows) do
        txt = UI.fit(txt, vw - 16)
        G.ui(txt, 8, ry, cols[i])
        ry = ry + 10
      end
      rowsEnd = ry
    else
      -- two columns
      local cx = math.floor(vw * 0.5)
      local ry = y + 6
      UI.label(state:upper(), cx, ry, vw - bw - 24 - cx, col)
      ry = ry + 10
      for i, txt in ipairs(rows) do
        local k = i - 1
        local colx = (k % 2 == 0) and 8 or cx
        local yy = (k % 2 == 0) and (y + 34 + math.floor(k / 2) * 10)
          or (ry + math.floor(k / 2) * 10)
        local maxW = (k % 2 == 0) and (cx - 16) or (vw - cx - 8)
        if yy < y + 24 and colx == cx then
          maxW = math.min(maxW, vw - bw - 24 - cx)
        end
        txt = UI.fit(txt, maxW)
        G.ui(txt, colx, yy, cols[i])
        rowsEnd = math.max(rowsEnd, yy + 10)
      end
    end
  else
    local txt = "Click this stage or press Enter to connect a server"
    while G.uiWidth(txt) > vw - 16 and #txt > 1 do
      txt = txt:sub(1, -2)
    end
    G.ui(txt, 8, y + 34, "gray")
    rowsEnd = y + 44
  end
  -- page buttons + hints: at the panel's bottom, but never further than a few
  -- rows below the text (a tall portrait panel keeps them next to the info)
  local hy = math.min(y + L.infoH - 14, rowsEnd + 6)
  self.hintY = hy
  UI.hints(HINTS, 8, hy, vw - 60)
  if self.pages > 1 then
    local bx = vw - 44
    G.panel(bx, hy, 16, 12, "ink", "dblue")
    G.ui("<", bx + 4, hy + 2, "yellow")
    self.btnPrev.x, self.btnPrev.y = bx, hy
    self.buttons[#self.buttons + 1] = self.btnPrev
    G.panel(bx + 20, hy, 16, 12, "ink", "dblue")
    G.ui(">", bx + 24, hy + 2, "yellow")
    self.btnNext.x, self.btnNext.y = bx + 20, hy
    self.buttons[#self.buttons + 1] = self.btnNext
  end
  if #self.missing > 0 then
    local txt = "placeholders: " .. table.concat(self.missing, " ")
    while G.uiWidth(txt) > vw - 16 and #txt > 1 do
      txt = txt:sub(1, -2)
    end
    G.ui(txt, 8, hy - 10, "magenta", 0.8)
  end
end

function Map:drawHeader()
  local G = self.app.G
  local vw = self.app.D.vw
  G.panel(0, 0, vw, 30, "navy", "dblue")
  local title = "LOBBY"
  G.ui(title, 9, 7, "black", 0.6)
  G.ui(title, 8, 6, "rust")
  local newW = G.uiWidth("+ NEW") + 14
  local nx = vw - newW - 8
  G.panel(nx, 6, newW, 20, "ink", "cyan")
  G.ui("+ NEW", nx + 7, 12, "yellow")
  self.buttons[#self.buttons + 1] = {
    id = "new",
    x = nx,
    y = 6,
    w = newW,
    h = 20,
    fn = function()
      self:newConnection()
    end,
  }
  require("src.lobby_views").draw(self.app, self.buttons, "map", nx - 5, 6)
end

-- The map page as it lies on screen, clipped to the view (virtual px).
-- Landscape covers the view; portrait leaves letterbox bars above and below.
function Map:mapRectOnScreen()
  local L = self.L
  local mx, my = L.viewX - self.cam.x, L.viewY - self.cam.y
  local x0, y0 = math.max(L.viewX, math.floor(mx)), math.max(L.viewY, math.floor(my))
  local x1 = math.min(L.viewX + L.viewW, math.floor(mx) + L.mapW)
  local y1 = math.min(L.viewY + L.viewH, math.floor(my) + L.mapH)
  return { x0 = x0, y0 = y0, w = math.max(0, x1 - x0), h = math.max(0, y1 - y0) }
end

function Map:draw()
  clear(self.buttons)
  local app = self.app
  local D = app.D
  local L = self.L
  love.graphics.setScissor(D.ox * D.s, (D.oy + L.viewY) * D.s, L.viewW * D.s, L.viewH * D.s)
  -- letterbox: black outside the map page, then everything on the map
  -- (backdrop, clouds, paths, stages, hero, label) clipped to the page
  self.app.G.color("black")
  love.graphics.rectangle("fill", L.viewX, L.viewY, L.viewW, L.viewH)
  local px, py = self:mapRectOnScreen()
  love.graphics.setScissor((D.ox + px.x0) * D.s, (D.oy + px.y0) * D.s, px.w * D.s, px.h * D.s)
  self:drawBackground()
  self:drawPaths()
  self:drawNodes()
  self:drawHero()
  love.graphics.setScissor(D.ox * D.s, (D.oy + L.viewY) * D.s, L.viewW * D.s, L.viewH * D.s)
  -- the stage label is HUD: it may hang over the letterbox bar
  local label = self.hover or self.sel
  if label then
    self:drawLabel(label, label == self.sel and self.labelPop.s or 1)
  end
  love.graphics.setScissor()
  self:drawHeader()
  self:drawInfo()
end

Map.fitFor = Map.fit
return Map
