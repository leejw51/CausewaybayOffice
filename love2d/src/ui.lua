-- Minimal retro widgets: text field (utf8-aware, optional masking), key-hint
-- footer, and wrapped body text. All coordinates are virtual px.

local utf8 = require("utf8")
local G = require("src.gfx")

local UI = {}

-- Measure with the font used to draw, preserve UTF-8, and reserve the ellipsis.
function UI.fit(text, width, body)
  text = tostring(text or ""):gsub("[%z\1-\31\127]", " ")
  local measure = body and G.textWidth or G.uiWidth
  width = math.max(0, width)
  if measure(text) <= width then
    return text
  end
  local suffix = "…"
  if measure(suffix) > width then
    return ""
  end
  while #text > 0 and measure(text .. suffix) > width do
    text = text:sub(1, (utf8.offset(text, -1) or 1) - 1)
  end
  return text .. suffix
end

function UI.label(text, x, y, w, color, alpha)
  G.ui(UI.fit(text, w), x, y, color, alpha)
end

-- Scissors use screen pixels, even when overlays are scaled or sliding.
-- Call inside push("all") / pop() to preserve the caller's clipping region.
function UI.clip(x, y, w, h)
  local x0, y0 = love.graphics.transformPoint(x, y)
  local x1, y1 = love.graphics.transformPoint(x + w, y + h)
  love.graphics.intersectScissor(x0, y0, math.max(0, x1 - x0), math.max(0, y1 - y0))
end
local fields = setmetatable({}, { __mode = "k" })
local function core()
  return require("src.core")
end
function UI.update(dt)
  for f in pairs(fields) do
    if f.historyKey and not f.masked then
      if f.observed ~= f.value then
        f.observed, f.pendingAge = f.value, 0
        f:refreshSuggestions()
      elseif f.pendingAge then
        f.pendingAge = f.pendingAge + dt
        if f.pendingAge >= 0.35 then
          if core().inputSave(f.historyKey, f.value, false) then
            f.pendingAge = nil
          end
        end
      end
    end
  end
end
function UI.flush()
  for f in pairs(fields) do
    f:remember()
  end
end

local Field = {}
Field.__index = Field

function UI.field(label, value, opts)
  opts = opts or {}
  local f = setmetatable({}, Field)
  f.label = label
  f.value = value or ""
  f.masked = opts.masked or false
  f.numeric = opts.numeric or false
  f.placeholder = opts.placeholder or ""
  f.maxLen = opts.maxLen or 256
  f.focused = false
  f.blink = 0
  f.historyKey = not f.masked and opts.historyKey or nil
  f.suggestions, f.suggestionIndex = {}, 1
  if f.historyKey then
    if opts.restore then
      local last = core().kvGet("input.draft." .. f.historyKey)
      if
        last ~= ""
        and utf8.len(last)
        and not last:find("[%z\1-\31\127]")
        and utf8.len(last) <= f.maxLen
        and (not f.numeric or last:match("^%d+$"))
      then
        f.value = last
        f.selectAll = true
      end
    end
    f:refreshSuggestions()
  end
  f.observed, f.remembered = f.value, f.value
  fields[f] = true
  return f
end

