-- Lobby: session cards (card_frame 9-slice) on a shelf with the hero and his
-- props. Enter opens, Ctrl+N connects, Ctrl+K search, Ctrl+R rename, Delete
-- closes, Ctrl+, settings, F1 help.

local UI = require("src.ui")
local Keys = require("src.keys")
local utf8 = require("utf8")

local Lobby = {}
Lobby.__index = Lobby

local CARD_W, CARD_H = 176, 96
local GAP = 16
local TOP = 32
local HEADER_H = 24
local SHELF_H = 64

function Lobby.new(app, params)
  local s = setmetatable({}, Lobby)
  s.app = app
  s.sel = params.select and app.sessions.index(params.select) or 1
  s.anim = {} -- id -> {y, a, scale, wasState}
  s.t = 0
  s.scroll = 0
  s.scrollTarget = 0
  s.lastClick = 0
  s.buttons = {}
  return s
end

function Lobby:enter()
  for _, rec in ipairs(self.app.sessions.list) do
    self.anim[rec.id] = { y = 0, a = 1, scale = 1, wasState = rec.state }
  end
end

-- Card columns for a content width; portrait layouts cap at 2.
function Lobby.columnsFor(vw, portrait)
  local n = math.max(1, math.floor((vw - GAP) / (CARD_W + GAP)))
  if portrait then
    n = math.min(2, n)
  end
  return n
end

function Lobby:columns()
  return Lobby.columnsFor(self.app.D.vw, self.app.D.portrait)
end

function Lobby:toMap()
  self.app.audio.play("select")
  self.app.switch("map")
end

function Lobby:cardPos(i)
  local cols = self:columns()
  local c = (i - 1) % cols
  local r = math.floor((i - 1) / cols)
  local totalW = cols * (CARD_W + GAP) - GAP
  local x0 = math.floor((self.app.D.vw - totalW) / 2)
  return x0 + c * (CARD_W + GAP), TOP + r * (CARD_H + GAP) - math.floor(self.scroll)
end

function Lobby:shelfY()
  return self.app.D.vh - SHELF_H
end

function Lobby:update(dt)
  self.t = self.t + dt
  local app = self.app
  local S = app.sessions
  local ST = app.core.ST
  local n = #S.list
  if self.sel > n then
    self.sel = n
  end
  if self.sel < 1 and n > 0 then
    self.sel = 1
  end
  -- forget animations of cards that are gone, so a reused slot id starts
  -- with a fresh slide-in instead of the old card's popped-out state
  for id in pairs(self.anim) do
    if not S.byId[id] then
      self.anim[id] = nil
    end
  end
  for _, rec in ipairs(S.list) do
    local a = self.anim[rec.id]
    if not a then
      a = { y = 0, x = 40, a = 0, scale = 1, wasState = rec.state }
      self.anim[rec.id] = a
      app.fx.tween(a, { x = 0, a = 1 }, 0.32, "expoOut")
    end
    if rec.state == ST.CONNECTED and a.wasState == ST.CONNECTING then
      local i = S.index(rec.id)
      local x, y = self:cardPos(i)
      app.fx.sparkBurst(
        x + CARD_W / 2,
        y + CARD_H / 2,
        24,
        app.G.strip("particle_spark", 4, 16, 16),
        130
      )
      app.audio.play("connect")
    end
    if rec.state == ST.ERROR and a.wasState ~= ST.ERROR then
      app.audio.play("error")
      app.fx.shake(3, 0.25)
    end
    a.wasState = rec.state
    -- (rec.pulse decays in Sessions.update so every scene shares the heartbeat)
    app.view(rec.id):update(dt)
    if rec.state == ST.CONNECTED then
      app.view(rec.id):pollBell()
    end
  end
  -- scroll to keep the selection visible between header and shelf
  if n > 0 then
    local _, y = self:cardPos(self.sel)
    local bottom = self:shelfY() - 8
    if y + CARD_H > bottom then
      self.scrollTarget = self.scrollTarget + (y + CARD_H - bottom)
    elseif y < TOP then
      self.scrollTarget = math.max(0, self.scrollTarget - (TOP - y))
    end
  else
    self.scrollTarget = 0
  end
  self.scroll = app.fx.approach(self.scroll, self.scrollTarget, dt, 14)
