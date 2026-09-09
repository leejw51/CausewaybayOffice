-- File browser overlay. Network jobs live in Rust and continue when closed.
local UI = require("src.ui")
local utf8 = require("utf8")
local Files = {}
Files.__index = Files
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
function Files.new(app, params)
  local s = setmetatable({ app = app, id = params.id, t = 0, buttons = {}, focus = 2 }, Files)
  local rec = app.sessions.get(s.id)
  s.rec = rec
  if rec and rec.fileBrowser then
    s.data = rec.fileBrowser
  else
    s.data = {
      panes = {
        {
          path = app.core.kvGet("files.local") ~= "" and app.core.kvGet("files.local") or "~",
          entries = {},
          selected = 1,
          scroll = 0,
        },
        { path = rec and rec.cwd or "~", entries = {}, selected = 1, scroll = 0 },
      },
      queue = { 1, 2 },
      message = "Choose a file, then Upload or Download",
    }
    if rec then
      rec.fileBrowser = s.data
    end
  end
  s.fields = {}
  for i, p in ipairs(s.data.panes) do
    s.fields[i] = UI.field("", p.path, { maxLen = 4096 })
  end
  if params.localPath then
    s:filedropped(params.localPath)
  end
  return s
end
function Files:filterEntries()
  for _, p in ipairs(self.data.panes) do
    p.entries = {}
    for _, row in ipairs(p.allEntries or {}) do
      if self.data.hidden or row.name:sub(1, 1) ~= "." then
        p.entries[#p.entries + 1] = row
      end
    end
    p.selected, p.scroll = 1, 0
  end
end

function Files:request(i, path)
  if self.data.active or self.confirm then
    return
  end
  local p = self.data.panes[i]
  p.path = path and path ~= "" and path or p.path
  self.fields[i].value = p.path
  p.selected, p.scroll = 1, 0
  self.data.queue = { i }
end
function Files:update(dt)
  self.t = self.t + dt
  if self.rec and self.rec.quickTransfer then
    return
  end
  local d, core = self.data, self.app.core
  if d.active then
    local st = core.filesStatus(self.id)
    d.status = st
    if st.state and st.state ~= "running" then
      local active = d.active
      d.active = nil
      if st.state == "done" then
        if active.pane then
          local p = d.panes[active.pane]
          p.path, p.allEntries = st.result.path, st.result.entries or {}
          self:filterEntries()
          p.loaded = true
          self.fields[active.pane].value = p.path
          if active.pane == 1 then
            core.kvSet("files.local", p.path)
          end
        else
          d.message = (active.op == "upload" and "Uploaded: " or "Downloaded: ")
            .. (active.name or "file")
          d.queue = { active.op == "upload" and 2 or 1 }
          self.app.toast(d.message)
        end
        d.error = nil
      else
        d.error = st.error or st.state
        if active.pane then
          d.panes[active.pane].entries = {}
        end
      end
    end
  end
  if not d.active and #d.queue > 0 then
    local i = table.remove(d.queue, 1)
    local req = { op = i == 1 and "local" or "list" }
    req[i == 1 and "local" or "remote"] = d.panes[i].path
    local ok, err = core.filesStart(self.id, req)
    if ok then
      d.active = { pane = i, op = req.op }
    else
      d.error = err
    end
  end
end
function Files:prepare(op, localPath)
  local d = self.data
  if d.active or #d.queue > 0 then
    d.error = "Wait for the current file operation"
    return
  end
  local from = d.panes[op == "upload" and 1 or 2]
  local row = from.entries[from.selected]
  if not localPath and (not row or not row.file) then
    d.error = "Select a file first (Enter opens folders)"
    return
  end
  local source = localPath or join(from.path, row.name)
  local name = source:match("([^/]+)$") or "file"
  local target = join(d.panes[op == "upload" and 2 or 1].path, name)
  self.confirm =
    { op = op, source = source, name = name, field = UI.field("", target, { maxLen = 4096 }) }
  self.confirm.field.focused = true
  for _, f in ipairs(self.fields) do
    f.focused = false
  end
  d.error = nil
end
function Files:filedropped(path)
  -- Keep a dropped file pending until initial folder browsing completes.
  self.droppedPath = path
end
function Files:transfer()
  local c, d = self.confirm, self.data
  if not c or d.active then
    return
  end
  if c.field.value == "" then
    d.error = "Enter a destination filename"
    return
  end
  local req = { op = c.op }
  req[c.op == "upload" and "local" or "remote"] = c.source
  req[c.op == "upload" and "remote" or "local"] = c.field.value
  local ok, err = self.app.core.filesStart(self.id, req)
  if ok then
    d.active = { op = c.op, name = c.name }
    d.error, self.confirm = nil, nil
    d.status = { state = "running", done = 0, total = 0 }
  else
    d.error = err
  end
end
function Files:openSelected()
  local p = self.data.panes[self.focus]
  local row = p.entries[p.selected]
  if row and row.dir then
    self:request(self.focus, join(p.path, row.name))
  end
end
function Files:keypressed(key, m)
  if key == "escape" then
    if self.confirm then
      self.confirm = nil
    else
      self.app.pop(self)
    end
    return
  end
  if self.confirm then
    if key == "return" or key == "kpenter" then
      self:transfer()
    else
      self.confirm.field:keypressed(key, m)
    end
    return
  end
  if key == "." and not self.fields[self.focus].focused then
    self.data.hidden = not self.data.hidden
    self:filterEntries()
    return
  end
  if key == "tab" then
    self.focus = 3 - self.focus
    for _, f in ipairs(self.fields) do
      f.focused = false
    end
    return
  end
  local f = self.fields[self.focus]
  if f.focused then
    if key == "return" or key == "kpenter" then
      self:request(self.focus, f.value)
      f.focused = false
    else
      f:keypressed(key, m)
    end
    return
  end
  local p = self.data.panes[self.focus]
  if key == "up" or key == "down" then
    p.selected = math.max(1, math.min(#p.entries, p.selected + (key == "up" and -1 or 1)))
    p.scroll = math.max(0, math.min(p.scroll, p.selected - 1))
    if p.selected > p.scroll + (p.visible or 5) then
      p.scroll = p.selected - (p.visible or 5)
    end
  elseif key == "return" or key == "kpenter" then
    self:openSelected()
  elseif key == "backspace" then
    self:request(self.focus, parent(p.path))
  elseif key == "u" then
    self:prepare("upload")
  elseif key == "d" then
    self:prepare("download")
  elseif key == "r" then
    self:request(self.focus)
  elseif key == "l" and (m.ctrl or m.gui) then
    f.focused, f.selectAll = true, true
  end
end
function Files:textinput(t)
  if self.confirm then
    self.confirm.field:textinput(t)
  elseif self.fields[self.focus].focused then
    self.fields[self.focus]:textinput(t)
  end
end
function Files:mousepressed(mx, my, b)
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
function Files:wheelmoved(_, dy)
  local p = self.data.panes[self.focus]
  p.scroll = math.max(0, math.min(math.max(0, #p.entries - (p.visible or 5)), p.scroll - dy * 3))
end
function Files:draw()
  local G, D, d = self.app.G, self.app.D, self.data
  if self.droppedPath and not d.active and #d.queue == 0 then
    local path = self.droppedPath
    self.droppedPath = nil
    self:prepare("upload", path)
  end
  local w, h = math.min(660, D.vw - 16), math.min(460, D.vh - 16)
  local x, y = UI.frame("FILES  /  SFTP", w, h, D.vw, D.vh, self.alpha or 1)
  self.buttons = {}
  local function fit(text, px, py, width, col)
    text = tostring(text or ""):gsub("[%z\1-\31\127]", "?")
    local full = text
    while #text > 0 and G.uiWidth(text .. (text == full and "" or "…")) > width do
      text = text:sub(1, (utf8.offset(text, -1) or 1) - 1)
    end
    G.ui(text .. (text == full and "" or "…"), px, py, col)
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
  fit(
    self.rec and (self.rec.user .. "@" .. self.rec.host) or "Session closed",
    x + 12,
    y + 29,
    w - 120,
    "cyan"
  )
  button(d.hidden and "HIDE DOTS" or "SHOW DOTS", x + w - 100, y + 25, 88, function()
    d.hidden = not d.hidden
    self:filterEntries()
  end)
  local busy = d.active ~= nil or #d.queue > 0
  local contentY, contentH = y + 44, h - 140
  if self.confirm then
    local c = self.confirm
    fit(
      c.op == "upload" and "UPLOAD TO SERVER" or "DOWNLOAD TO THIS MAC",
      x + 12,
      contentY + 6,
      w - 24,
      "yellow"
    )
    fit("From: " .. c.source, x + 12, contentY + 28, w - 24, "gray")
    fit("Destination (editable filename)", x + 12, contentY + 50, w - 24, "cyan")
    c.field:draw(x + 12, contentY + 65, w - 24, self.t, 0)
    fit(
      "Existing files are kept. Rename to save another copy.",
      x + 12,
      contentY + 95,
      w - 24,
      "gray"
    )
    button(c.op == "upload" and "UPLOAD" or "DOWNLOAD", x + 12, y + h - 86, 100, function()
      self:transfer()
    end, not busy)
    button("BACK", x + 120, y + h - 86, 68, function()
      self.confirm = nil
    end)
  else
    local stacked = w < 440
    for i, p in ipairs(d.panes) do
      local pw = stacked and w - 24 or math.floor((w - 32) / 2)
      local ph = stacked and math.floor((contentH - 8) / 2) or contentH
      local px = x + 12 + (stacked and 0 or (i - 1) * (pw + 8))
      local py = contentY + (stacked and (i - 1) * (ph + 8) or 0)
      G.panel(px, py, pw, ph, "ink", self.focus == i and "cyan" or "dgray")
      fit(
        i == 1 and "LOCAL" or "REMOTE",
        px + 6,
        py + 6,
        pw - 85,
        self.focus == i and "yellow" or "gray"
      )
      button("UP", px + pw - 67, py + 1, 28, function()
        self.focus = i
        self:request(i, parent(p.path))
      end, not busy)
      button("GO", px + pw - 35, py + 1, 30, function()
        self.focus = i
        self:request(i, self.fields[i].value)
      end, not busy)
      self.fields[i]:draw(px + 4, py + 22, pw - 8, self.t, 0)
      hit(px + 4, py + 22, pw - 8, 20, function()
        self.focus = i
        for j, f in ipairs(self.fields) do
          f.focused = j == i
        end
        self.fields[i].selectAll = true
      end)
      p.visible = math.max(1, math.floor((ph - 48) / 16))
      for line = 1, p.visible do
        local index = p.scroll + line
        local row = p.entries[index]
        if row then
          local ry = py + 46 + (line - 1) * 16
          if p.selected == index then
            G.panel(px + 3, ry - 2, pw - 6, 16, "dblue", self.focus == i and "cyan" or "dblue")
          end
          local suffix = row.dir and "/" or ""
          local sz = row.dir and "DIR" or size(row.size)
          fit(
            (row.dir and "+ " or "  ") .. row.name .. suffix,
            px + 6,
            ry + 2,
            pw - 66,
            row.dir and "cyan" or "white"
          )
          fit(sz, px + pw - 58, ry + 2, 53, "gray")
          hit(px + 3, ry - 2, pw - 6, 16, function()
            local twice = self.lastClick == i .. ":" .. index
              and self.t - (self.clickTime or 0) < 0.35
            self.focus, p.selected = i, index
            for _, f in ipairs(self.fields) do
              f.focused = false
            end
            self.lastClick, self.clickTime = i .. ":" .. index, self.t
            if twice then
              self:openSelected()
            end
          end)
        end
      end
      if #p.entries == 0 then
        fit(busy and "Loading..." or "No files", px + 8, py + 49, pw - 16, "gray")
      end
    end
    local by, bw = y + h - 86, math.floor((w - 36) / 4)
    button("UPLOAD", x + 12, by, bw, function()
      self:prepare("upload")
    end, not busy)
    button("DOWNLOAD", x + 16 + bw, by, bw, function()
      self:prepare("download")
    end, not busy)
    button("SHELL DIR", x + 20 + bw * 2, by, bw, function()
      self:request(2, self.app.core.cwd(self.id) ~= "" and self.app.core.cwd(self.id) or "~")
    end, not busy)
    button("REFRESH", x + 24 + bw * 3, by, bw, function()
      self:request(self.focus)
    end, not busy)
  end
  local st = d.status or {}
  local msg = d.error or d.message
  if d.active then
    msg = d.active.pane and "Reading folder..."
      or (d.active.op .. "  " .. size(st.done) .. " / " .. size(st.total))
    local ratio = (tonumber(st.total) or 0) > 0 and math.min(1, (st.done or 0) / st.total) or 0
    G.panel(x + 12, y + h - 40, w - 112, 5, "ink", "dgray")
    G.color("cyan")
    love.graphics.rectangle("fill", x + 13, y + h - 39, (w - 114) * ratio, 3)
    button("CANCEL", x + w - 90, y + h - 48, 78, function()
      self.app.core.filesCancel(self.id)
      d.queue = {}
    end)
  end
  fit(msg, x + 12, y + h - 60, w - 24, d.error and "alarm" or "lgreen")
  fit("Drop a file to upload  |  Tab switch  Enter open", x + 12, y + h - 30, w - 95, "gray")
  button("CLOSE", x + w - 72, y + 4, 60, function()
    self.app.pop(self)
  end)
end
Files.join, Files.parent = join, parent
return Files
