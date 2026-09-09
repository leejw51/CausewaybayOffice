-- Compact transfer sheet above the terminal; cwd and filename are inferred.
local UI = require("src.ui")
local Paths = require("src.terminal_files")
local Transfer = {}
Transfer.__index = Transfer
function Transfer.new(app, params)
  local self = setmetatable({ app = app, id = params.id, t = 0, buttons = {} }, Transfer)
  self.rec = app.sessions.get(self.id)
  self.op = params.op or "upload"
  self.auto = params.auto
  local cwd = app.core.cwd(self.id)
  self.cwd = cwd ~= "" and cwd or (self.rec and self.rec.cwd)
  self.source = params.path or ""
  self.field = UI.field("", "", { maxLen = 4096 })
  self.field.focused = true
  if params.details and self.rec and self.rec.lastTransfer and not self.rec.quickTransfer then
    local last = self.rec.lastTransfer
    self.op, self.source, self.cwd = last.op, last.source, last.cwd
    self.field.value = last.destination
    self.done, self.error = last.done, last.error
  elseif self.rec and self.rec.quickTransfer then
    self.job = self.rec.quickTransfer
    self.auto = nil
    self.op, self.source, self.cwd = self.job.op, self.job.source, self.job.cwd
    self.field.value = self.job.destination
  elseif self.op == "upload" and self.source == "" then
    local ok, err = app.core.filesStart(self.id, { op = "pick" })
    if ok then
      self.picking = true
    else
      self.error = err
    end
  else
    self:paths()
  end
  return self
end
function Transfer:paths()
  if self.op == "upload" then
    local name = self.source:match("([^/]+)$")
    self.field.value = name and Paths.resolve(self.cwd, name) or ""
  else
    local detected = self.source
    self.source = Paths.resolve(self.cwd, detected) or ""
    if detected ~= "" and self.source == "" then
      self.auto = nil
    end
    local name = self.source:match("([^/]+)$")
    self.field.value = name
        and (love.filesystem.getUserDirectory():gsub("/+$", "") .. "/Downloads/" .. name)
      or ""
    if self.source == "" then
      self.remote = UI.field(
        "",
        detected ~= "" and detected or (self.cwd and self.cwd .. "/" or ""),
        { maxLen = 4096 }
      )
      self.remote.focused, self.field.focused = true, false
    end
  end
end
function Transfer:update(dt)
  self.t = self.t + dt
  if self.silent and self.closing then
    return
  end
  if self.auto and not self.picking and not self.job then
    self.auto = nil
    if self.source ~= "" and self.field.value ~= "" then
      self:start()
      if self.job then
        self.silent = true
        self.app.pop(self)
        return
      end
    end
  end
  if self.picking then
    local st = self.app.core.filesStatus(self.id)
    if st.state == "done" then
      self.picking = nil
      self.source = st.result.path
      self:paths()
    elseif st.state == "error" or st.state == "cancelled" then
      self.picking, self.auto = nil, nil
      self.error = st.error
    end
  end
  if self.job then
    local st = self.app.core.filesStatus(self.id)
    self.job.status = st
    if st.state == "done" or st.state == "error" or st.state == "cancelled" then
      self.error = st.state ~= "done" and st.error or nil
      self.done = st.state == "done"
      self.job.done, self.job.error, self.job.finishedAt = self.done, self.error, self.app.time
      self.rec.lastTransfer = self.job
      self.rec.quickTransfer = nil
      self.job = nil
      if self.done then
        self.app.toast("File transfer complete")
      end
    end
  end
end
function Transfer:start()
  if self.job or self.picking then
    return
  end
  if self.remote then
    self.source = Paths.resolve(self.cwd, self.remote.value)
    if not self.source then
      self.source = ""
      self.error = "Shell folder unknown: enter an absolute remote path"
      return
    end
    if self.field.value == "" then
      self.field.value = love.filesystem.getUserDirectory():gsub("/+$", "")
        .. "/Downloads/"
        .. (self.source:match("([^/]+)$") or "")
    end
  end
  if self.source == "" or self.field.value == "" then
    self.error = "Enter the full source and destination paths"
    return
  end
  local req = { op = self.op }
  req[self.op == "upload" and "local" or "remote"] = self.source
  req[self.op == "upload" and "remote" or "local"] = self.field.value
  local ok, err = self.app.core.filesStart(self.id, req)
  if ok then
    self.job = {
      op = self.op,
      source = self.source,
      destination = self.field.value,
      cwd = self.cwd,
      name = self.source:match("([^/]+)$"),
      status = { state = "running" },
    }
    self.rec.quickTransfer = self.job
    self.error, self.done = nil, nil
  else
    self.error = err
  end
