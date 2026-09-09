-- Password prompt overlay: { title, onSubmit(password) }. Enter submits,
-- Esc cancels. The value is never stored by this overlay.

local UI = require("src.ui")

local Pw = {}
Pw.__index = Pw

local W, H = 300, 92

function Pw.new(app, params)
  local s = setmetatable({}, Pw)
  s.app = app
  s.params = params or {}
  s.field = UI.field("", "", { masked = true, maxLen = 256 })
  s.field.focused = true
  s.t = 0
  return s
end

function Pw:update(dt)
  self.t = self.t + dt
end

function Pw:keypressed(key, m)
  if key == "escape" then
    self.app.pop(self)
    if self.params.onCancel then
      self.params.onCancel()
    end
  elseif key == "return" or key == "kpenter" then
    local v = self.field.value
    self.app.pop(self)
    if self.params.onSubmit then
      self.params.onSubmit(v)
    end
  else
    self.field:keypressed(key, m)
  end
end

function Pw:textinput(t)
  self.field:textinput(t)
end

function Pw:draw()
  local app = self.app
  local G, D = app.G, app.D
  local a = self.alpha or 1
  local w = math.min(W, D.vw - 16)
  local x, y = UI.frame(self.params.title or "PASSWORD", w, H, D.vw, D.vh, a, "icon_key")
  UI.label(self.params.prompt or "password for this host", x + 12, y + 28, w - 24, "gray", a)
  self.field:draw(x + 12, y + 40, w - 24, self.t, 0)
  UI.hints({ { "Enter", "connect" }, { "Esc", "cancel" } }, x + 12, y + H - 20, w - 24)
end

return Pw
