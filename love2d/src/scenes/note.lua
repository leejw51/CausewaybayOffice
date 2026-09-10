-- Full-screen note reader (READ in the AI panel's NOTES list). The whole
-- note in the terminal font, scrollable. COPY puts it on the clipboard for
-- other tools, TERM reviews it as terminal input, DEL removes it. Esc closes.

local UI = require("src.ui")

local Note = {}
Note.__index = Note

local LINE_H = 16

function Note.new(app, p)
  return setmetatable({
    app = app,
    id = p.id,
    text = p.text or "",
    ts_ms = p.ts_ms,
    sessionId = p.sessionId,
    panel = p.panel,
    scroll = 0,
    maxScroll = 0,
    buttons = {},
  }, Note)
end

function Note:copy()
  love.system.setClipboardText(self.text)
  self.app.fx.flash(0.15, 0.4, 0.86, 0.94, 0.25)
  self.app.audio.play("select")
  self.app.toast("Note copied")
end

-- Review the note as input for the session it was opened from.
function Note:toTerminal()
  if not self.sessionId then
    self.app.toast("No terminal for this note")
    return false
  end
  self.app.push("paste", { id = self.sessionId, text = self.text })
  return true
end

function Note:delete()
  if self.panel and self.panel:deleteNote(self.id) then
    self.app.pop(self)
    return true
  end
  self.app.toast("Could not delete the note")
  return false
end

function Note:scrollBy(dy)
  self.scroll = math.max(0, math.min(self.maxScroll, self.scroll + dy))
end

function Note:keypressed(key, m)
  m = m or {}
  if key == "escape" then
    self.app.pop(self)
  elseif key == "c" or key == "return" or key == "kpenter" then
    self:copy()
  elseif key == "t" then
    self:toTerminal()
  elseif key == "delete" or key == "d" then
    self:delete()
  elseif key == "down" then
    self:scrollBy(LINE_H)
  elseif key == "up" then
    self:scrollBy(-LINE_H)
  elseif key == "pagedown" or key == "space" then
    self:scrollBy(self.pageH or 160)
  elseif key == "pageup" then
    self:scrollBy(-(self.pageH or 160))
  elseif key == "home" then
    self.scroll = 0
  elseif key == "end" then
    self.scroll = self.maxScroll
  end
end

function Note:wheelmoved(_, dy)
  self:scrollBy(-dy * LINE_H * 2)
end

function Note:mousepressed(mx, my, b)
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
  if self.frame and not UI.inside(mx, my, unpack(self.frame)) then
    self.app.pop(self)
  end
end

function Note:draw()
  local app = self.app
  local D, G = app.D, app.G
  local w, h = D.vw - 16, D.vh - 16
  local a = self.alpha or 1
  local x, y = UI.frame("NOTE", w, h, D.vw, D.vh, a)
  self.frame = { x, y, w, h }
  self.buttons = {}
  -- buttons, right aligned in the title row
  local bx = x + w - 12
  local defs = {
    {
      "DEL",
      "lred",
      function()
        self:delete()
      end,
    },
    {
      "TERM",
      "yellow",
      function()
        self:toTerminal()
      end,
    },
    {
      "COPY",
      "cyan",
      function()
        self:copy()
      end,
    },
  }
  for _, d in ipairs(defs) do
    local bw = G.uiWidth(d[1]) + 12
    bx = bx - bw
    G.panel(bx, y + 5, bw, 16, "ink", d[2], a)
    G.ui(d[1], bx + 6, y + 9, d[2], a)
    self.buttons[#self.buttons + 1] = { x = bx, y = y + 5, w = bw, h = 16, fn = d[3] }
    bx = bx - 4
  end
  local _, lines = G.fontTerm:getWrap(self.text, w - 24)
  local meta = string.format("%d line%s", #lines, #lines == 1 and "" or "s")
  if self.ts_ms and self.ts_ms > 0 then
    meta = os.date("%Y-%m-%d %H:%M", math.floor(self.ts_ms / 1000)) .. "   " .. meta
  end
  G.ui(meta, x + 12, y + 30, "gray", a)
  local top = y + 46
  local visible = math.max(1, math.floor((h - 46 - 22) / LINE_H))
  self.pageH = visible * LINE_H
  self.maxScroll = math.max(0, (#lines - visible) * LINE_H)
  self.scroll = math.min(self.scroll, self.maxScroll)
  local first = math.floor(self.scroll / LINE_H) + 1
  for i = first, math.min(#lines, first + visible - 1) do
    G.text(lines[i], x + 12, top + (i - first) * LINE_H, "white", a)
  end
  if #lines > visible then
    -- scroll position
    local trackH = visible * LINE_H
    local knobH = math.max(8, math.floor(trackH * visible / #lines))
    local knobY = top + math.floor((trackH - knobH) * (self.scroll / self.maxScroll))
    G.color("dblue", 0.6 * a)
    love.graphics.rectangle("fill", x + w - 6, top, 2, trackH)
    G.color("cyan", 0.8 * a)
    love.graphics.rectangle("fill", x + w - 6, knobY, 2, knobH)
  end
  UI.hints({
    { "C/Enter", "copy" },
    { "T", "to terminal" },
    { "D", "delete" },
    { "↑↓ PgUp/Dn", "scroll" },
    { "Esc", "close" },
  }, x + 12, y + h - 18, w - 24)
end

return Note