end
function Transfer:keypressed(key, m)
  if key == "escape" then
    self.app.pop(self)
  elseif key == "return" or key == "kpenter" then
    self:start()
  elseif key == "tab" and self.remote then
    self.remote.focused = not self.remote.focused
    self.field.focused = not self.remote.focused
  elseif not self.job then
    (self.remote and self.remote.focused and self.remote or self.field):keypressed(key, m)
  end
end
function Transfer:textinput(t)
  if not self.job then
    (self.remote and self.remote.focused and self.remote or self.field):textinput(t)
  end
end
function Transfer:mousepressed(mx, my, b)
  if b ~= 1 then
    return
  end
  for _, bt in ipairs(self.buttons) do
    if UI.inside(mx, my, bt[1], bt[2], bt[3], bt[4]) then
      bt[5]()
      return
    end
  end
end
function Transfer:draw()
  if self.auto or (self.closing and self.silent) then
    return
  end
  local G, D = self.app.G, self.app.D
  local w, h = math.min(480, D.vw - 20), self.remote and 210 or 190
  local x, y = UI.frame(
    self.op == "upload" and "UPLOAD FILE" or "DOWNLOAD FILE",
    w,
    h,
    D.vw,
    D.vh,
    self.alpha or 1
  )
  self.buttons = {}
  local function text(s, py, col)
    s = tostring(s or ""):gsub("[%z\1-\31\127]", "?")
    local utf8 = require("utf8")
    while G.uiWidth(s) > w - 28 and #s > 0 do
      s = "…" .. s:sub(utf8.offset(s, 3) or (#s + 1))
    end
    G.ui(s, x + 14, py, col or "gray")
  end
  text("Folder: " .. (self.cwd or "unknown; enter destination"), y + 29, "cyan")
  text("From: " .. self.source, y + 45)
  local fy = y + 77
  if self.remote then
    self.remote:draw(x + 14, y + 59, w - 28, self.t, 0)
    fy = fy + 20
    self.buttons[#self.buttons + 1] = {
      x + 14,
      y + 59,
      w - 28,
      20,
      function()
        self.remote.focused, self.field.focused = true, false
      end,
    }
  end
  text(self.op == "upload" and "Remote filename" or "Save to (local filename)", fy - 13, "yellow")
  self.field:draw(x + 14, fy, w - 28, self.t, 0)
  self.buttons[#self.buttons + 1] = {
    x + 14,
    fy,
    w - 28,
    20,
    function()
      self.field.focused = true
      if self.remote then
        self.remote.focused = false
      end
    end,
  }
  local message = self.error
    or (self.done and "Transfer complete")
    or "Filename filled in. Existing files are kept."
  if self.picking then
    message = "Choose a local file..."
  end
  if self.job then
    local st = self.job.status or {}
    message = string.format(
      "Transferring  %.1f / %.1f MB",
      (st.done or 0) / 1048576,
      (st.total or 0) / 1048576
    )
    G.panel(x + 14, fy + 28, w - 28, 5, "ink", "cyan")
    G.color("cyan")
    love.graphics.rectangle(
      "fill",
      x + 15,
      fy + 29,
      (w - 30) * ((st.total or 0) > 0 and math.min(1, (st.done or 0) / st.total) or 0),
      3
    )
  end
  text(message, y + h - 62, self.error and "alarm" or "lgreen")
  local function button(label, bx, bw, fn)
    G.panel(bx, y + h - 38, bw, 20, "ink", "cyan")
    G.ui(label, bx + 6, y + h - 32, "yellow")
    self.buttons[#self.buttons + 1] = { bx, y + h - 38, bw, 20, fn }
  end
  if self.job then
    button("CANCEL", x + 14, 80, function()
      self.app.core.filesCancel(self.id)
    end)
  elseif not self.done and not self.picking then
    button(self.op:upper(), x + 14, 90, function()
      self:start()
    end)
  end
  if self.done and self.op == "download" then
    button("SHOW FOLDER", x + 14, 114, function()
      local dir = self.field.value:match("^(.*)/[^/]+$") or love.filesystem.getUserDirectory()
      local url = "file://"
        .. dir:gsub("[^%w%-%._~/]", function(c)
          return string.format("%%%02X", string.byte(c))
        end)
      love.system.openURL(url)
    end)
  end
  button("CLOSE", x + w - 90, 76, function()
    self.app.pop(self)
  end)
end
return Transfer