end

function Lobby:openSelected()
  local rec = self.app.sessions.list[self.sel]
  if rec then
    self.app.audio.play("select")
    self.app.switch("terminal", { id = rec.id })
  end
end

function Lobby:closeSelected()
  local app = self.app
  local rec = app.sessions.list[self.sel]
  if not rec then
    return
  end
  local a = self.anim[rec.id]
  if a then
    app.fx.tween(a, { scale = 0, a = 0 }, 0.32, "expoIn")
  end
  app.disconnectSession(rec)
end

function Lobby:keypressed(key, m)
  local app = self.app
  local chord = Keys.appChord(key, m)
  local n = #app.sessions.list
  local cols = self:columns()
  if chord == "new" then
    app.push("connect")
  elseif chord == "search" then
    app.push("search")
  elseif chord == "rename" then
    local rec = app.sessions.list[self.sel]
    if rec then
      app.push("rename", { id = rec.id })
    end
  elseif chord == "settings" then
    app.push("settings")
  elseif chord == "help" then
    app.push("help")
  elseif chord == "quit" then
    love.event.quit()
  elseif key == "return" or key == "kpenter" then
    self:openSelected()
  elseif key == "delete" or key == "backspace" then
    self:closeSelected()
  elseif key == "left" then
    self.sel = math.max(1, self.sel - 1)
  elseif key == "right" then
    self.sel = math.min(n, self.sel + 1)
  elseif key == "up" then
    self.sel = math.max(1, self.sel - cols)
  elseif key == "down" then
    self.sel = math.min(n, self.sel + cols)
  elseif key == "n" then
    app.push("connect")
  elseif key == "g" then
    app.switch("map2")
  elseif key == "m" then
    self:toMap()
  elseif key == "tab" then
    if n > 0 then
      self.sel = (self.sel % n) + 1
    end
  elseif key == "escape" then
    app.fx.shake(1, 0.1)
  end
  if key == "left" or key == "right" or key == "up" or key == "down" then
    app.audio.play("click")
  end
end

function Lobby:cardAt(mx, my)
  for i = 1, #self.app.sessions.list do
    local x, y = self:cardPos(i)
    if mx >= x and mx < x + CARD_W and my >= y and my < y + CARD_H then
      return i
    end
  end
  return nil
end

