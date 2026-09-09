-- Map 2 lobby: searchable, filtered cards for every live session and saved
-- favorite. Favorites are added by connecting, never by a separate add step.
local UI = require("src.ui")
local Keys = require("src.keys")
local utf8 = require("utf8")
local Map2 = {}
Map2.__index = Map2
Map2.FILTERS = { "All", "Online", "Connecting", "Offline", "Error", "Favorites" }
local COLORS = { Online = "lgreen", Connecting = "amber", Offline = "gray", Error = "alarm" }

local function status(core, rec)
  if not rec then
    return "Offline"
  end
  local st = rec.state or core.state(rec.id)
  if st == core.ST.CONNECTED then
    return "Online"
  elseif st == core.ST.CONNECTING then
    return "Connecting"
  elseif st == core.ST.ERROR then
    return "Error"
  else
    return "Offline"
  end
end

function Map2.matches(entry, query, filter)
  if filter ~= "All" and filter ~= "Favorites" and entry.status ~= filter then
    return false
  end
  if filter == "Favorites" and not entry.favorite then
    return false
  end
  local h = entry.host
  local hay = (
    entry.name
    .. " "
    .. (h.user or "")
    .. "@"
    .. (h.host or "")
    .. ":"
    .. (h.port or 22)
  ):lower()
  for term in query:lower():gmatch("%S+") do
    if not hay:find(term, 1, true) then
      return false
    end
  end
  return true
end

function Map2.new(app, params)
  local s = setmetatable({
    app = app,
    t = 0,
    filter = 1,
    sel = 1,
    scroll = 0,
    entries = {},
    shown = {},
    buttons = {},
    cards = {},
    nextPoll = 0,
  }, Map2)
  s.field = UI.field(
    "",
    "",
    { placeholder = "search name, user, host or port", historyKey = "search.map2", restore = true }
  )
  s.field.focused = true
  s:refresh()
  if params and params.select then
    for i, e in ipairs(s.shown) do
      if e.rec and e.rec.id == params.select then
        s.sel = i
        s:keepSelectedVisible()
        break
      end
    end
  end
  return s
end

