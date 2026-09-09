-- Small context menu overlay: { items = { {label, fn}, ... }, x, y }.
-- Up/Down/Enter/click pick, Esc closes. Anchored near (x, y) when given.

local UI = require("src.ui")

local Menu = {}
Menu.__index = Menu

local ROW_H = 14

function Menu.new(app, params)
  local s = setmetatable({}, Menu)
  s.app = app
  s.items = params.items or {}
  s.sel = 1
  s.t = 0
  s.title = params.title or "MENU"
  s.w = 150
  for _, it in ipairs(s.items) do
    s.w = math.max(s.w, app.G.uiWidth(it[1]) + 28)
  end
  s.h = 26 + #s.items * ROW_H + 8
  local D = app.D
  s.x = math.floor(math.max(4, math.min((params.x or (D.vw - s.w) / 2), D.vw - s.w - 4)))
  s.y = math.floor(math.max(4, math.min((params.y or (D.vh - s.h) / 2), D.vh - s.h - 4)))
  return s
end

function Menu:update(dt)
  self.t = self.t + dt
end

function Menu:pick(i)
  local it = self.items[i]
  self.app.pop(self)
  if it and it[2] then
    self.app.audio.play("select")
    it[2]()
  end
end

function Menu:keypressed(key)
  if key == "escape" then
    self.app.pop(self)
  elseif key == "up" then
    self.sel = ((self.sel - 2) % #self.items) + 1
    self.app.audio.play("click")
  elseif key == "down" or key == "tab" then
    self.sel = (self.sel % #self.items) + 1
    self.app.audio.play("click")
  elseif key == "return" or key == "kpenter" or key == "space" then
    self:pick(self.sel)
  end
end

function Menu:mousemoved(mx, my)
  for i = 1, #self.items do
    if UI.inside(mx, my, self.x, self.y + 22 + (i - 1) * ROW_H, self.w, ROW_H) then
      self.sel = i
    end
  end
end

function Menu:mousepressed(mx, my, b)
  for i = 1, #self.items do
    if UI.inside(mx, my, self.x, self.y + 22 + (i - 1) * ROW_H, self.w, ROW_H) then
      self:pick(i)
      return
    end
  end
  if b == 1 or b == 2 then
    self.app.pop(self)
  end
end

function Menu:draw()
  local G = self.app.G
  local a = self.alpha or 1
  G.frame(self.x, self.y, self.w, self.h, a)
  G.ui(self.title, self.x + 10, self.y + 8, "rust", a)
  for i, it in ipairs(self.items) do
    local ry = self.y + 22 + (i - 1) * ROW_H
    if i == self.sel then
      G.panel(self.x + 6, ry, self.w - 12, ROW_H - 1, "ink", "neon_pink", a)
    end
    G.ui(it[1], self.x + 12, ry + 3, i == self.sel and "neon_pink" or "white", a)
  end
end

return Menu
