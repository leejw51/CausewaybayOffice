-- Search overlay: live fuzzy list from Core.search. Enter opens the session.

local UI = require("src.ui")

local Search = {}
Search.__index = Search

local W, H = 340, 210

function Search.new(app)
  local s = setmetatable({}, Search)
  s.app = app
  s.field = UI.field(
    "",
    "",
    { placeholder = "name, host, user…", historyKey = "search.sessions", restore = true }
  )
  s.field.focused = true
  s.results = {}
  s.sel = 1
  s.t = 0
  s.last = nil
  s:refresh()
  return s
end

function Search:refresh()
  local q = self.field.value
  self.results = self.app.core.search(q)
  self.last = q
  if self.sel > #self.results then
    self.sel = math.max(1, #self.results)
  end
end

function Search:update(dt)
  self.t = self.t + dt
  if self.field.value ~= self.last then
    self:refresh()
  end
end

function Search:open()
  local id = self.results[self.sel]
  if id == nil then
    return
  end
  local app = self.app
  app.audio.play("select")
  app.pop(self)
  if app.sceneName == "terminal" and app.scene.id == id then
    return
  end
  app.switch("terminal", { id = id })
end

function Search:keypressed(key, m)
  local app = self.app
  if key == "escape" then
    app.pop(self)
  elseif key == "return" or key == "kpenter" then
    self:open()
  elseif key == "up" then
    self.sel = math.max(1, self.sel - 1)
    app.audio.play("click")
  elseif key == "down" or key == "tab" then
    self.sel = math.min(#self.results, self.sel + 1)
    app.audio.play("click")
  else
    self.field:keypressed(key, m)
  end
end

function Search:textinput(t)
  self.field:textinput(t)
end

function Search:layout()
  local D = self.app.D
  local w, h = math.min(W, D.vw - 8), math.min(H, D.vh - 8)
  local visible = math.max(1, math.floor((h - 84) / 18))
  local first = math.max(1, self.sel - visible + 1)
  return w, h, math.floor((D.vw - w) / 2), math.floor((D.vh - h) / 2), first, visible
end

function Search:mousepressed(mx, my, b)
  if b ~= 1 then
    return
  end
  local D = self.app.D
  local W, H, x, y, first, visible = self:layout()
  for i = first, math.min(#self.results, first + visible - 1) do
    if UI.inside(mx, my, x + 6, y + 54 + (i - first) * 18, W - 12, 18) then
      self.sel = i
      self:open()
      return
    end
  end
  if not UI.inside(mx, my, x, y, W, H) then
    self.app.pop(self)
  end
end

function Search:draw()
  local app = self.app
  local G, D = app.G, app.D
  local a = self.alpha or 1
  local W, H, _, _, first, visible = self:layout()
  local x, y = UI.frame("SEARCH SESSIONS", W, H, D.vw, D.vh, a, "icon_search")
  self.field:draw(x + 12, y + 28, W - 24, self.t, 0)
  local ry = y + 54
  local ST = app.core.ST
  if #self.results == 0 then
    G.ui("no match", x + 10, ry + 4, "dgray")
  end
  for i = first, math.min(#self.results, first + visible - 1) do
    local id = self.results[i]
    local rec = app.sessions.get(id)
    local name = rec and rec.name or app.core.getName(id)
    local host = rec and app.cfg.who(rec.user, rec.host) or ""
    local selected = i == self.sel
    if selected then
      G.panel(x + 10, ry, W - 20, 18, "ink", "neon_pink")
    end
    local led = "gray"
    if rec then
      if rec.state == ST.CONNECTED then
        led = "green"
      elseif rec.state == ST.CONNECTING then
        led = "yellow"
      elseif rec.state == ST.ERROR then
        led = "lred"
      end
    end
    G.led(x + 10, ry + 7, led, true, self.t + i)
    host = UI.fit(host, W * 0.4)
    name = UI.fit(name, W - G.uiWidth(host) - 40, true)
    G.text(name, x + 18, ry + 1, selected and "neon_pink" or "white")
    G.ui(host, x + W - G.uiWidth(host) - 10, ry + 5, "cyan")
    ry = ry + 18
  end
  UI.hints(
    { { "Enter", "open" }, { "↑↓", "select" }, { "Esc", "close" } },
    x + 12,
    y + H - 20,
    W - 24
  )
end

return Search