function Lobby:mousepressed(mx, my, b)
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
  local i = self:cardAt(mx, my)
  if i then
    local now = love.timer.getTime()
    if i == self.sel and now - self.lastClick < 0.4 then
      self:openSelected()
    end
    self.sel = i
    self.lastClick = now
    return
  end
  -- ghost "+ new" card
  local gx, gy = self:cardPos(#self.app.sessions.list + 1)
  if UI.inside(mx, my, gx, gy, CARD_W, CARD_H) then
    self.app.push("connect")
  end
end

function Lobby:wheelmoved(_, dy)
  self.scrollTarget = math.max(0, self.scrollTarget - dy * 24)
end

local function stateStyle(ST, st)
  if st == ST.CONNECTED then
    return "lgreen", "ONLINE"
  elseif st == ST.CONNECTING then
    return "amber", "CONNECTING"
  elseif st == ST.ERROR then
    return "alarm", "ERROR"
  elseif st == ST.CLOSED then
    return "gray", "CLOSED"
  end
  return "dgray", "IDLE"
end

-- Which LED frame to show for a state at time t (blink / flicker patterns
-- from STYLE.md).
function Lobby.ledFrame(G, ST, st, t)
  if st == ST.CONNECTED then
    return G.LED.on
  elseif st == ST.CONNECTING then
    return (math.floor(t * 2) % 2 == 0) and G.LED.connecting or G.LED.off
  elseif st == ST.ERROR then
    -- 90ms on / 120ms off x3, then 1.4s pause
    local period = 3 * 0.21 + 1.4
    local u = t % period
    if u < 3 * 0.21 and (u % 0.21) < 0.09 then
      return G.LED.error
    end
    return G.LED.off
  end
  return G.LED.off
end

function Lobby:drawCard(i, rec)
  local app = self.app
  local G, ST = app.G, app.core.ST
  local a = self.anim[rec.id] or { y = 0, x = 0, a = 1, scale = 1 }
  local x, y = self:cardPos(i)
  x, y = x + (a.x or 0), y + (a.y or 0)
  local selected = i == self.sel
  local alpha = a.a
  local pulse = rec.pulse > 0 and (1 + 0.08 * math.sin(rec.pulse * math.pi)) or 1
  local sc = a.scale * pulse
  love.graphics.push()
  love.graphics.translate(x + CARD_W / 2, y + CARD_H / 2)
  love.graphics.scale(sc, sc)
  love.graphics.translate(-CARD_W / 2, -CARD_H / 2)

  local flicker = rec.state == ST.ERROR
    and Lobby.ledFrame(G, ST, rec.state, self.t + i) == G.LED.error
  G.frame(0, 0, CARD_W, CARD_H, alpha, selected and 1 or 0.85)
  if selected then
    local r, g, b = G.rgb("rust")
    love.graphics.setColor(r, g, b, alpha * (0.35 + 0.25 * math.sin(self.t * 4)))
    love.graphics.rectangle("line", 2.5, 2.5, CARD_W - 5, CARD_H - 5)
    love.graphics.rectangle("line", 0.5, 0.5, CARD_W - 1, CARD_H - 1)
  end
  if flicker then
    G.color("alarm", 0.9 * alpha)
    love.graphics.rectangle("line", 1.5, 1.5, CARD_W - 3, CARD_H - 3)
  end

  -- LED + name
  local ledCol, stateTxt = stateStyle(ST, rec.state)
  local led = G.ledStrip(8)
  G.drawFrame(led, Lobby.ledFrame(G, ST, rec.state, self.t + i), 12, 9, 1, alpha)
  local name = rec.name
  local maxNameW = CARD_W - 32
  while G.textWidth(name) > maxNameW and #name > 1 do
    name = name:sub(1, (utf8.offset(name, -1) or 2) - 1)
  end
  if name ~= rec.name then
    name = name:sub(1, (utf8.offset(name, -1) or 2) - 1) .. "…"
  end
  G.text(name, 25, 6, "black", 0.6 * alpha)
  G.text(name, 24, 5, "white", alpha)

  -- host row with link icon
  G.drawIcon("icon_link", 12, 23, 8, alpha)
  local line = rec.user .. "@" .. rec.host
  if rec.port and rec.port ~= 22 then
    line = line .. ":" .. rec.port
  end
  while G.uiWidth(line) > CARD_W - 36 and #line > 1 do
    line = line:sub(1, -2)
  end
  G.ui(line, 22, 24, rec.state == ST.ERROR and "alarm" or "cyan", alpha)

  -- live thumbnail
  local tv = app.view(rec.id)
  local tx, ty, tw, th = 12, 34, CARD_W - 24, 40
  love.graphics.setColor(0.02, 0.03, 0.08, alpha)
  love.graphics.rectangle("fill", tx, ty, tw, th)
  if tv.canvas then
    local pw, ph = tv.canvas:getDimensions()
    local k = math.min(tw / pw, th / ph)
    love.graphics.setColor(1, 1, 1, 0.9 * alpha)
    love.graphics.draw(
      tv.canvas,
      tx + math.floor((tw - pw * k) / 2),
      ty + math.floor((th - ph * k) / 2),
      0,
      k,
      k
    )
  end
  love.graphics.setColor(0.4, 0.86, 0.94, 0.25 * alpha)
  love.graphics.rectangle("line", tx + 0.5, ty + 0.5, tw - 1, th - 1)

  -- bottom row: session icon, dims / heartbeat, state
  G.drawIcon("icon_session", 10, 76, 16, alpha)
  local info = rec.info
  local dims = info and (info.cols .. "x" .. info.rows) or ""
  local stateX = CARD_W - G.uiWidth(stateTxt) - 12
  if rec.state == ST.CONNECTED and info and info.last_ping_ms > 0 then
    local ago = math.max(0, (app.core.nowMs() - info.last_ping_ms) / 1000)
    local hb = dims .. string.format(" hb %ds", math.floor(ago))
    if 26 + G.uiWidth(hb) + 6 <= stateX then
      dims = hb -- only when it fits before the state label
    end
  end
  G.ui(dims, 26, 80, rec.pulse > 0 and "lgreen" or "gray", alpha)
  G.ui(stateTxt, stateX, 80, ledCol, alpha)
  if rec.state == ST.ERROR then
    local err = app.core.error(rec.id)
    while G.uiWidth(err .. "…") > CARD_W - 24 and #err > 1 do
      err = err:sub(1, -2)
    end
    love.graphics.setColor(0, 0, 0, 0.7 * alpha)
    love.graphics.rectangle("fill", tx, ty + th - 12, tw, 12)
    G.ui(err .. "…", tx + 2, ty + th - 10, "alarm", alpha)
  end
  love.graphics.pop()
end

function Lobby:drawGhostCard()
  local app = self.app
  local G = app.G
  local x, y = self:cardPos(#app.sessions.list + 1)
  if y > self:shelfY() then
    return
  end
  love.graphics.setColor(0.5, 0.46, 0.95, 0.45 + 0.15 * math.sin(self.t * 3))
  local dash = 6
  for dx = 0, CARD_W - dash, dash * 2 do
    love.graphics.rectangle("fill", x + dx, y, dash, 1)
    love.graphics.rectangle("fill", x + dx, y + CARD_H - 1, dash, 1)
  end
  for dy = 0, CARD_H - dash, dash * 2 do
    love.graphics.rectangle("fill", x, y + dy, 1, dash)
    love.graphics.rectangle("fill", x + CARD_W - 1, y + dy, 1, dash)
  end
  local msg = "+ new  (Ctrl+N)"
  G.ui(
    msg,
    x + math.floor((CARD_W - G.uiWidth(msg)) / 2),
    y + math.floor(CARD_H / 2) - 4,
    "lblue",
    0.8
  )
end

function Lobby.heroStrip(G)
  -- only the hands/keyboard band (45%..66% of the height) animates
  return G.strip(
    "hero_idle",
    4,
    56,
    nil,
    { mode = "anchor", pick = 2, lockBelow = 0.66, lockAbove = 0.45 }
  )
end

function Lobby:drawShelf()
  local app = self.app
  local G, D = app.G, app.D
  local vw = D.vw
  local sy = self:shelfY()
  -- shelf board
  love.graphics.setColor(0.055, 0.063, 0.19, 0.9)
  love.graphics.rectangle("fill", 0, sy, vw, SHELF_H)
  G.color("rust")
  love.graphics.rectangle("fill", 8, sy, vw - 16, 2)
  G.color("rust_dark")
  love.graphics.rectangle("fill", 8, sy + 2, vw - 16, 1)
  -- hero typing: the two most similar frames (hands up / down), feet pinned
  -- to the shelf at integer px, 3 fps, no bob (the strip's frames drift)
  local hero = Lobby.heroStrip(G)
  local frame = 1 + math.floor(self.t * 3) % hero.n
  G.drawAnchored(hero, frame, 16 + math.floor(hero.fw / 2), sy + 3)
  -- props beside him
  local px = 84
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(G.sprite("prop_dimsum", 32, 32), px, sy - 30)
  love.graphics.draw(G.sprite("prop_milktea", 32, 32), px + 36, sy - 30)
  love.graphics.draw(G.sprite("prop_tram", 48, 30), px + 76, sy - 29)
  -- hints
  UI.hints({
    { "Enter", "open" },
    { "^N", "new" },
    { "^K", "search" },
    { "^R", "rename" },
    { "Del", "close" },
    { "M", "map" },
    { "G", "map2" },
    { "^,", "settings" },
    { "F1", "help" },
  }, 8, D.vh - 14, vw - 16)
end

function Lobby:drawHeader()
  local app = self.app
  local G, D = app.G, app.D
  local vw = D.vw
  local S = app.sessions
  self.buttons = {}
  love.graphics.setColor(0.10, 0.12, 0.31, 0.95)
  love.graphics.rectangle("fill", 0, 0, vw, HEADER_H)
  G.color("rust")
  love.graphics.rectangle("fill", 0, HEADER_H, vw, 1)
  G.ui("CAUSEWAYBAY OFFICE", 9, 5, "black", 0.6)
  G.ui("CAUSEWAYBAY OFFICE", 8, 4, "rust")
  G.ui("LOBBY", 8, 14, "gray")
  local count = string.format("%d / %d sessions", #S.list, app.core.MAX_SESSIONS)
  G.ui(count, math.floor((vw - G.uiWidth(count)) / 2), 8, "white")
  -- state LEDs summary (up to 3 most recent)
  local led = G.ledStrip(8)
  local ST = app.core.ST
  local lx = math.floor((vw + G.uiWidth(count)) / 2) + 10
  for i = math.max(1, #S.list - 2), #S.list do
    local rec = S.list[i]
    if rec then
      G.drawFrame(led, Lobby.ledFrame(G, ST, rec.state, self.t + i), lx, 8, 1, 1)
      lx = lx + 10
    end
  end
  -- toolbar icons (right)
  local icons = {
    {
      "icon_search",
      function()
        app.push("search")
      end,
    },
    {
      "icon_settings",
      function()
        app.push("settings")
      end,
    },
    {
      "icon_ai",
      function()
        app.push("help")
      end,
    },
  }
  local gridW = G.uiWidth("MAP2") + 12
  local mapW = G.uiWidth("MAP") + 12
  local ix = vw - 8 - #icons * 20 - (app.core.mock and 84 or 0) - mapW - gridW - 12
  -- MAP button (key M)
  G.frame(ix, 3, mapW, 18, 1)
  G.ui("MAP", ix + 6, 8, "yellow")
  self.buttons[#self.buttons + 1] = {
    x = ix,
    y = 3,
    w = mapW,
    h = 18,
    fn = function()
      self:toMap()
    end,
  }
  ix = ix + mapW + 6
  G.frame(ix, 3, gridW, 18, 1)
  G.ui("MAP2", ix + 6, 8, "yellow")
  self.buttons[#self.buttons + 1] = {
    x = ix,
    y = 3,
    w = gridW,
    h = 18,
    fn = function()
      app.switch("map2")
    end,
  }
  ix = ix + gridW + 6
  for _, ic in ipairs(icons) do
    G.drawIcon(ic[1], ix, 4, 16)
    self.buttons[#self.buttons + 1] = { x = ix, y = 4, w = 16, h = 16, fn = ic[2] }
    ix = ix + 20
  end
end

function Lobby:draw()
  local app = self.app
  local G, D = app.G, app.D
  local vw, vh = D.vw, D.vh
  local S = app.sessions

  app.drawSkyline(self.t, 0.4, vh)

  -- cards (clipped between header and shelf)
  local sy = self:shelfY()
  love.graphics.setScissor(
    D.ox * D.s,
    (D.oy + HEADER_H + 1) * D.s,
    vw * D.s,
    (sy - HEADER_H - 1) * D.s
  )
  for i, rec in ipairs(S.list) do
    self:drawCard(i, rec)
  end
  self:drawGhostCard()
  if #S.list == 0 then
    local msg = "NO SESSIONS YET"
    local _, gy = self:cardPos(1)
    G.ui(msg, math.floor((vw - G.uiWidth(msg)) / 2), gy + CARD_H + 16, "gray")
  end
  love.graphics.setScissor()

  self:drawShelf()
  self:drawHeader()
end

return Lobby
