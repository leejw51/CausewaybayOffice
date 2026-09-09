-- Review generated commands and multiline pastes before sending them.
local UI = require("src.ui")
local Paste = {}
Paste.__index = Paste
function Paste.new(app, p)
  local text = (p.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("[%z\1-\8\11-\31\127]", "")
  return setmetatable({
    app = app,
    id = p.id,
    text = text,
    scroll = 0,
    -- A slot may be reused while this overlay is open; bind to the record.
    session = app.sessions.get(p.id),
  }, Paste)
end
function Paste:keypressed(key)
  if key == "escape" then
    self.app.pop(self)
  elseif key == "return" or key == "kpenter" then
    if
      self.session
      and self.app.sessions.get(self.id) == self.session
      and self.app.core.state(self.id) == self.app.core.ST.CONNECTED
    then
      self.app.core.paste(self.id, self.text)
      self.app.pop(self)
    else
      self.app.toast("Session is no longer connected")
    end
  elseif key == "down" or key == "pagedown" then
    self.scroll = math.min(self.maxScroll or 0, self.scroll + 32)
  elseif key == "up" or key == "pageup" then
    self.scroll = math.max(0, self.scroll - 32)
  end
end
function Paste:draw()
  local app = self.app
  local D, G = app.D, app.G
  local w, h = math.min(420, D.vw - 8), math.min(270, D.vh - 8)
  local x, y = UI.frame("REVIEW TERMINAL INPUT", w, h, D.vw, D.vh, self.alpha)
  G.ui("Sending newlines may run commands.", x + 12, y + 30, "amber")
  local _, lines = G.fontTerm:getWrap(self.text, w - 24)
  local visible = math.max(1, math.floor((h - 80) / 16))
  self.maxScroll = math.max(0, (#lines - visible) * 16)
  local first = math.floor(self.scroll / 16) + 1
  for i = first, math.min(#lines, first + visible - 1) do
    G.text(lines[i], x + 12, y + 46 + (i - first) * 16, "white")
  end
  UI.hints(
    { { "Enter", "send" }, { "Esc", "cancel" }, { "↑↓", "scroll" } },
    x + 12,
    y + h - 18,
    w - 24
  )
end
return Paste