function Field:refreshSuggestions()
  self.suggestions, self.suggestionIndex = {}, 1
  if not self.historyKey or self.masked then
    return
  end
  for _, value in ipairs(core().inputSearch(self.historyKey, self.value)) do
    if
      value ~= self.value
      and utf8.len(value)
      and utf8.len(value) <= self.maxLen
      and not value:find("[%z\1-\31\127]")
      and (not self.numeric or value:match("^%d+$"))
    then
      self.suggestions[#self.suggestions + 1] = value
    end
  end
end
function Field:remember()
  if self.historyKey and not self.masked and self.remembered ~= self.value then
    if core().inputSave(self.historyKey, self.value, true) then
      self.remembered, self.pendingAge = self.value, nil
    end
  end
end
function Field:acceptSuggestion()
  self:refreshSuggestions()
  local value = self.suggestions[1]
  if not value then
    return false
  end
  self.value = value
  self:remember()
  self:refreshSuggestions()
  return true
end

function Field:textinput(t)
  if not utf8.len(t) or t:find("[%z\1-\31\127]") then
    return false
  end
  if self.numeric and not t:match("^%d+$") then
    return false
  end
  if self.selectAll then
    self.value, self.selectAll = "", false
  end
  if (utf8.len(self.value) or #self.value) >= self.maxLen then
    return false
  end
  local remaining = self.maxLen - (utf8.len(self.value) or #self.value)
  local cut = utf8.offset(t, remaining + 1)
  self.value = self.value .. (cut and t:sub(1, cut - 1) or t)
  return true
end

function Field:backspace()
  if self.selectAll then
    self.value, self.selectAll = "", false
    return
  end
  local off = utf8.offset(self.value, -1)
  if off then
    self.value = self.value:sub(1, off - 1)
  end
end

function Field:keypressed(key, m)
  if key == "a" and m and (m.ctrl or m.gui) then
    self.selectAll = true
    return true
  end
  if key == "space" and m and m.ctrl then
    return self:acceptSuggestion()
  end
  if key == "backspace" then
    if m and (m.alt or m.gui) then
      self.value = ""
    else
      self:backspace()
    end
    return true
  elseif key == "v" and m and (m.gui or (m.ctrl and m.shift)) then
    local clip = love.system.getClipboardText() or ""
    clip = clip:gsub("[\r\n]", "")
    self:textinput(clip)
    return true
  elseif key == "u" and m and m.ctrl then
    self.value = ""
    return true
  end
  return false
end

function Field:display()
  if self.masked then
    return string.rep("*", utf8.len(self.value) or #self.value)
  end
  return self.value
end

-- Draw label at (x, y) and the box to the right (w wide). h = 20.
function Field:draw(x, y, w, t, labelW)
  labelW = labelW or 72
  UI.label(self.label, x, y + 6, math.max(0, labelW - 8), self.focused and "yellow" or "gray")
  local bx = x + labelW
  local bw = w - labelW
  G.panel(bx, y, bw, 20, self.focused and "ink" or "navy", self.focused and "cyan" or "dgray")
  local shown = self:display()
  local col = "white"
  if shown == "" and not self.focused then
    shown = self.placeholder
    col = "dgray"
  end
  -- clip to box: show the tail
  local maxW = math.max(0, bw - 8 - (self.focused and 8 or 0))
  while G.textWidth(shown) > maxW and #shown > 0 do
    local off = utf8.offset(shown, 2) or 2
    shown = shown:sub(off)
  end
  love.graphics.push("all")
  UI.clip(bx + 2, y + 2, bw - 4, 16)
  if self.focused and self.selectAll then
    G.panel(bx + 3, y + 2, G.textWidth(shown) + 2, 16, "dblue", "dblue")
  end
  G.text(shown, bx + 4, y + 2, col)
  if self.focused and self.suggestions[1] then
    local hx = bx + 4 + G.textWidth(shown) + 12
    local hint = "^Space " .. self.suggestions[1]
    while G.uiWidth(hint) > bx + bw - 4 - hx and #hint > 0 do
      hint = hint:sub(1, (utf8.offset(hint, -1) or 1) - 1)
    end
    G.ui(hint, hx, y + 6, "cyan")
  end
  if self.focused and math.floor((t or 0) * 2.5) % 2 == 0 then
    local cx = bx + 4 + G.textWidth(shown)
    G.color("rust")
    love.graphics.rectangle("fill", cx, y + 3, 8, 14)
  end
  love.graphics.pop()
end

-- Footer with key hints: { {"Enter", "open"}, ... }
function UI.hints(items, x, y, w)
  local cx = x
  for _, it in ipairs(items) do
    local kw = G.uiWidth(it[1]) + 6
    local total = kw + 3 + G.uiWidth(it[2])
    if w and cx + total > x + w - 4 then
      break
    end
    G.panel(cx, y, kw, 12, "ink", "dblue")
    G.ui(it[1], cx + 3, y + 2, "yellow")
    cx = cx + kw + 3
    G.ui(it[2], cx, y + 2, "gray")
    cx = cx + G.uiWidth(it[2]) + 10
  end
end

-- Modal frame centred on screen. Returns x, y of the frame.
function UI.frame(title, w, h, vw, vh, alpha, icon)
  w = math.min(w, vw - 8)
  h = math.min(h, vh - 8)
  local x = math.floor((vw - w) / 2)
  local y = math.floor((vh - h) / 2)
  alpha = alpha or 1
  love.graphics.setColor(0.055, 0.063, 0.19, 0.6 * alpha)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  G.frame(x, y, w, h, alpha)
  local tx = x + 12
  if icon then
    G.drawIcon(icon, x + 10, y + 6, 16, alpha)
    tx = tx + 18
  end
  title = UI.fit(title, x + w - 12 - tx)
  G.ui(title, tx + 1, y + 11, "black", 0.6 * alpha)
  G.ui(title, tx, y + 10, "rust", alpha)
  G.color("rust", 0.5 * alpha)
  love.graphics.rectangle("fill", x + 12, y + 22, w - 24, 1)
  return x, y, w, h
end

-- Wrapped text with fontTerm, returns height drawn.
function UI.wrapped(text, x, y, w, colName, a)
  love.graphics.setFont(G.fontTerm)
  G.color(colName or "white", a)
  local _, lines = G.fontTerm:getWrap(text, w)
  love.graphics.printf(text, math.floor(x), math.floor(y), w, "left")
  return #lines * G.fontTerm:getHeight()
end

function UI.wrapHeight(text, w)
  local _, lines = G.fontTerm:getWrap(text, w)
  return #lines * G.fontTerm:getHeight()
end

function UI.inside(mx, my, x, y, w, h)
  return mx >= x and mx < x + w and my >= y and my < y + h
end

return UI