function Map2:refresh()
  local S, core = self.app.sessions, self.app.core
  local old = self.shown[self.sel]
  local selectedKey = old and old.key
  local represented, entries = {}, {}
  for _, rec in ipairs(S.list) do
    local key = S.hostKey(rec)
    entries[#entries + 1] = {
      key = "session:" .. rec.id,
      rec = rec,
      host = rec,
      name = rec.name,
      status = status(core, rec),
      favorite = S.findHost(key) ~= nil,
    }
    represented[key] = true
  end
  for _, host in ipairs(S.hosts) do
    local key = S.hostKey(host)
    if not represented[key] then
      entries[#entries + 1] = {
        key = "host:" .. key,
        host = host,
        name = host.label or host.host,
        status = "Offline",
        favorite = true,
      }
    end
  end
  self.entries, self.shown = entries, {}
  for _, e in ipairs(entries) do
    if Map2.matches(e, self.field.value, Map2.FILTERS[self.filter]) then
      self.shown[#self.shown + 1] = e
    end
  end
  self.sel = math.max(1, math.min(self.sel, #self.shown))
  for i, e in ipairs(self.shown) do
    if e.key == selectedKey then
      self.sel = i
      break
    end
  end
  self.lastQuery = self.field.value
  self:layout()
end

function Map2:layout()
  local D = self.app.D
  self.cols = math.max(1, math.floor((D.vw - 12) / 192))
  self.cardW = math.floor((D.vw - 16 - (self.cols - 1) * 8) / self.cols)
  self.cardH = 88
  self.filterButtons = {}
  local x, y = 10, 76
  for i, label in ipairs(Map2.FILTERS) do
    local w = self.app.G.uiWidth(label) + 12
    if x + w > D.vw - 10 then
      x, y = 10, y + 21
    end
    self.filterButtons[i] = { x = x, y = y, w = w }
    x = x + w + 4
  end
  self.top, self.bottom = y + 25, D.vh - 24
  self.visibleRows = math.max(1, math.floor((self.bottom - self.top) / (self.cardH + 8)))
  self.maxScroll = math.max(0, math.ceil(#self.shown / self.cols) - self.visibleRows)
  self.scroll = math.max(0, math.min(self.scroll, self.maxScroll))
end

function Map2:keepSelectedVisible()
  local row = math.floor((self.sel - 1) / self.cols)
  self.scroll = math.max(0, math.min(self.scroll, row))
  self.scroll = math.min(self.maxScroll, math.max(self.scroll, row - self.visibleRows + 1))
end
function Map2:resize()
  self:layout()
  self:keepSelectedVisible()
end
function Map2:update(dt)
  self.t = self.t + dt
  if self.lastQuery ~= self.field.value then
    self.sel, self.scroll = 1, 0
    self:refresh()
  elseif self.t >= self.nextPoll then
    self.nextPoll = self.t + 0.25
    self:refresh()
  end
  local x, y = self:cardPosition(self.sel)
  self.cursor = self.cursor or { x = x, y = y }
  self.cursor.x = self.app.fx.approach(self.cursor.x, x, dt, 16)
  self.cursor.y = self.app.fx.approach(self.cursor.y, y, dt, 16)
end

function Map2:cardPosition(index)
  local i = index - 1 - math.floor(self.scroll) * self.cols
  return 8 + (i % self.cols) * (self.cardW + 8),
    self.top + math.floor(i / self.cols) * (self.cardH + 8)
end

function Map2:selectionFocus()
  local x, y = self:cardPosition(self.sel)
  return {
    x = (x + self.cardW / 2) / self.app.D.vw,
    y = math.max(0, math.min(1, (y + self.cardH / 2) / self.app.D.vh)),
  }
end

function Map2:disconnectMenu(index, mx, my)
  local e = self.shown[index or self.sel]
  if not e or not e.rec then
    return
  end
  self.sel = index or self.sel
  local focus = self:selectionFocus()
  self.app.push("menu", {
    title = e.name,
    x = mx,
    y = my,
    items = {
      {
        "Disconnect",
        function()
          self.app.disconnectSession(e.rec, focus)
        end,
      },
      { "Cancel", function() end },
    },
  })
end
function Map2:setFilter(i)
  self.filter = ((i - 1) % #Map2.FILTERS) + 1
  self.sel, self.scroll = 1, 0
  self:refresh()
end
function Map2:newConnection()
  self.app.push("connect", { fromTerminal = true })
end
function Map2:open(index)
  self.sel = index or self.sel
  local e = self.shown[index or self.sel]
  if not e then
    return
  end
  local app = self.app
  local rec = e.rec
  if rec and app.sessions.get(rec.id) ~= rec then
    self:refresh()
    return
  end
  local current = status(app.core, rec)
  if rec and (current == "Online" or current == "Connecting") then
    app.audio.play("select")
    app.switch("terminal", { id = rec.id })
    return
  end
  local cols, rows = app.termGrid()
  local h = e.host
  local opened, err = app.sessions.open({
    host = h.host,
    user = h.user,
    port = h.port,
    keypath = h.keypath,
    cols = cols,
    rows = rows,
  })
  if opened then
    app.switch("terminal", { id = opened.id })
  else
    app.toast(err or "Connection failed")
  end
end
function Map2:keypressed(key, m)
  local chord = Keys.appChord(key, m)
  if key == "escape" then
    self.field.value = ""
    self:setFilter(1)
  elseif chord == "lobby" then
    return
  elseif chord == "new" then
    self:newConnection()
  elseif chord == "settings" then
    self.app.push("settings")
  elseif chord == "help" then
    self.app.push("help")
  elseif chord == "search" then
    self.app.push("search")
  elseif chord == "rename" then
    local e = self.shown[self.sel]
    if e then
      self.app.push(
        "rename",
        e.rec and { id = e.rec.id }
          or { hostKey = self.app.sessions.hostKey(e.host), initial = e.name }
      )
    end
  elseif chord == "quit" then
    love.event.quit()
  elseif key == "tab" then
    self:setFilter(self.filter + (m.shift and -1 or 1))
  elseif key == "delete" then
    self:disconnectMenu()
  elseif key == "return" or key == "kpenter" then
    self:open()
  elseif key == "up" then
    self.sel = math.max(1, self.sel - self.cols)
    self:keepSelectedVisible()
  elseif key == "down" then
    self.sel = math.min(#self.shown, self.sel + self.cols)
    self:keepSelectedVisible()
  elseif key == "left" then
    self.sel = math.max(1, self.sel - 1)
    self:keepSelectedVisible()
  elseif key == "right" then
    self.sel = math.min(#self.shown, self.sel + 1)
    self:keepSelectedVisible()
  elseif key == "pageup" then
    self:wheelmoved(0, self.visibleRows)
  elseif key == "pagedown" then
    self:wheelmoved(0, -self.visibleRows)
  else
    self.field:keypressed(key, m)
  end
end
function Map2:textinput(t)
  self.field:textinput(t)
end
function Map2:wheelmoved(_, dy)
  self.scroll = math.max(0, math.min(self.maxScroll, self.scroll - dy))
end
function Map2:mousepressed(mx, my, b)
  if b == 2 then
    for _, card in ipairs(self.cards) do
      if UI.inside(mx, my, card.x, card.y, card.w, card.h) then
        self:disconnectMenu(card.index, mx, my)
        return
      end
    end
  end
  if b ~= 1 then
    return
  end
  for _, btn in ipairs(self.buttons) do
    if UI.inside(mx, my, btn.x, btn.y, btn.w, btn.h) then
      btn.fn()
      return
    end
  end
  for _, card in ipairs(self.cards) do
    if UI.inside(mx, my, card.x, card.y, card.w, card.h) then
      self.sel = card.index
      self:open(card.index)
      return
    end
  end
end
local function fit(G, text, width)
  text = tostring(text):gsub("[\r\n\t]", " ")
  if G.uiWidth(text) <= width then
    return text
  end
  while #text > 0 and G.uiWidth(text .. "...") > width do
    text = text:sub(1, (utf8.offset(text, -1) or 1) - 1)
  end
  return text .. "..."
end
function Map2:draw()
  local app = self.app
  local D, G = app.D, app.G
  self:layout()
  self.buttons, self.cards = {}, {}
  app.drawSkyline(self.t, 0.15, D.vh)
  G.panel(0, 0, D.vw, self.top - 4, "navy", "rust")
  G.ui("LOBBY", 10, 8, "rust")
  UI.label(
    string.format("%d sessions  %d favorites", #app.sessions.list, #app.sessions.hosts),
    10,
    34,
    D.vw - 20,
    "gray"
  )
  local x = D.vw - 8
  local function button(label, fn)
    local w = G.uiWidth(label) + 14
    x = x - w
    G.frame(x, 6, w, 22, 1)
    G.ui(label, x + 7, 13, "yellow")
    self.buttons[#self.buttons + 1] = { x = x, y = 6, w = w, h = 22, fn = fn }
    x = x - 5
  end
  button("+ NEW", function()
    self:newConnection()
  end)
  require("src.lobby_views").draw(app, self.buttons, "map2", x, 7)
  self.field:draw(10, 48, D.vw - 20, self.t, 0)
  for i, label in ipairs(Map2.FILTERS) do
    local b = self.filterButtons[i]
    local fx, fy, w = b.x, b.y, b.w
    G.panel(
      fx,
      fy,
      w,
      17,
      self.filter == i and "ink" or "navy",
      self.filter == i and "cyan" or "dblue"
    )
    G.ui(label, fx + 6, fy + 5, self.filter == i and "yellow" or "gray")
    self.buttons[#self.buttons + 1] = {
      x = fx,
      y = fy,
      w = w,
      h = 17,
      fn = function()
        self:setFilter(i)
      end,
    }
  end
  local first = math.floor(self.scroll) * self.cols + 1
  local last = math.min(#self.shown, first + self.visibleRows * self.cols - 1)
  for i = first, last do
    local e = self.shown[i]
    local localIndex = i - first
    local cx = 8 + (localIndex % self.cols) * (self.cardW + 8)
    local cy = self.top + math.floor(localIndex / self.cols) * (self.cardH + 8)
    local col = COLORS[e.status]
    G.frame(cx, cy, self.cardW, self.cardH, 1)
    if i == self.sel then
      G.panel(cx + 3, cy + 3, self.cardW - 6, self.cardH - 6, "ink", "cyan", 0.85)
    end
    G.led(cx + 10, cy + 12, col, true, self.t)
    G.ui(fit(G, e.name, self.cardW - 36), cx + 22, cy + 8, "yellow")
    G.ui(
      fit(G, (e.host.user or "") .. "@" .. (e.host.host or ""), self.cardW - 20),
      cx + 10,
      cy + 26,
      "white"
    )
    G.ui("port " .. (e.host.port or 22), cx + 10, cy + 41, "gray")
    G.ui(e.status, cx + 10, cy + 65, col)
    G.ui(e.favorite and "* favorite" or "session", cx + self.cardW - 92, cy + 65, "cyan")
    self.cards[#self.cards + 1] = { x = cx, y = cy, w = self.cardW, h = self.cardH, index = i }
  end
  if #self.shown == 0 then
    UI.wrapped(
      #self.entries == 0 and "No servers. + NEW connects and saves a favorite."
        or "No matches. Change the search or filter.",
      12,
      self.top + 18,
      D.vw - 24,
      "gray"
    )
  end
  if #self.shown > 0 and self.cursor then
    local x, y, w, h = self.cursor.x, self.cursor.y, self.cardW, self.cardH
    local breathe = 1 + math.sin(self.t * 4) * 0.5
    love.graphics.setColor(0.4, 0.9, 1, 0.8)
    love.graphics.setLineWidth(2)
    for _, corner in ipairs({
      { x, y, 1, 1 },
      { x + w, y, -1, 1 },
      { x, y + h, 1, -1 },
      { x + w, y + h, -1, -1 },
    }) do
      local cx, cy, dx, dy = unpack(corner)
      love.graphics.line(
        cx + dx * 12,
        cy - dy * breathe,
        cx - dx * breathe,
        cy - dy * breathe,
        cx - dx * breathe,
        cy + dy * 12
      )
    end
    love.graphics.setLineWidth(1)
  end
  G.panel(0, D.vh - 24, D.vw, 24, "navy", "dblue")
  local entry = self.shown[self.sel]
  local bw = require("src.lobby_views").disconnect(
    app,
    self.buttons,
    entry and entry.rec,
    D.vw - 8,
    D.vh - 22,
    self:selectionFocus()
  )
  UI.hints({
    { "Enter", "open" },
    { "Tab", "filter" },
    { "↑↓", "select" },
    { "wheel", "scroll" },
    { "Del", "disconnect" },
    { "Esc", "clear filters" },
  }, 10, D.vh - 16, D.vw - bw - 28)
end
return Map2
