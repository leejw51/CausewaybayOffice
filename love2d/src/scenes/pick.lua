-- Local file picker drawn by LÖVE: no system dialog. Folder listings come
-- from the core's async "local" file job; nothing is evaluated by a shell.
-- `params.onPick(path)` runs with the chosen absolute path after the overlay
-- closes. Used by the terminal UPLOAD button.
local UI = require("src.ui")
local utf8 = require("utf8")
local Pick = {}
Pick.__index = Pick
local function join(dir, name)
  return dir:gsub("/+$", "") .. "/" .. name
end
local function parent(path)
  return path:match("^(.*)/[^/]+/?$") or "/"
end
local function size(n)
  n = tonumber(n) or 0
  if n >= 1048576 then
    return string.format("%.1f MB", n / 1048576)
  end
  if n >= 1024 then
    return string.format("%.1f KB", n / 1024)
  end
  return n .. " B"
end
local function home()
  return (love.filesystem.getUserDirectory():gsub("/+$", ""))
end
function Pick.new(app, params)
  local s = setmetatable({
    app = app,
    id = params.id,
    onPick = params.onPick,
    t = 0,
    buttons = {},
    entries = {},
    allEntries = {},
    selected = 1,
    scroll = 0,
    visible = 5,
    hidden = false,
    message = "Choose a file to upload",
  }, Pick)
  local last = app.core.kvGet("files.local")
  s.path = params.path or (last ~= "" and last or "~")
  s.field = UI.field("", s.path, { maxLen = 4096 })
  s:request(s.path)
  return s
