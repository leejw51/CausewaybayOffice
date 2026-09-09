-- Connect overlay: host / port / user / password / keypath form + recent
-- hosts. Tab cycles fields, Up/Down picks a recent host, Enter connects.

local UI = require("src.ui")

local Connect = {}
Connect.__index = Connect

local W, H = 360, 262

function Connect.new(app, params)
  local s = setmetatable({}, Connect)
  s.app = app
  s.params = params or {}
  local user = os.getenv("USER") or os.getenv("USERNAME") or "root"
  s.fields = {
    UI.field(
      "host",
      "",
      { placeholder = "localhost", historyKey = "connect.host", restore = true }
    ),
    UI.field(
      "port",
      "22",
      { numeric = true, maxLen = 5, historyKey = "connect.port", restore = true }
    ),
    UI.field("user", user, { historyKey = "connect.user", restore = true }),
    UI.field("password", "", { masked = true, placeholder = "(agent / key)" }),
    UI.field("keypath", "", {
      placeholder = "~/.ssh/id_ed25519 (blank = agent)",
      historyKey = "connect.keypath",
      restore = true,
    }),
  }
  s.focus = 1
  s.fields[1].focused = true
  s.recent = app.sessions.hosts
  s.recentSel = 0
  s.error = nil
  s.errorT = 0
  s.t = 0
  return s
end

function Connect:setFocus(i)
  local n = #self.fields
  self.fields[self.focus]:remember()
  self.fields[self.focus].focused = false
  self.focus = ((i - 1) % n) + 1
  self.fields[self.focus].focused = true
end

function Connect:pickRecent(i)
  self.recentSel = i
  local h = self.recent[i]
  if h then
    self.fields[1].value = h.host or ""
    self.fields[2].value = tostring(h.port or 22)
    self.fields[3].value = h.user or ""
    self.fields[5].value = h.keypath or ""
    self.fields[4].value = ""
    self.app.audio.play("click")
  end
end

function Connect:connect()
  local app = self.app
  local host = self.fields[1].value
  if host == "" then
    host = "localhost"
  end
  local port = tonumber(self.fields[2].value)
  if not port or port < 1 or port > 65535 or port ~= math.floor(port) then
    self.error, self.errorT = "Port must be 1..65535", 0
    return
  end
  local cols, rows = app.termGrid()
  local rec, err = app.sessions.open({
    host = host,
    port = port,
    user = self.fields[3].value,
    password = self.fields[4].value,
    keypath = self.fields[5].value,
    cols = cols,
    rows = rows,
    keepalive = app.cfg.get().keepaliveSeconds,
    platform = self.params.platform,
  })
  if not rec then
    self.error = err
    self.errorT = 0
    app.fx.shake(3, 0.25)
    app.audio.play("error")
    return
  end
  self.fields[1].value = host
  for _, field in ipairs(self.fields) do
    field:remember()
  end
  app.audio.play("select")
  app.pop(self)
  if self.params.onOpen then
    self.params.onOpen(rec)
  end
  if self.params.fromTerminal then
    app.switch("terminal", { id = rec.id })
  end
end

function Connect:update(dt)
  self.t = self.t + dt
  self.errorT = self.errorT + dt
end

function Connect:keypressed(key, m)
  local app = self.app
  if key == "escape" then
    app.pop(self)
  elseif key == "tab" then
    self:setFocus(self.focus + (m.shift and -1 or 1))
    app.audio.play("click")
  elseif key == "return" or key == "kpenter" then
    self:connect()
  elseif key == "up" then
    if #self.recent > 0 then
      self:pickRecent(((self.recentSel - 2) % #self.recent) + 1)
    end
  elseif key == "down" then
    if #self.recent > 0 then
      self:pickRecent((self.recentSel % #self.recent) + 1)
    end
  else
    self.fields[self.focus]:keypressed(key, m)
  end
end

function Connect:textinput(t)
  self.fields[self.focus]:textinput(t)
end

function Connect:layout()
  local D = self.app.D
  local w, h = math.min(W, D.vw - 8), math.min(H, D.vh - 8)
  local visible = math.max(0, math.floor((h - 202) / 10))
  local first = math.max(1, self.recentSel - visible + 1)
  return w, h, math.floor((D.vw - w) / 2), math.floor((D.vh - h) / 2), first, visible
end

function Connect:mousepressed(mx, my, b)
  if b ~= 1 then
    return
  end
  local D = self.app.D
  local W, H, x, y, first, visible = self:layout()
  for i = 1, #self.fields do
    local fy = y + 28 + (i - 1) * 24
    if UI.inside(mx, my, x + 12, fy, W - 24, 20) then
      self:setFocus(i)
      return
    end
  end
  local ry = y + 28 + #self.fields * 24 + 14
  for i = first, math.min(#self.recent, first + visible - 1) do
    if UI.inside(mx, my, x + 8, ry + (i - first) * 10, W - 16, 10) then
      self:pickRecent(i)
      return
    end
  end
  if not UI.inside(mx, my, x, y, W, H) then
    self.app.pop(self)
  end
end

function Connect:draw()
  local app = self.app
  local G, D = app.G, app.D
  local a = self.alpha or 1
  local W, H, _, _, first, visible = self:layout()
  local x, y = UI.frame("NEW CONNECTION", W, H, D.vw, D.vh, a, "icon_link")
  love.graphics.setColor(1, 1, 1, a)
  for i, f in ipairs(self.fields) do
    f:draw(x + 12, y + 28 + (i - 1) * 24, W - 24, self.t, 72)
  end
  G.drawIcon("icon_key", x + W - 30, y + 28 + 3 * 24 + 2, 16, a)
  local ry = y + 28 + #self.fields * 24 + 6
  G.ui("FAVORITE SERVERS", x + 12, ry - 2, "dgray")
  ry = ry + 8
  if #self.recent == 0 then
    G.ui("(none yet)", x + 8, ry + 2, "dgray")
  end
  for i = first, math.min(#self.recent, first + visible - 1) do
    local h = self.recent[i]
    local line = string.format("%s@%s:%d", h.user or "", h.host or "", h.port or 22)
    local utf8 = require("utf8")
    while G.uiWidth(line) > W - 28 and #line > 0 do
      line = line:sub(1, (utf8.offset(line, -1) or 1) - 1)
    end
    local selected = i == self.recentSel
    if selected then
      G.panel(x + 10, ry + (i - first) * 10 - 1, W - 20, 10, "ink", "ink")
    end
    G.ui(line, x + 14, ry + (i - first) * 10, selected and "neon_pink" or "gray")
  end
  if self.error then
    local k = math.max(0, 1 - self.errorT / 4)
    G.ui("! " .. self.error, x + 12, y + H - 32, "alarm", 0.4 + 0.6 * k)
  end
  UI.hints(
    { { "Enter", "connect" }, { "Tab", "next field" }, { "^Space", "reuse" }, { "Esc", "cancel" } },
    x + 12,
    y + H - 20,
    W - 24
  )
end

return Connect
