-- HOT NOTE: edit a remote file in place. NEW NOTE: the same editor on a
-- fresh <fruit><number>.txt in the shell folder, created on Esc / DONE. The terminal's HOT NOTE button arms
-- picking; a click on a filename downloads it (sftp, through the core's file
-- job) into the save directory, this overlay opens on the text, and DONE /
-- Esc write it back with an overwriting upload (atomic rename on the remote,
-- see cbo.h). DISCARD closes without uploading. Nothing is typed into the
-- shell: the transfer is a file job, never a command.
--
-- The editor is deliberately small: lines of UTF-8, a cursor, insert /
-- delete / newline, arrows, Home/End, PgUp/PgDn, clipboard paste, COPY of
-- the whole text. Tabs are kept and drawn as four spaces. Files over
-- MAX_BYTES or with NUL bytes are refused (not a text editor's business).

local UI = require("src.ui")
local utf8 = require("utf8")

local HotNote = {}
HotNote.__index = HotNote

HotNote.MAX_BYTES = 512 * 1024
HotNote.DIR = "hotnotes"
local LINE_H = 16
local TAB = "    "

-- ---- pure editor model (tested on its own) ---------------------------------

local Editor = {}
Editor.__index = Editor
HotNote.Editor = Editor

local function chars(s)
  local out = {}
  for _, cp in utf8.codes(s) do
    out[#out + 1] = utf8.char(cp)
  end
  return out
end

function Editor.new(text)
  local e = setmetatable({}, Editor)
  e.crlf = text:find("\r\n", 1, true) ~= nil
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  e.lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    e.lines[#e.lines + 1] = chars(line)
  end
  if #e.lines == 0 then
    e.lines[1] = {}
  end
  e.row, e.col = 1, 0 -- col = characters before the cursor
  e.dirty = false
  return e
end

function Editor:text()
  local out = {}
  for i, l in ipairs(self.lines) do
    out[i] = table.concat(l)
  end
  return table.concat(out, self.crlf and "\r\n" or "\n")
end

function Editor:line(i)
  return table.concat(self.lines[i] or {})
end

function Editor:insert(s)
  if s == "" then
    return
  end
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
  local first = true
  for piece in (s .. "\n"):gmatch("(.-)\n") do
    if not first then
      self:newline()
    end
    local l = self.lines[self.row]
    for _, c in ipairs(chars(piece)) do
      table.insert(l, self.col + 1, c)
      self.col = self.col + 1
    end
    first = false
  end
  self.dirty = true
end

function Editor:newline()
  local l = self.lines[self.row]
  local rest = {}
  for i = self.col + 1, #l do
    rest[#rest + 1] = l[i]
  end
  for i = #l, self.col + 1, -1 do
    l[i] = nil
  end
  table.insert(self.lines, self.row + 1, rest)
  self.row, self.col = self.row + 1, 0
  self.dirty = true
end

function Editor:backspace()
  if self.col > 0 then
    table.remove(self.lines[self.row], self.col)
    self.col = self.col - 1
    self.dirty = true
  elseif self.row > 1 then
    local prev = self.lines[self.row - 1]
    local cur = table.remove(self.lines, self.row)
    self.col = #prev
    for _, c in ipairs(cur) do
      prev[#prev + 1] = c
    end
    self.row = self.row - 1
    self.dirty = true
  end
end

function Editor:delete()
  local l = self.lines[self.row]
  if self.col < #l then
    table.remove(l, self.col + 1)
    self.dirty = true
  elseif self.lines[self.row + 1] then
    local nxt = table.remove(self.lines, self.row + 1)
    for _, c in ipairs(nxt) do
      l[#l + 1] = c
    end
    self.dirty = true
  end
end

function Editor:move(drow, dcol)
  if dcol ~= 0 then
    local c = self.col + dcol
    if c < 0 and self.row > 1 then
      self.row, self.col = self.row - 1, #self.lines[self.row - 1]
    elseif c > #self.lines[self.row] and self.lines[self.row + 1] then
      self.row, self.col = self.row + 1, 0
    else
      self.col = math.max(0, math.min(#self.lines[self.row], c))
    end
  end
  if drow ~= 0 then
    self.row = math.max(1, math.min(#self.lines, self.row + drow))
    self.col = math.min(self.col, #self.lines[self.row])
  end
end

function Editor:home()
  self.col = 0
end

function Editor:eol()
  self.col = #self.lines[self.row]
end

function Editor:place(row, col)
  self.row = math.max(1, math.min(#self.lines, row))
  self.col = math.max(0, math.min(#self.lines[self.row], col))
end

-- ---- overlay ---------------------------------------------------------------

local function basename(path)
  return path:match("([^/]+)/*$") or path
end

function HotNote.new(app, p)
  local s = setmetatable({}, HotNote)
  s.app = app
  s.id = p.id
  s.remote = p.remote
  s.fileName = basename(p.remote or "")
  s.session = app.sessions and app.sessions.get(p.id)
  s.state = "download" -- download | edit | upload | error
  s.error = nil
  s.editor = nil
  s.scroll = 0 -- first visible line - 1
  s.hscroll = 0 -- characters hidden at the left
  s.buttons = {}
  s.t = 0
  s.blink = 0
  s.uploaded = false
  local root = love.filesystem.getSaveDirectory()
  love.filesystem.createDirectory(HotNote.DIR)
  s.localPath = string.format("%s/%s/%d-%s", root, HotNote.DIR, os.time(), s.fileName)
  if p.create then
    -- NEW NOTE: a fresh file with a random name, no prompt
    s.cwd = p.cwd
    s.created = true
    s.tries = 0
    local name, fruit = HotNote.randomName()
    s.fruit = fruit
    s:startCreate(name)
  elseif p.text then
    -- tests: start on text without a transfer
    s.editor = Editor.new(p.text)
    s.state = "edit"
  else
    local ok, err =
      app.core.filesStart(s.id, { op = "download", remote = s.remote, ["local"] = s.localPath })
    if not ok then
      s.state, s.error = "error", err or "download failed"
    end
  end
  return s
end

-- Load the downloaded bytes into the editor (refuses binaries and big files).
function HotNote:loadLocal()
  local f, err = io.open(self.localPath, "rb")
  if not f then
    return false, err or "cannot read the downloaded file"
  end
  local data = f:read("*a") or ""
  f:close()
  if #data > HotNote.MAX_BYTES then
    return false, string.format("%s is larger than %d KB", self.fileName, HotNote.MAX_BYTES / 1024)
  end
  if data:find("%z") then
    return false, self.fileName .. " is not a text file"
  end
  if not utf8.len(data) then
    return false, self.fileName .. " is not UTF-8 text"
  end
  self.editor = Editor.new(data)
  self.state = "edit"
  return true
end

-- Text files end with a newline (POSIX; vim does the same), so `cat` and
-- zsh do not show a dangling partial line. An empty file stays empty.
function HotNote.finalText(editor)
  local text = editor:text()
  local eol = editor.crlf and "\r\n" or "\n"
  if text ~= "" and text:sub(-#eol) ~= eol then
    text = text .. eol
  end
  return text
end

function HotNote:writeLocal()
  local f, err = io.open(self.localPath, "wb")
  if not f then
    return false, err
  end
  f:write(HotNote.finalText(self.editor))
  f:close()
  return true
end

-- NEW NOTE names: <fruit><number>.txt, e.g. apple0.txt, pear1.txt. The
-- number starts at 0 and steps up while that name exists in the folder.
HotNote.WORDS = {
  "apple",
  "pear",
  "mango",
  "lychee",
  "kiwi",
  "peach",
  "plum",
  "melon",
  "lemon",
  "grape",
  "cherry",
  "banana",
  "papaya",
  "guava",
  "fig",
  "durian",
  "longan",
  "pomelo",
  "berry",
  "lime",
}
function HotNote.randomName(fruit, n)
  fruit = fruit or HotNote.WORDS[math.random(#HotNote.WORDS)]
  return string.format("%s%d.txt", fruit, n or 0), fruit
end

-- Start an empty, dirty editor on <shell folder>/<name>; Esc / DONE create it.
function HotNote:startCreate(name)
  self.fileName = name
  self.remote = self.cwd:gsub("/+$", "") .. "/" .. name
  self.localPath =
    string.format("%s/%s/%d-%s", love.filesystem.getSaveDirectory(), HotNote.DIR, os.time(), name)
  self.editor = self.editor or Editor.new("")
  self.editor.dirty = true
  self.state, self.error = "edit", nil
  return true
end

-- DONE / Esc: upload when changed, else just close.
function HotNote:finish()
  if self.state == "upload" or self.state == "download" then
    return false
  end
  if not self.editor or not self.editor.dirty then
    self.app.pop(self)
    return true
  end
  local ok, err = self:writeLocal()
  if not ok then
    self.error = err
    return false
  end
  ok, err = self.app.core.filesStart(self.id, {
    op = "upload",
    ["local"] = self.localPath,
    remote = self.remote,
    overwrite = not self.created,
  })
  if not ok then
    self.error = err or "upload failed"
    self.app.audio.play("error")
    return false
  end
  self.state, self.error = "upload", nil
  return true
end

function HotNote:discard()
  if self.state == "download" or self.state == "upload" then
    self.app.core.filesCancel(self.id)
  end
  self.app.pop(self)
end

function HotNote:copy()
  if self.editor then
    love.system.setClipboardText(self.editor:text())
    self.app.toast("Copied " .. self.fileName)
    self.app.audio.play("select")
  end
end

function HotNote:update(dt)
  self.t = self.t + dt
  self.blink = self.blink + dt
  if self.state == "download" or self.state == "upload" then
    local st = self.app.core.filesStatus(self.id)
    if st.state == "done" then
      if self.state == "download" then
        local ok, err = self:loadLocal()
        if not ok then
          self.state, self.error = "error", err
          self.app.audio.play("error")
        end
      else
        self.uploaded = true
        self.editor.dirty = false
        self.app.toast("Uploaded " .. self.fileName)
        self.app.audio.play("select")
        self.app.pop(self)
      end
    elseif st.state == "error" or st.state == "cancelled" then
      local err = st.error or (self.state .. " " .. st.state)
      if
        self.state == "upload"
        and self.created
        and self.tries < 20
        and err:find("existing", 1, true)
      then
        -- the random name was taken: pick another and upload again
        self.tries = self.tries + 1
        self:startCreate(HotNote.randomName(self.fruit, self.tries))
        self:finish()
        return
      end
      self.error = err
      self.state = self.editor and "edit" or "error"
      self.app.audio.play("error")
    end
  end
end

function HotNote:keypressed(key, m)
  m = m or {}
  if key == "escape" then
    if self.state == "edit" then
      self:finish()
    else
      self:discard()
    end
    return
  end
  if self.state ~= "edit" then
    return
  end
  local e = self.editor
  if (key == "s" and (m.ctrl or m.gui)) or (key == "return" and m.ctrl) then
    self:finish()
  elseif key == "v" and (m.ctrl or m.gui) then
    local clip = love.system.getClipboardText() or ""
    clip = clip:gsub("[%z\1-\8\11-\12\14-\31\127]", "")
    e:insert(clip)
  elseif key == "c" and (m.ctrl or m.gui) then
    self:copy()
  elseif key == "return" or key == "kpenter" then
    e:newline()
  elseif key == "backspace" then
    e:backspace()
  elseif key == "delete" then
    e:delete()
  elseif key == "left" then
    e:move(0, -1)
  elseif key == "right" then
    e:move(0, 1)
  elseif key == "up" then
    e:move(-1, 0)
  elseif key == "down" then
    e:move(1, 0)
  elseif key == "home" then
    e:home()
  elseif key == "end" then
    e:eol()
  elseif key == "pageup" then
    e:move(-(self.visible or 10), 0)
  elseif key == "pagedown" then
    e:move(self.visible or 10, 0)
  elseif key == "tab" then
    e:insert("\t")
  end
end

function HotNote:textinput(t)
  if self.state == "edit" and utf8.len(t) and not t:find("[%z\1-\31\127]") then
    self.editor:insert(t)
  end
end

function HotNote:wheelmoved(_, dy)
  if self.editor then
    self.scroll = math.max(0, math.min(#self.editor.lines - 1, self.scroll - dy * 3))
  end
end

function HotNote:mousepressed(mx, my, b)
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
  if self.state == "edit" and self.textBox and UI.inside(mx, my, unpack(self.textBox)) then
    local row = self.scroll + math.floor((my - self.textBox[2]) / LINE_H) + 1
    local col = self.hscroll + math.floor((mx - self.textBox[1]) / self.charW + 0.5)
    self.editor:place(row, col)
  end
end

local function shown(l)
  return (table.concat(l):gsub("\t", TAB))
end

function HotNote:draw()
  local app = self.app
  local D, G = app.D, app.G
  local w, h = D.vw - 16, D.vh - 16
  local a = self.alpha or 1
  local title = (self.created and "NEW NOTE  " or "HOT NOTE  ") .. self.fileName
  local x, y = UI.frame(title, w, h, D.vw, D.vh, a)
  self.buttons = {}
  local bx = x + w - 12
  local defs = { {
    "DISCARD",
    "lred",
    function()
      self:discard()
    end,
  } }
  if self.state == "edit" then
    table.insert(defs, 1, {
      "COPY",
      "cyan",
      function()
        self:copy()
      end,
    })
    table.insert(defs, 1, {
      "DONE",
      "green",
      function()
        self:finish()
      end,
    })
  end
  for i = #defs, 1, -1 do
    local d = defs[i]
    local bw = G.uiWidth(d[1]) + 12
    bx = bx - bw
    G.panel(bx, y + 5, bw, 16, "ink", d[2], a)
    G.ui(d[1], bx + 6, y + 9, d[2], a)
    self.buttons[#self.buttons + 1] = { x = bx, y = y + 5, w = bw, h = 16, fn = d[3] }
    bx = bx - 4
  end
  local status
  if self.state == "download" then
    status = "downloading " .. self.remote
  elseif self.state == "upload" then
    status = "uploading " .. self.remote
  elseif self.state == "error" then
    status = "! " .. (self.error or "failed")
  else
    local e = self.editor
    status = string.format(
      "%s   %d line%s   %d:%d%s",
      UI.fit(self.remote, w * 0.5),
      #e.lines,
      #e.lines == 1 and "" or "s",
      e.row,
      e.col + 1,
      e.dirty and "   modified (Esc or DONE uploads)" or ""
    )
    if self.error then
      status = "! " .. self.error .. "   " .. status
    end
  end
  G.ui(UI.fit(status, w - 24), x + 12, y + 30, self.error and "alarm" or "gray", a)
  local top = y + 46
  self.charW = G.textWidth("M")
  local visible = math.max(1, math.floor((h - 46 - 22) / LINE_H))
  self.visible = visible
  local cols = math.max(1, math.floor((w - 24) / self.charW))
  if self.state == "edit" then
    local e = self.editor
    -- keep the cursor in view
    if e.row - 1 < self.scroll then
      self.scroll = e.row - 1
    elseif e.row - 1 >= self.scroll + visible then
      self.scroll = e.row - visible
    end
    local curCol = utf8.len(shown({ unpack(e.lines[e.row], 1, e.col) })) or e.col
    if curCol < self.hscroll then
      self.hscroll = curCol
    elseif curCol >= self.hscroll + cols then
      self.hscroll = curCol - cols + 1
    end
    self.textBox = { x + 12, top, w - 24, visible * LINE_H }
    love.graphics.push("all")
    UI.clip(x + 12, top, w - 24, visible * LINE_H)
    for i = self.scroll + 1, math.min(#e.lines, self.scroll + visible) do
      local text = shown(e.lines[i])
      if self.hscroll > 0 then
        text = text:sub((utf8.offset(text, self.hscroll + 1) or (#text + 1)))
      end
      local ly = top + (i - self.scroll - 1) * LINE_H
      if i == e.row then
        G.color("dblue", 0.35 * a)
        love.graphics.rectangle("fill", x + 12, ly, w - 24, LINE_H)
      end
      G.text(text, x + 12, ly, "white", a)
    end
    if math.floor(self.blink * 2) % 2 == 0 then
      local cx = x + 12 + (curCol - self.hscroll) * self.charW
      local cy = top + (e.row - self.scroll - 1) * LINE_H
      G.color("cyan", 0.9 * a)
      love.graphics.rectangle("fill", cx, cy, 2, LINE_H)
    end
    love.graphics.pop()
    if #e.lines > visible then
      local trackH = visible * LINE_H
      local knobH = math.max(8, math.floor(trackH * visible / #e.lines))
      local knobY = top
        + math.floor((trackH - knobH) * (self.scroll / math.max(1, #e.lines - visible)))
      G.color("dblue", 0.6 * a)
      love.graphics.rectangle("fill", x + w - 6, top, 2, trackH)
      G.color("cyan", 0.8 * a)
      love.graphics.rectangle("fill", x + w - 6, knobY, 2, knobH)
    end
  else
    local dots = string.rep(".", 1 + math.floor(self.t * 3) % 3)
    G.text(
      self.state == "error" and (self.error or "failed") or (self.state .. dots),
      x + 12,
      top,
      self.state == "error" and "alarm" or "cyan",
      a
    )
  end
  local hints
  if self.state == "edit" then
    hints = {
      { "Esc / ^S", "upload + close" },
      { "Cmd+V", "paste" },
      { "Cmd+C", "copy all" },
      { "Tab", "tab" },
    }
  else
    hints = { { "Esc", "cancel" } }
  end
  UI.hints(hints, x + 12, y + h - 18, w - 24)
end

return HotNote