end
function Pick:filterEntries()
  self.entries = {}
  for _, row in ipairs(self.allEntries) do
    if (self.hidden or row.name:sub(1, 1) ~= ".") and (row.dir or row.file) then
      self.entries[#self.entries + 1] = row
    end
  end
  self.selected, self.scroll = 1, 0
end
-- Ask the core for a folder. A listing already in flight keeps the newest
-- request pending and issues it when the current one lands.
function Pick:request(path)
  path = path and path ~= "" and path or self.path
  if self.active then
    self.pending = path
    return
  end
  local ok, err = self.app.core.filesStart(self.id, { op = "local", ["local"] = path })
  if ok then
    self.active, self.error = path, nil
  else
    self.error = err
  end
end
function Pick:update(dt)
  self.t = self.t + dt
  if self.active then
    local st = self.app.core.filesStatus(self.id)
    if st.state and st.state ~= "running" then
      self.active = nil
      if st.state == "done" and st.result and st.result.path then
        self.path = st.result.path
        self.field.value = self.path
        self.allEntries = st.result.entries or {}
        self:filterEntries()
        self.error = nil
        self.app.core.kvSet("files.local", self.path)
      else
        self.error = st.error or st.state
      end
    end
  end
  if not self.active and self.pending then
    local path = self.pending
    self.pending = nil
    self:request(path)
  end
end
function Pick:select(index)
  self.selected = math.max(1, math.min(#self.entries, index))
  self.scroll = math.max(0, math.min(self.scroll, self.selected - 1))
  if self.selected > self.scroll + self.visible then
    self.scroll = self.selected - self.visible
  end
end
function Pick:jump(prefix)
  prefix = prefix:lower()
  local n = #self.entries
  for step = 1, n do
    local i = (self.selected + step - 1) % n + 1
    if self.entries[i].name:lower():sub(1, #prefix) == prefix then
      self:select(i)
      return
    end
  end
end
function Pick:pick(path)
  if self.closing then
    return
  end
  self.app.core.kvSet("files.local", self.path)
  self.app.pop(self)
  if self.onPick then
    self.onPick(path)
  end
end
-- Enter / double-click: descend into a folder or choose the file.
function Pick:open()
  local row = self.entries[self.selected]
  if not row then
    return
  end
  if row.dir then
    self:request(join(self.path, row.name))
  elseif row.file then
    self:pick(join(self.path, row.name))
  end
end
function Pick:choose()
  local row = self.entries[self.selected]
  if row and row.file then
    self:pick(join(self.path, row.name))
  elseif row and row.dir then
    self:request(join(self.path, row.name))
  else
    self.error = "Select a file first (Enter opens folders)"
  end
end
function Pick:filedropped(path)
  self:pick(path)
end
function Pick:keypressed(key, m)
  if key == "escape" then
    if self.field.focused then
      self.field.focused = false
      self.field.value = self.path
    else
      self.app.pop(self)
    end
    return
  end
  if key == "l" and (m.ctrl or m.gui) then
    self.field.focused, self.field.selectAll = true, true
    return
  end
  if self.field.focused then
    if key == "return" or key == "kpenter" then
      self.field.focused = false
      self:request(self.field.value)
    else
      self.field:keypressed(key, m)
    end
    return
  end
  local n = #self.entries
  if key == "up" then
    self:select(self.selected - 1)
  elseif key == "down" then
    self:select(self.selected + 1)
  elseif key == "pageup" then
    self:select(self.selected - self.visible)
  elseif key == "pagedown" then
    self:select(self.selected + self.visible)
  elseif key == "home" then
    self:select(1)
  elseif key == "end" then
    self:select(n)
  elseif key == "return" or key == "kpenter" then
    self:open()
  elseif key == "backspace" or key == "left" then
    self:request(parent(self.path))
  elseif key == "right" then
    local row = self.entries[self.selected]
    if row and row.dir then
      self:request(join(self.path, row.name))
    end
  elseif key == "." then
    self.hidden = not self.hidden
    self:filterEntries()
  end
end
function Pick:textinput(t)
  if self.field.focused then
    self.field:textinput(t)
  elseif t ~= "." and not t:find("[%s%c]") then
    self:jump(t)
  end
end
function Pick:mousepressed(mx, my, b)
  if b ~= 1 then
    return
  end
  for _, bt in ipairs(self.buttons) do
    if UI.inside(mx, my, bt.x, bt.y, bt.w, bt.h) then
      bt.fn()
      return
    end
  end
end
function Pick:wheelmoved(_, dy)
  self.scroll =
    math.max(0, math.min(math.max(0, #self.entries - self.visible), self.scroll - dy * 3))
end
function Pick:draw()
  local G, D = self.app.G, self.app.D
  local w, h = math.min(560, D.vw - 16), math.min(440, D.vh - 16)
  local x, y = UI.frame("UPLOAD  /  CHOOSE A FILE", w, h, D.vw, D.vh, self.alpha or 1)
  self.buttons = {}
  local function fit(text, px, py, width, col)
    G.ui(UI.fit(text, width), px, py, col)
  end
  local function hit(px, py, bw, bh, fn)
    self.buttons[#self.buttons + 1] = { x = px, y = py, w = bw, h = bh, fn = fn }
  end
  local function button(label, px, py, bw, fn, enabled)
    G.panel(px, py, bw, 18, "ink", enabled == false and "dgray" or "cyan")
    fit(label, px + 5, py + 5, bw - 10, enabled == false and "dgray" or "yellow")
    if enabled ~= false then
      hit(px, py, bw, 18, fn)
    end
  end
  local busy = self.active ~= nil
  -- Path row: field + UP / GO.
  local rowY = y + 28
  self.field:draw(x + 12, rowY, w - 24 - 76, self.t, 0)
  hit(x + 12, rowY, w - 24 - 76, 20, function()
    self.field.focused, self.field.selectAll = true, true
  end)
  button("UP", x + w - 84, rowY + 1, 32, function()
    self:request(parent(self.path))
  end, not busy)
  button("GO", x + w - 48, rowY + 1, 36, function()
    self.field.focused = false
    self:request(self.field.value)
  end, not busy)
  -- Shortcuts to the usual folders.
  local sy = rowY + 26
  local sx = x + 12
  for _, s in ipairs({
    { "HOME", home() },
    { "DESKTOP", home() .. "/Desktop" },
    { "DOWNLOADS", home() .. "/Downloads" },
    { "DOCUMENTS", home() .. "/Documents" },
  }) do
    local bw = G.uiWidth(s[1]) + 12
    if sx + bw <= x + w - 100 then
      button(s[1], sx, sy, bw, function()
        self:request(s[2])
      end, not busy)
      sx = sx + bw + 4
    end
  end
  button(self.hidden and "HIDE DOTS" or "SHOW DOTS", x + w - 100, sy, 88, function()
    self.hidden = not self.hidden
    self:filterEntries()
  end)
  -- Listing.
  local ly = sy + 24
  local lh = y + h - 78 - ly
  G.panel(x + 12, ly, w - 24, lh, "ink", "cyan")
  self.visible = math.max(1, math.floor((lh - 6) / 16))
  self.scroll = math.max(0, math.min(math.max(0, #self.entries - self.visible), self.scroll))
  for line = 1, self.visible do
    local index = self.scroll + line
    local row = self.entries[index]
    if row then
      local ry = ly + 4 + (line - 1) * 16
      if self.selected == index then
        G.panel(x + 15, ry - 2, w - 30, 16, "dblue", "cyan")
      end
      fit(
        (row.dir and "+ " or "  ") .. row.name .. (row.dir and "/" or ""),
        x + 18,
        ry + 2,
        w - 24 - 72,
        row.dir and "cyan" or "white"
      )
      fit(row.dir and "DIR" or size(row.size), x + w - 70, ry + 2, 53, "gray")
      hit(x + 15, ry - 2, w - 30, 16, function()
        local twice = self.lastClick == index and self.t - (self.clickTime or 0) < 0.35
        self.field.focused = false
        self:select(index)
        self.lastClick, self.clickTime = index, self.t
        if twice then
          self:open()
        end
      end)
    end
  end
  if #self.entries == 0 then
    fit(busy and "Reading folder..." or "No files here", x + 20, ly + 6, w - 40, "gray")
  end
  if #self.entries > self.visible then
    local track = lh - 8
    local knob = math.max(8, math.floor(track * self.visible / #self.entries))
    local top = math.floor((track - knob) * self.scroll / math.max(1, #self.entries - self.visible))
    G.panel(x + w - 17, ly + 4 + top, 3, knob, "cyan", "cyan")
  end
  -- Footer: status, buttons, hints.
  local row = self.entries[self.selected]
  local msg = self.error or (row and row.file and ("Upload " .. row.name) or self.message)
  fit(msg, x + 12, y + h - 70, w - 24, self.error and "alarm" or "lgreen")
  button("UPLOAD", x + 12, y + h - 50, 90, function()
    self:choose()
  end, not busy and row ~= nil)
  button("CLOSE", x + w - 84, y + h - 50, 72, function()
    self.app.pop(self)
  end)
  UI.hints({
    { "Enter", "open / upload" },
    { "Bksp", "up" },
    { "^L", "path" },
    { ".", "dots" },
  }, x + 12, y + h - 24, w - 24)
  fit("or drop a file here", x + 110, y + h - 45, w - 110 - 96, "gray")
end
Pick.join, Pick.parent = join, parent
return Pick
