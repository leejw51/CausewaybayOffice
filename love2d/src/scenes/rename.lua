-- Rename overlay: any UTF-8 name up to 32 chars.

local UI = require("src.ui")
local utf8 = require("utf8")

local Rename = {}
Rename.__index = Rename

local W, H = 300, 92

function Rename.new(app, params)
  local s = setmetatable({}, Rename)
  s.app = app
  s.id = params.id
  s.hostKey = params.hostKey
  local rec = s.id and app.sessions.get(s.id)
  s.field =
    UI.field("", params.initial or (rec and rec.name) or "", { maxLen = 32, historyKey = "rename" })
  s.field.focused = true
  s.error = nil
  s.t = 0
  return s
end

function Rename:update(dt)
  self.t = self.t + dt
end

function Rename:apply()
  local app = self.app
  local name = self.field.value
  local n = utf8.len(name) or 0
  if n == 0 or n > 32 then
    self.error = "1..32 characters"
    app.fx.shake(2, 0.2)
    app.audio.play("error")
    return
  end
  if self.hostKey then
    local h = app.sessions.findHost(self.hostKey)
    if h then
      h.label = name
      app.sessions.saveHosts()
    end
    app.audio.play("select")
    app.pop(self)
  elseif app.sessions.rename(self.id, name) then
    app.audio.play("select")
    app.pop(self)
  else
    self.error = app.core.lastError()
    if self.error == "" then
      self.error = "rename failed"
    end
    app.audio.play("error")
  end
end

function Rename:keypressed(key, m)
  if key == "escape" then
    self.app.pop(self)
  elseif key == "return" or key == "kpenter" then
    self:apply()
  else
    self.field:keypressed(key, m)
  end
end

function Rename:textinput(t)
  self.field:textinput(t)
end

function Rename:draw()
  local app = self.app
  local G, D = app.G, app.D
  local a = self.alpha or 1
  local title = self.hostKey and "RENAME STAGE" or "RENAME SESSION"
  local x, y, W, H = UI.frame(title, W, H, D.vw, D.vh, a, "icon_session")
  self.field:draw(x + 12, y + 28, W - 24, self.t, 0)
  local n = utf8.len(self.field.value) or 0
  local count = string.format("%d/32", n)
  G.ui(count, x + W - 12 - G.uiWidth(count), y + 52, n > 32 and "alarm" or "dgray")
  if self.error then
    UI.label("! " .. self.error, x + 12, y + 52, W - 68, "alarm")
  end
  UI.hints({ { "Enter", "save" }, { "Esc", "cancel" } }, x + 12, y + H - 20, W - 24)
end

return Rename
