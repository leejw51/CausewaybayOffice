-- Terminal: tab strip + term_view + status bar for one session.
-- Esc goes to the shell as a raw ESC; Ctrl+Esc or a double-tap Esc (300 ms)
-- returns to the lobby. Ctrl+Tab / Ctrl+Shift+Tab cycle sessions with a
-- horizontal slide, Ctrl+Space toggles the AI side panel, Ctrl+= / Ctrl+-
-- zoom the grid (1x / 2x). A learned completion is shown as ghost text after
-- the cursor; Right arrow or Ctrl+Space accepts it (Ctrl+Space is the macOS
-- input-source switch on many keyboards, so Right is the reliable one).
-- Everything else goes to the ssh session.
--
-- Geometry: the chrome (tab strip, status bar, AI panel) lives in virtual px
-- at the UI scale D.s; the grid itself is drawn in *screen* px at
-- D.termZoom so an 80x24 grid fits a 1080x800 window with the bezel on.
-- self.ox/self.oy are the grid origin in virtual px, self.px/self.py the
-- same in screen px (integers), self.gw/self.gh the grid size in virtual px.

local Keys = require("src.keys")
local UI = require("src.ui")
local AIPanel = require("src.scenes.ai")

local Term = {}
Term.__index = Term

local TAB_H = 16
local CWD_H = 16
-- {label, has icon, min virtual width}: optional buttons leave narrow strips.
local TAB_BUTTONS = {
  { "< LOBBY", true },
  { "DISCONNECT", false },
  { "AI CLOSE", false, 440 },
  { "UPLOAD", false },
  { "DOWNLOAD", false },
  { "RENAME", false },
  { "AUTO NOTE", false },
  { "HOT NOTE", false },
  { "NEW NOTE", false },
}
local STATUS_H = 16
local PAD = 4
local ESC_DOUBLE = 0.3
local BACK_HINT = "F2 lobby  F1 help"

function Term.new(app, params)
  local s = setmetatable({}, Term)
  s.app = app
  s.id = params.id
  s.t = 0
  s.slide = { x = 0 }
  s.prev = nil -- {view, x} sliding out
  s.ai = nil
  s.aiOpen = false
  s.aiW = { w = 0 }
  s.dragging = false
  s.lastEsc = -1
  s.buttons = {}
  s.bells = 0 -- bells seen (tests / scripted QA read this)
  s.hover = {} -- button id -> lift (px), tweened
  s.toast = nil -- first-visit hint {a, t}
  s.resizes = 0 -- cbo_session_resize calls issued by this scene
  s.statusRight = "" -- what the status bar drew on the right (tests / QA read this)
  s.statusRightX = 0
  s.statusLeftEnd = 0
  s.icons = {
    {
      "icon_ai",
      function()
        s:toggleAI()
      end,
    },
    {
      "icon_search",
      function()
        app.push("search")
      end,
    },
  }
  s.crtOpts = { crt = true, barrel = 0, scanline = 0.12, vignette = 0.22 }
  s.prevOpts =
    { crt = true, barrel = 0, scanline = 0.12, vignette = 0.22, showCursor = false, alpha = 0.7 }
  return s
end

function Term:enter()
  self:layout()
  local cfg = self.app.cfg.get()
  if not cfg.seenTermHint then
    cfg.seenTermHint = true
    self.app.cfg.save()
    self.toast = { a = 0, t = 0 }
    self.app.fx.tween(self.toast, { a = 1 }, 0.4, "expoOut")
  end
end

function Term:toMap()
  self.app.audio.play("select")
  self.app.switch("map", { fromTerminal = true })
end

function Term:fileTarget(mx, my)
  local Paths = require("src.terminal_files")
  local tv = self:view()
  local selected = tv:selectedText()
  if selected and selected ~= "" and not selected:find("\n", 1, true) then
    return Paths.clean(selected)
  end
  if mx < self.ox or mx >= self.ox + self.gw or my < self.oy or my >= self.oy + self.gh then
    return nil
  end
  local cx, cy = self:cellAt(mx, my)
  local token = Paths.at(tv, cx, cy)
  return token and token.name or nil
end
-- Navigate only at an empty, recognized prompt. A path check may take a
-- moment; any intervening input/output invalidates the original click.
function Term:canNavigate()
  local core = self.app.core
  return core.canComplete(self.id) and core.typing(self.id) == "" and core.cwd(self.id) ~= ""
end
function Term:changeFolder(path)
  if not self:canNavigate() then
    self.app.toast("Finish the current command before changing folders")
    return false
  end
  local command = require("src.sessions").cdCommand(path)
  if not command then
    return false
  end
  self:write(command)
  self:view().sel = nil
  return true
end
function Term:parentFolder()
  local path = require("src.terminal_files").resolveLiteral(self.app.core.cwd(self.id), "..")
  if path then
    self:changeFolder(path)
  end
end
function Term:probeFolder(click)
  local core = self.app.core
  if
    not click
    or self.folderProbe
    or not self:canNavigate()
    or click.gen ~= core.generation(self.id)
    or click.cwd ~= core.cwd(self.id)
  then
    return
  end
  local path = require("src.terminal_files").resolveLiteral(click.cwd, click.name)
  if path and core.probePath(self.id, path) then
    self.folderProbe = { path = path, gen = click.gen, cwd = click.cwd }
  end
end
function Term:updateFolderProbe()
  local pending, core = self.folderProbe, self.app.core
  if not pending then
    return
  end
  if
    not self:canNavigate()
    or pending.gen ~= core.generation(self.id)
    or pending.cwd ~= core.cwd(self.id)
  then
    self.folderProbe = nil
    return
  end
  local st = core.probeStatus(self.id)
  if not st.state or st.state == "running" then
    return
  end
  self.folderProbe = nil
  -- Files, missing paths and ordinary output words remain normal text.
  if st.state == "done" and st.result and st.result.dir then
    self:changeFolder(pending.path)
  end
end

function Term:resetFileCursor()
  if self.fileCursorActive then
    love.mouse.setCursor()
    self.fileCursorActive = nil
  end
end

function Term:toggleDownloadPick()
  self:resetFileCursor()
  self.downloadPicking = not self.downloadPicking
  self.hotNotePicking = false
  self.dragging = false
  self:view().sel = nil
  self.completionBox, self.transferBox = nil, nil
  if self.downloadPicking then
    self.app.toast("Click a filename to download. Esc cancels.")
  end
end

-- HOT NOTE: arm picking; the next filename click downloads the file into an
-- editor overlay that uploads it back when closed (scenes/hotnote.lua).
function Term:toggleHotNotePick()
  self:resetFileCursor()
  self.hotNotePicking = not self.hotNotePicking
  self.downloadPicking = false
  self.dragging = false
  self:view().sel = nil
  self.completionBox, self.transferBox = nil, nil
  if self.hotNotePicking then
    self.app.toast("Click a filename to edit it. Esc cancels.")
  end
end

-- NEW NOTE: name a file, write it in the editor, upload it into the shell
-- folder when done. Needs a known shell folder.
function Term:newNote()
  self.hotNotePicking, self.downloadPicking = false, false
  self:resetFileCursor()
  local cwd = self.app.core.cwd(self.id)
  if cwd == "" then
    self.app.toast("Shell folder unknown: run cd first")
    self.app.audio.play("error")
    return false
  end
  self.app.push("hotnote", { id = self.id, create = true, cwd = cwd })
  return true
end

-- Open the editor on a remote file named in the terminal (relative to the
-- shell folder when not absolute).
function Term:hotNote(name)
  self.hotNotePicking = false
  self:resetFileCursor()
  local Paths = require("src.terminal_files")
  local path = Paths.resolve(self.app.core.cwd(self.id), name)
  if not path then
    self.app.toast("Shell folder unknown: run cd first or use an absolute path")
    self.app.audio.play("error")
    return false
  end
  self.app.push("hotnote", { id = self.id, remote = path })
  return true
end

function Term:download(path)
  self.downloadPicking, self.hotNotePicking = false, false
  self:resetFileCursor()
  if not path then
    local mx, my = self.app.D.toVirtual(love.mouse.getPosition())
    path = self:fileTarget(mx, my)
  end
  self.app.push("transfer", { id = self.id, op = "download", path = path, auto = path ~= nil })
end
-- UPLOAD: an in-app local file picker (scenes/pick.lua); the chosen file
-- goes straight into the shell folder through the quick transfer sheet.
function Term:upload()
  self.downloadPicking, self.hotNotePicking = false, false
  self:resetFileCursor()
  if self.app.hasOverlay("pick") then
    return
  end
  local app, id = self.app, self.id
  app.push("pick", {
    id = id,
    onPick = function(path)
      app.push("transfer", { id = id, op = "upload", path = path, auto = true })
    end,
  })
end

-- Context menu (right-click on the grid, wheel over the top bar).
function Term:openMenu(mx, my)
  local app = self.app
  local filename = self:fileTarget(mx, my)
  app.push("menu", {
    title = "SESSION",
    x = mx,
    y = my,
    items = {
      {
        filename and ("Download " .. (require("utf8").len(filename) > 30 and filename:sub(
          1,
          (require("utf8").offset(filename, 28) or #filename) - 1
        ) .. "…" or filename)) or "Download file...",
        function()
          self:download(filename)
        end,
      },
      {
        "Upload file to this folder...",
        function()
          self:upload()
        end,
      },
      {
        filename and ("Hot note: edit " .. filename) or "Hot note: click a file to edit",
        function()
          if filename then
            self:hotNote(filename)
          else
            self:toggleHotNotePick()
          end
        end,
      },
      {
        "New note in this folder...",
        function()
          self:newNote()
        end,
      },
      {
        "Auto note (screen -> AI -> note)",
        function()
          self:autoNote()
        end,
      },
      {
        "Recent transfer / show download folder",
        function()
          local rec = app.sessions.get(self.id)
          if rec and (rec.quickTransfer or rec.lastTransfer) then
            app.push("transfer", { id = self.id, details = true })
          else
            app.toast("No transfers in this session yet")
          end
        end,
      },
      {
        "Files: upload / download  (^Shift+F)",
        function()
          app.push("files", { id = self.id })
        end,
      },
      {
        "Back to lobby  (F2)",
        function()
          self:toLobby()
        end,
      },
      {
        "Rename  (^R)",
        function()
          app.push("rename", { id = self.id })
        end,
      },
      {
        "Disconnect session",
        function()
          app.disconnectSession(app.sessions.get(self.id))
        end,
      },
      {
        "Help  (F1)",
        function()
          app.push("help")
        end,
      },
    },
  })
end

function Term:leave()
  self.folderProbe, self.folderClick = nil, nil
  self.downloadPicking = false
  self:resetFileCursor()
  if self.ai then
    self.ai:close()
  end
end

-- AI panel width (virtual px): up to 256 / 42% of the content, but it
-- yields so the grid keeps 80 columns whenever the window allows, and it
-- never goes below 140 (about 15 chat characters per line).
function Term.aiWidthFor(D)
  local w = math.min(256, math.floor(D.vw * 0.42))
  local keep80 = D.vw - PAD * 2 - math.ceil(80 * 8 * D.termZoom / D.s)
  return math.max(140, math.min(w, keep80))
end

-- Where the AI panel docks: beside the grid (landscape) or below it
-- (portrait: the grid keeps the full width and at least 24 rows).
function Term.aiDock(D)
  return D.portrait and "bottom" or "right"
end

function Term.aiHeightFor(D)
  local rowsPx = math.ceil(24 * 16 * D.termZoom / D.s)
  local free = D.vh - TAB_H - CWD_H - STATUS_H - PAD * 2
  local h = math.floor(D.vh * 0.45)
  -- Short portrait windows still need a readable chat, even when 24 terminal
  -- rows and a useful chat cannot both fit. Tall portrait keeps those 24 rows.
  return math.min(math.max(144, math.min(h, free - rowsPx)), math.max(100, free - 96))
end

-- Panel size along its dock axis (width when right, height when bottom).
function Term.aiSizeFor(D)
  if Term.aiDock(D) == "bottom" then
    return Term.aiHeightFor(D)
  end
  return Term.aiWidthFor(D)
end

function Term:aiWidth()
  return Term.aiSizeFor(self.app.D)
end

-- Tab strip rows: the session name always gets printed at the top. When the
-- nav buttons leave no room beside them (portrait, narrow windows) the name,
-- host and index move to a second title row instead of being cut to "…".
function Term.toolbar(D, G)
  local buttons, x, row = {}, 4, 0
  local limit = D.vw - 56
  for _, b in ipairs(TAB_BUTTONS) do
    if not b[3] or D.vw >= b[3] then
      local w = G.uiWidth(b[1]) + (b[2] and 26 or 12)
      if x + w > limit and x > 4 then
        x, row = 4, row + 1
      end
      buttons[b[1]] = { x = x, y = row * TAB_H, w = w }
      x = x + w + 4
    end
  end
  return buttons, row + 1, x
end

function Term.titleRows(D, rec, G)
  if not rec or not G then
    return 1
  end
  local _, rows, x = Term.toolbar(D, G)
  local room = D.vw - x - 68
  local need = G.uiWidth(rec.name or "")
    + 10
    + G.uiWidth(require("src.config").who(rec.user, rec.host))
    + 10
    + G.uiWidth("[00/00]")
  return rows + (need > room and 1 or 0)
end

-- Height of the chrome above the grid (tab strip, plus the title row).
function Term:chromeTop()
  local app = self.app
  return TAB_H * Term.titleRows(app.D, app.sessions.get(self.id), app.G) + CWD_H
end

-- Free area for the grid given the AI panel size along its dock axis.
function Term.availFor(D, aiSize, top)
  local availW = D.vw - PAD * 2
  local availH = D.vh - (top or (TAB_H + CWD_H)) - STATUS_H - PAD * 2
  if Term.aiDock(D) == "bottom" then
    availH = availH - aiSize
  else
    availW = availW - aiSize
  end
  return availW, availH
end

-- Grid the terminal scene would give a session right now (used by the
-- connect dialog / --demo so a session opens at its final size).
function Term.grid(D, aiOpen)
  local availW, availH = Term.availFor(D, aiOpen and Term.aiSizeFor(D) or 0)
  return D.termGrid(availW, availH)
end

-- Compute grid + resize the session to fit the available area. The session
-- is resized only when the grid actually changed (window resize, bezel
-- toggle, zoom, AI panel open/close).
function Term:layout()
  local app = self.app
  local D = app.D
  local zoom = D.termZoom
  local aiW = self.aiOpen and self:aiWidth() or 0
  local top = self:chromeTop()
  self.top = top
  local availW, availH = Term.availFor(D, aiW, top)
  local cols, rows = D.termGrid(availW, availH, zoom)
  self.cols, self.rows = cols, rows
  self.zoom = zoom
  -- cell size in virtual px (fractional when zoom < D.s)
  self.cellW, self.cellH = 8 * zoom / D.s, 16 * zoom / D.s
  self.gw, self.gh = cols * self.cellW, rows * self.cellH
  -- origin: centred in the free area, snapped to whole screen pixels
  self.px = PAD * D.s + math.floor((availW - self.gw) * D.s / 2)
  self.py = (top + PAD) * D.s + math.floor((availH - self.gh) * D.s / 2)
  self.ox, self.oy = self.px / D.s, self.py / D.s
  self.aiTargetW = aiW
  if self.id ~= nil and app.sessions.get(self.id) then
    local info = app.core.info(self.id)
    if info and (info.cols ~= cols or info.rows ~= rows) then
      app.core.resize(self.id, cols, rows)
      self.resizes = self.resizes + 1
      self:view().dirty = true -- re-snapshot now, not at the next generation
    end
  end
end

function Term:resize()
  if self.aiTween then
    self.app.fx.cancel(self.aiTween)
    self.aiTween = nil
  end
  self:layout()
  self.aiW.w = self.aiTargetW
end

-- RETRO button: the cool-retro-term stages and the cursor trail together.
function Term:toggleRetro()
  self.app.toggleRetro()
end

-- PRIVACY button: ids, hosts, addresses and ports draw as stars (screen capture).
function Term:togglePrivacy()
  self.app.togglePrivacy()
end

-- Zoom button: 1x -> 2x -> 1x.
function Term:cycleZoom()
  local D = self.app.D
  self:setZoom(D.termZoom >= 2 and 1 or D.termZoom + 1)
end

function Term:setZoom(z)
  local D = self.app.D
  if D.setTermZoom(z) ~= self.zoom then
    self.app.cfg.get().termZoom = D.termZoom
    self.app.cfg.save()
    self:layout()
    self.app.audio.play("click")
    self.app.fx.flash(0.12, 1, 1, 1, 0.12)
  else
    self.app.fx.shake(1, 0.1)
  end
end

function Term:view()
  return self.app.view(self.id)
end

function Term:cycle(dir)
  self.folderProbe, self.folderClick = nil, nil
  self.downloadPicking = false
  self:resetFileCursor()
  local app = self.app
  local rec = app.sessions.neighbor(self.id, dir)
  if not rec or rec.id == self.id then
    app.fx.shake(1, 0.1)
    return
  end
  local D = app.D
  self.prev = { view = self:view(), x = 0, id = self.id }
  app.fx.tween(self.prev, { x = -dir * D.vw }, 0.32, "expoOut", function()
    self.prev = nil
  end)
  self.id = rec.id
  self.slide.x = dir * D.vw
  app.fx.tween(self.slide, { x = 0 }, 0.32, "expoOut")
  app.audio.play("select")
  if self.ai then
    self.ai:close()
    self.ai = AIPanel.new(app, self.id)
  end
  self:layout()
end

-- The panel slides (expo) over the old grid; the session is resized once,
-- when the slide has finished, so the shell sees a single SIGWINCH.
-- The visible screen as text (trailing blanks and empty rows dropped).
function Term:screenText()
  local tv = self:view()
  if not tv or not tv.cells or not tv.rows or not tv.cols then
    return ""
  end
  local lines = {}
  for row = 0, tv.rows - 1 do
    lines[#lines + 1] = tv:rowText(row, 0, tv.cols - 1)
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return table.concat(lines, "\n")
end

-- AUTO NOTE: capture the screen, open the panel in note mode and let it
-- summarize (with a key) and save. One click, nothing to type.
function Term:autoNote()
  local app = self.app
  local text = self:screenText()
  if text == "" then
    app.toast("Nothing on screen to note")
    app.audio.play("error")
    return false
  end
  local rec = app.sessions.get(self.id)
  local where = rec and app.cfg.who(rec.user, rec.host) or ""
  local cwd = app.core.cwd(self.id)
  local header = "AUTO NOTE  " .. (rec and rec.name or "") .. "  " .. where
  if cwd ~= "" then
    header = header .. "  " .. cwd
  end
  header = header .. "  " .. os.date("%Y-%m-%d %H:%M")
  if not self.aiOpen then
    self:toggleAI()
  elseif not self.ai then
    self.ai = AIPanel.new(app, self.id)
  end
  local result, err = self.ai:autoNote(text, header)
  if not result then
    app.toast(err or "Auto note failed")
    return false
  end
  app.toast(result == "summarizing" and "Auto note: summarizing the screen…" or "Auto note saved")
  return true
end

function Term:toggleAI()
  local app = self.app
  self.aiOpen = not self.aiOpen
  if self.aiOpen and not self.ai then
    self.ai = AIPanel.new(app, self.id)
  end
  local target = self.aiOpen and self:aiWidth() or 0
  self.aiTargetW = target
  self.aiTween = app.fx.tween(
    self.aiW,
    { w = target },
    0.32,
    self.aiOpen and "expoOut" or "expoIn",
    function()
      self.aiTween = nil
      self:layout()
    end
  )
  app.audio.play(self.aiOpen and "open" or "close")
end

function Term:toLobby()
  self.app.audio.play("select")
  self.app.switch("lobby", { select = self.id })
end

function Term:update(dt)
  self.t = self.t + dt
  if self.toast then
    self.toast.t = self.toast.t + dt
    if self.toast.t > 3 and not self.toast.fading then
      self.toast.fading = true
      local toast = self.toast
      self.app.fx.tween(toast, { a = 0 }, 0.6, "expoIn", function()
        if self.toast == toast then
          self.toast = nil
        end
      end)
    end
  end
  local app = self.app
  local rec = app.sessions.get(self.id)
  if not rec then
    if not app.fx.transitioning then
      app.switch("lobby")
    end
    return
  end
  self:updateFolderProbe()
  self.assistAge = (self.assistAge or 0) + dt
  if self.assistAge >= 0.12 then
    self.assistAge = 0
    self:refreshCompletion()
  end
  local tv = self:view()
  tv:update(dt)
  if self.prev and self.prev.view then
    self.prev.view:update(dt)
  end
  local bells = tv:pollBell()
  if bells > 0 then
    self.bells = self.bells + bells
    app.fx.shake(3, 0.12)
    app.fx.flash(0.35, 1, 1, 1, 0.12)
    app.audio.play("bell")
  end
  if self.ai then
    self.ai:update(dt)
  end
  for _, r in ipairs(app.sessions.list) do
    if r.id ~= self.id then
      app.view(r.id):update(dt)
    end
  end
end

function Term:refreshCompletion()
  local core = self.app.core
  local rec = self.app.sessions.get(self.id)
  self.suggestion = nil
  if self.aiOpen or not rec or not core.canComplete(self.id) then
    return
  end
  local prefix = core.typing(self.id)
  local candidates = prefix == "" and core.predictNext(rec.hostId or 0, 8)
    or core.complete(rec.hostId or 0, prefix, 8)
  for _, row in ipairs(candidates) do
    if
      row.cmd:sub(1, #prefix) == prefix
      and #row.cmd > #prefix
      and not row.cmd:find("[%z\1-\31\127]")
    then
      self.suggestion, self.completionPrefix = row.cmd, prefix
      return
    end
  end
end
function Term:acceptCompletion()
  self:refreshCompletion()
  if not self.suggestion then
    self.app.toast("No learned completion for this line yet")
    return false
  end
  local suffix = self.suggestion:sub(#self.completionPrefix + 1)
  -- Only append the missing suffix. Enter is always a separate user action.
  self:write(suffix)
  self.suggestion = nil
  return true
end

function Term:write(bytes)
  self.folderProbe, self.folderClick = nil, nil
  self.app.core.write(self.id, bytes)
  if self.app.core.scrollOffset(self.id) ~= 0 then
    self.app.core.scroll(self.id, 0)
  end
end

-- Right arrow with no modifier accepts the ghost text: the cursor is already
-- at the end of the typed line, so the shell would ignore the key anyway.
function Term:acceptsWithRight(key, m)
  return key == "right"
    and not (m.ctrl or m.shift or m.alt or m.gui)
    and not self.aiOpen
    and self.suggestion ~= nil
end

function Term:keypressed(key, m)
  self.folderProbe, self.folderClick = nil, nil
  if key == "escape" and (self.downloadPicking or self.hotNotePicking) then
    self.downloadPicking, self.hotNotePicking = false, false
    self:resetFileCursor()
    self.lastEsc = -1
    return
  end
  if m.ctrl and m.shift and key == "u" then
    return self:upload()
  end
  if m.ctrl and m.shift and key == "d" then
    return self:toggleDownloadPick()
  end
  if key == "f" and m.ctrl and m.shift then
    return self.app.push("files", { id = self.id })
  end
  if key == "space" and m.ctrl and not m.shift and not self.aiOpen then
    self:refreshCompletion()
    if self.suggestion then
      return self:acceptCompletion()
    end
    return self:toggleAI()
  end
  if self:acceptsWithRight(key, m) then
    self:refreshCompletion()
    if self.suggestion then
      return self:acceptCompletion()
    end
  end
  local app = self.app
  local chord = Keys.appChord(key, m)
  -- Chat owns clipboard input. Never route a chat paste/copy to the SSH shell.
  if self.aiOpen and self.ai and chord == "paste" then
    self.ai.input:keypressed("v", m)
    return
  elseif self.aiOpen and self.ai and chord == "copy" then
    if self.ai.input.selectAll then
      love.system.setClipboardText(self.ai.input.value)
    end
    return
  end
  if chord == "cycle" then
    return self:cycle(1)
  elseif chord == "cycleBack" then
    return self:cycle(-1)
  elseif chord == "ai" then
    return self:toggleAI()
  elseif chord == "lobby" then
    return self:toLobby()
  elseif chord == "new" then
    return app.push("connect", { fromTerminal = true })
  elseif chord == "history" then
    return app.push("history", { id = self.id })
  elseif chord == "search" then
    return app.push("search")
  elseif chord == "rename" then
    return app.push("rename", { id = self.id })
  elseif chord == "settings" then
    return app.push("settings")
  elseif chord == "help" then
    return app.push("help")
  elseif chord == "paste" then
    local clip = love.system.getClipboardText() or ""
    if clip ~= "" then
      if clip:find("[\r\n%z\1-\31\127]") and not app.core.bracketedPaste(self.id) then
        app.push("paste", { id = self.id, text = clip })
      else
        app.core.paste(self.id, clip)
      end
    end
    return
  elseif chord == "copy" then
    local tv = self:view()
    local text = tv:selectedText()
    if text and text ~= "" then
      love.system.setClipboardText(text)
      tv.sel = nil
      app.fx.flash(0.15, 0.4, 0.86, 0.94, 0.25)
    else
      self:write("\x03")
    end
    return
  elseif chord == "quit" then
    love.event.quit()
    return
  elseif chord == "zoomIn" then
    return self:setZoom(self.app.D.termZoom + 1)
  elseif chord == "zoomOut" then
    return self:setZoom(self.app.D.termZoom - 1)
  end

  -- AI panel owns the keyboard while open
  if self.aiOpen and self.ai then
    if key == "escape" then
      -- single Esc closes the panel (cancels a running request first)
      if not self.ai:cancel() then
        self:toggleAI()
      end
      return
    end
    self.ai:keypressed(key, m)
    return -- unused chat keys must not leak to the remote terminal
  end

  -- Shift+PgUp / Shift+PgDn page through the scrollback (plain PgUp goes
  -- to the shell as \x1b[5~ so less/vim keep working)
  if m.shift and (key == "pageup" or key == "pagedown") then
    self:scrollBy(key == "pageup" and (self.rows or 24) or -(self.rows or 24))
    return
  end
  if key == "escape" then
    local now = love.timer.getTime()
    if now - self.lastEsc < ESC_DOUBLE then
      self.lastEsc = -1
      return self:toLobby()
    end
    self.lastEsc = now
    self:write("\x1b")
    return
  end
  local bytes = Keys.translate(key, m)
  if bytes then
    self:write(bytes)
    app.audio.play("click")
  end
end

function Term:textinput(t)
  if self.aiOpen and self.ai then
    self.ai:textinput(t)
    return
  end
  self:write(t)
  self.app.audio.play("click")
end

function Term:scrollBy(lines)
  local core = self.app.core
  local off = core.scrollOffset(self.id) + lines
  off = math.max(0, math.min(off, core.scrollbackLen(self.id)))
  core.scroll(self.id, off)
end

function Term:wheelmoved(_, dy)
  local mx, my = self.app.D.toVirtual(love.mouse.getPosition())
  -- the context menu only for a wheel *over the tab strip*; a cursor parked
  -- above or beside the window must not steal the scrollback wheel
  if my >= 0 and my < (self.top or TAB_H) and mx >= 0 and mx <= self.app.D.vw then
    if not self.app.hasOverlay("menu") then
      self:openMenu(4, (self.top or TAB_H) + 2)
    end
    return
  end
  if self.aiOpen and self.ai and self.ai:hover() then
    self.ai:wheelmoved(dy)
    return
  end
  self:scrollBy(dy * 3)
end

function Term:mousepressed(mx, my, b)
  if b == 2 then
    self:openMenu(mx, my)
    return
  end
  if b ~= 1 then
    return
  end
  if
    (love.keyboard.isDown("lgui", "rgui", "lctrl", "rctrl"))
    and my >= (self.top or TAB_H)
    and my < self.app.D.vh - STATUS_H
  then
    local path = self:fileTarget(mx, my)
    if path then
      return self:download(path)
    end
  end
  if self.transferBox and UI.inside(mx, my, unpack(self.transferBox)) then
    self.app.push("transfer", { id = self.id, details = true })
    return
  end
  if self.completionBox and UI.inside(mx, my, unpack(self.completionBox)) then
    return self:acceptCompletion()
  end
  for _, bt in ipairs(self.buttons) do
    if UI.inside(mx, my, bt.x, bt.y, bt.w, bt.h) then
      self.app.audio.play("click")
      bt.fn()
      return
    end
  end
  if self.aiOpen and self.ai and self.ai:hover(mx, my) then
    self.ai:mousepressed(mx, my, b)
    return
  end
  if self.hotNotePicking then
    local path = self:fileTarget(mx, my)
    if path then
      self:hotNote(path)
    end
    return
  end
  if self.downloadPicking then
    local path = self:fileTarget(mx, my)
    if path then
      self:download(path)
    end
    return
  end
  local tv = self:view()
  local cx, cy = self:cellAt(mx, my)
  local token = require("src.terminal_files").at(tv, cx, cy)
  self.folderClick = token
      and {
        name = token.literal or token.name,
        gen = tv.gen or self.app.core.generation(self.id),
        cwd = self.app.core.cwd(self.id),
        mx = mx,
        my = my,
      }
    or nil
  tv.sel = { x0 = cx, y0 = cy, x1 = cx, y1 = cy }
  self.dragging = true
end

-- Virtual px (content space) -> grid cell.
function Term:cellAt(mx, my)
  local D = self.app.D
  return self:view():cellAt(mx * D.s - self.px, my * D.s - self.py, self.zoom or 1)
end

function Term:updateHover(mx, my)
  for _, bt in ipairs(self.buttons) do
    if bt.id then
      local over = UI.inside(mx, my, bt.x, bt.y, bt.w, bt.h)
      local h = self.hover[bt.id]
      if not h then
        h = { lift = 0, over = false }
        self.hover[bt.id] = h
      end
      if over ~= h.over then
        h.over = over
        self.app.fx.tween(h, { lift = over and 2 or 0 }, 0.18, "expoOut")
      end
    end
  end
end

function Term:mousemoved(mx, my)
  if
    self.folderClick
    and (math.abs(mx - self.folderClick.mx) > 2 or math.abs(my - self.folderClick.my) > 2)
  then
    self.folderClick = nil
  end
  self:updateHover(mx, my)
  if self.dragging then
    local tv = self:view()
    local cx, cy = self:cellAt(mx, my)
    tv.sel.x1, tv.sel.y1 = cx, cy
  end
end

function Term:mousereleased(mx, my)
  if self.dragging then
    self.dragging = false
    local tv = self:view()
    local s = tv.sel
    if s and s.x0 == s.x1 and s.y0 == s.y1 then
      tv.sel = nil
      local click = self.folderClick
      if click and (not mx or (math.abs(mx - click.mx) <= 2 and math.abs(my - click.my) <= 2)) then
        self:probeFolder(click)
      end
    end
    self.folderClick = nil
  end
end

local function stateStyle(ST, st)
  if st == ST.CONNECTED then
    return "lgreen", "ONLINE"
  elseif st == ST.CONNECTING then
    return "amber", "CONNECTING"
  elseif st == ST.ERROR then
    return "alarm", "ERROR"
  elseif st == ST.CLOSED then
    return "gray", "CLOSED"
  end
  return "dgray", "IDLE"
end

-- The learned completion, dimmed, from the cursor cell to the right edge.
-- Drawn in grid space (screen px, 8x16 cells at the terminal zoom).
function Term:drawFileLink(tv, zoom)
  self.fileHint, self.hoverFilename = nil, nil
  if #self.app.overlays > 0 then
    self:resetFileCursor()
    return
  end
  local mx, my = self.app.D.toVirtual(love.mouse.getPosition())
  if mx < self.ox or mx >= self.ox + self.gw or my < self.oy or my >= self.oy + self.gh then
    self:resetFileCursor()
    return
  end
  local cx, cy = self:cellAt(mx, my)
  local token = require("src.terminal_files").at(tv, cx, cy)
  local folderLink = token and token.directory and self:canNavigate()
  if self.downloadPicking or self.hotNotePicking or folderLink then
    local kind = token and "hand" or "crosshair"
    self.fileCursors = self.fileCursors or {}
    self.fileCursors[kind] = self.fileCursors[kind] or love.mouse.getSystemCursor(kind)
    if self.fileCursorActive ~= kind then
      love.mouse.setCursor(self.fileCursors[kind])
      self.fileCursorActive = kind
    end
  else
    self:resetFileCursor()
  end
  self.hoverFilename = token and token.name or nil
  if not token then
    return
  end
  self.fileHint = (
    self.downloadPicking and "Click to download "
    or (self.hotNotePicking and "Click to edit ")
    or (folderLink and "Click to cd: " or "Click folder: cd / Cmd+click file: download ")
  ) .. token.name
  if
    self.downloadPicking
    or self.hotNotePicking
    or folderLink
    or love.keyboard.isDown("lgui", "rgui", "lctrl", "rctrl")
  then
    self.app.G.color("cyan")
    love.graphics.rectangle(
      "fill",
      token.first * 8 * zoom,
      (cy + 1) * 16 * zoom - 2,
      (token.last - token.first + 1) * 8 * zoom,
      1
    )
  end
end

function Term:drawGhost(tv, zoom)
  local suffix = self:ghostText()
  if not suffix or not tv.cvis or tv.cx >= (tv.cols or 0) or tv.cy >= (tv.rows or 0) then
    return
  end
  local G = self.app.G
  local room = tv.cols - tv.cx
  local shown, width = "", 0
  for ch in suffix:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local w = self.app.core.utf8Width and self.app.core.utf8Width(ch) or 1
    if width + w > room then
      break
    end
    shown, width = shown .. ch, width + w
  end
  if shown == "" then
    return
  end
  self.ghostShown = shown
  love.graphics.setFont(G.fontTerm)
  G.color("gray", 0.75)
  love.graphics.print(shown, tv.cx * 8 * zoom, tv.cy * 16 * zoom, 0, zoom, zoom)
end

-- The part of the suggestion the user has not typed yet (nil when none).
function Term:ghostText()
  if self.aiOpen or not self.suggestion then
    return nil
  end
  local suffix = self.suggestion:sub(#(self.completionPrefix or "") + 1)
  if suffix == "" then
    return nil
  end
  return suffix
end

function Term:drawFolderBar(y)
  local app, utf8 = self.app, require("utf8")
  local G, vw = app.G, app.D.vw
  local path = app.core.cwd(self.id)
  self.displayedFolder = path
  local rec = app.sessions.get(self.id)
  path = app.cfg.hidePath(path, rec and rec.user, rec and rec.host)
  G.panel(0, y, vw, CWD_H, "ink", "dblue")
  G.ui("FOLDER", 8, y + 4, "gray")
  local px = 16 + G.uiWidth("FOLDER")
  if path == "" then
    G.ui("Waiting for shell...", px, y + 4, "dgray")
    return
  end
  local copyW = G.uiWidth("COPY") + 12
  local upW = G.uiWidth("cd ..") + 12
  local upX = vw - copyW - upW - 8
  local room = upX - 8 - px
  local shown = path:gsub("[%z\1-\31\127]", "?")
  local shortened = false
  while #shown > 0 and G.uiWidth((shortened and "…" or "") .. shown) > room do
    shown = shown:sub(utf8.offset(shown, 2) or (#shown + 1))
    shortened = true
  end
  G.ui((shortened and "…" or "") .. shown, px, y + 4, "cyan")
  G.panel(upX, y + 1, upW, CWD_H - 2, "ink", "cyan")
  G.ui("cd ..", upX + 6, y + 4, "yellow")
  self.buttons[#self.buttons + 1] = {
    id = "parentFolder",
    x = upX,
    y = y,
    w = upW,
    h = CWD_H,
    fn = function()
      self:parentFolder()
    end,
  }
  G.panel(vw - copyW - 4, y + 1, copyW, CWD_H - 2, "ink", "cyan")
  G.ui("COPY", vw - copyW + 2, y + 4, "yellow")
  self.buttons[#self.buttons + 1] = {
    id = "folder",
    x = px,
    y = y,
    w = upX - px - 4,
    h = CWD_H,
    fn = function()
      love.system.setClipboardText(path)
      app.toast("Folder path copied")
    end,
  }
  local copy = self.buttons[#self.buttons].fn
  self.buttons[#self.buttons + 1] =
    { id = "copyFolder", x = vw - copyW - 4, y = y, w = copyW, h = CWD_H, fn = copy }
end

function Term:drawTabStrip(rec)
  local app = self.app
  local G, D = app.G, app.D
  local vw = D.vw
  local ST = app.core.ST
  self.buttons = {}
  local rows = Term.titleRows(D, rec, G)
  local top = TAB_H * rows
  love.graphics.setColor(0.10, 0.12, 0.31, 1)
  love.graphics.rectangle("fill", 0, 0, vw, top)
  G.color("rust")
  love.graphics.rectangle("fill", 0, top - 1, vw, 1)
  local Lobby = require("src.scenes.lobby")
  -- Return to the selected lobby layout (lift 2px on hover).
  local positions, toolbarRows, endX = Term.toolbar(D, G)
  local x = 4
  local rowY = (toolbarRows - 1) * TAB_H
  local function button(id, label, icon, fn)
    local pos = positions[id == "ai" and "AI CLOSE" or label]
    if not pos then
      return -- hidden at this width (see TAB_BUTTONS)
    end
    x = pos.x
    local w = pos.w
    local lift = (self.hover[id] and self.hover[id].lift) or 0
    local by = pos.y + 1 - math.floor(lift + 0.5)
    G.frame(x, by, w, TAB_H - 2, 1)
    if (id == "download" and self.downloadPicking) or (id == "hotnote" and self.hotNotePicking) then
      G.panel(x, by, w, TAB_H - 2, "dblue", "cyan")
    end
    if icon then
      G.drawIcon(icon, x + 5, by + 1, 12)
    end
    G.ui(label, x + (icon and 20 or 6), by + 4, "yellow")
    self.buttons[#self.buttons + 1] = { id = id, x = x, y = pos.y, w = w, h = TAB_H, fn = fn }
    x = x + w + 4
  end
  button("lobby", "< LOBBY", "icon_session", function()
    self:toLobby()
  end)
  button("disconnect", "DISCONNECT", nil, function()
    app.disconnectSession(app.sessions.get(self.id))
  end)
  button("ai", self.aiOpen and "AI CLOSE" or "AI CHAT", nil, function()
    self:toggleAI()
  end)
  button("upload", "UPLOAD", nil, function()
    self:upload()
  end)
  button("download", "DOWNLOAD", nil, function()
    self:toggleDownloadPick()
  end)
  button("rename", "RENAME", nil, function()
    app.push("rename", { id = self.id })
  end)
  button("autonote", "AUTO NOTE", nil, function()
    self:autoNote()
  end)
  button("hotnote", "HOT NOTE", nil, function()
    self:toggleHotNotePick()
  end)
  button("newnote", "NEW NOTE", nil, function()
    self:newNote()
  end)
  x = endX + 4
  G.drawFrame(G.ledStrip(8), Lobby.ledFrame(G, ST, rec.state, self.t), x, rowY + 4, 1, 1)
  x = x + 12
  -- right: icons (ai, search) + hint; the middle wraps/truncates to fit
  local ix = vw - 8 - 20 * 2
  local limit = ix - 8
  local function fit(txt, col, gap)
    local room = limit - x
    if room < G.uiWidth("…") + 8 then
      return false
    end
    local t = UI.fit(txt, room)
    G.ui(t, x, rowY + 4, col)
    x = x + G.uiWidth(t) + (gap or 10)
    return t == txt
  end
  local hostTxt = app.cfg.who(rec.user, rec.host)
  local idx = string.format("[%d/%d]", app.sessions.index(self.id) or 0, app.sessions.count())
  if rows > toolbarRows then
    -- title row: the whole name, then host and index as room allows
    local saveX, saveLimit = x, limit
    x, limit = 8, vw - 8
    love.graphics.setColor(0.08, 0.10, 0.26, 1)
    love.graphics.rectangle("fill", 0, toolbarRows * TAB_H, vw, TAB_H - 1)
    local function fitRow(txt, col, gap)
      local room = limit - x
      local t = UI.fit(txt, room)
      G.ui(t, x, toolbarRows * TAB_H + 4, col)
      x = x + G.uiWidth(t) + (gap or 10)
      return t == txt
    end
    if fitRow(rec.name, "yellow") and fitRow(hostTxt, "cyan") then
      fitRow(idx, "gray")
    end
    x, limit = saveX, saveLimit
  else
    fit(rec.name, "yellow")
    if fit(hostTxt, "cyan") then
      fit(idx, "gray")
    end
  end
  local ix0 = ix
  for _, ic in ipairs(self.icons) do
    G.drawIcon(ic[1], ix, 0, 16)
    self.buttons[#self.buttons + 1] = { x = ix, y = 0, w = 16, h = 16, fn = ic[2] }
    ix = ix + 20
  end
  local panelOpen = self.aiOpen or #app.overlays > 0
  local hint = panelOpen and "Esc close"
    or (self.suggestion and "Right accept" or "^Space complete")
  local hx = ix0 - G.uiWidth(hint) - 12
  if toolbarRows == 1 and hx > x + 4 then
    G.ui(hint, hx, 4, panelOpen and "yellow" or "dgray")
  end
  self:drawFolderBar(top)
end

function Term:drawStatus(rec)
  local app = self.app
  local G, D = app.G, app.D
  local vw, vh = D.vw, D.vh
  local y = vh - STATUS_H
  local ST = app.core.ST
  love.graphics.setColor(0.10, 0.12, 0.31, 1)
  love.graphics.rectangle("fill", 0, y, vw, STATUS_H)
  G.color("rust")
  love.graphics.rectangle("fill", 0, y, vw, 1)
  local ledCol, stTxt = stateStyle(ST, rec.state)
  local Lobby = require("src.scenes.lobby")
  G.drawFrame(G.ledStrip(8), Lobby.ledFrame(G, ST, rec.state, self.t), 6, y + 5, 1, 1)
  local x = 18
  -- keepalive countdown
  local ka = app.cfg.get().keepaliveSeconds or 15
  local info = rec.info
  local kaTxt = "keepalive off"
  if info and info.last_ping_ms > 0 and ka > 0 then
    local left = ka - (app.core.nowMs() - info.last_ping_ms) / 1000
    kaTxt = string.format("%2ds keepalive", math.max(0, math.floor(left + 0.5)))
  elseif ka > 0 then
    kaTxt = string.format("%2ds keepalive", ka)
  end
  local idleTxt
  if info and info.last_activity_ms > 0 then
    local idle = math.max(0, (app.core.nowMs() - info.last_activity_ms) / 1000)
    idleTxt = string.format("idle %ds", math.floor(idle))
  end
  local grid = string.format("UTF-8  %dx%d  %dx  ", self.cols or 0, self.rows or 0, self.zoom or 1)
  local desired = x
    + G.uiWidth(kaTxt)
    + 12
    + G.uiWidth(stTxt)
    + 12
    + (idleTxt and G.uiWidth(idleTxt) + 12 or 0)
  -- the zoom button sits left of the right-hand hint; the hint
  -- shrinks to "F1 help" and the idle counter yields before they are dropped
  local cfgNow = app.cfg.get()
  -- RETRO and PRIVACY live in the app-wide top bar; the zoom button stays here
  local toggles = {
    { id = "font", label = "FONT " .. (self.zoom or 1) .. "x", on = true, fn = self.cycleZoom },
  }
  local btnW = 12
  for _, b in ipairs(toggles) do
    b.w = G.uiWidth(b.label) + 8
    btnW = btnW + b.w + 4
  end
  local core = desired - (idleTxt and G.uiWidth(idleTxt) + 12 or 0)
  local right = grid .. BACK_HINT
  if vw - G.uiWidth(right) - 8 - btnW <= desired then
    right = BACK_HINT
  end
  if vw - G.uiWidth(right) - 8 - btnW <= core then
    right = "F1 help"
  end
  local rightX = vw - G.uiWidth(right) - 8
  local stateW = G.uiWidth(stTxt)
  -- the toggles outrank the keepalive text too: it shortens to "15s" before
  -- they go, so they only vanish on a window too narrow for both
  local coreMin = 18 + G.uiWidth("15s") + 12 + stateW + 12
  local leftEdge = rightX
  if rightX - btnW > coreMin then
    leftEdge = rightX - btnW
    local bx = leftEdge + 4
    for _, b in ipairs(toggles) do
      G.panel(bx, y + 1, b.w, STATUS_H - 2, b.on and "dblue" or "ink", b.on and "cyan" or "dgray")
      G.ui(b.label, bx + 4, y + 4, b.on and "yellow" or "gray")
      local fn = b.fn
      self.buttons[#self.buttons + 1] = {
        id = b.id,
        x = bx,
        y = y,
        w = b.w,
        h = STATUS_H,
        fn = function()
          fn(self)
        end,
      }
      bx = bx + b.w + 4
    end
  end
  local kaRoom = leftEdge - x - stateW - 36
  if G.uiWidth(kaTxt) > kaRoom then
    kaTxt = kaTxt:match("^%s*(%d+s)") or "ka" -- "15s" beats "15s keepali…"
  end
  local shown = UI.fit(kaTxt, kaRoom)
  G.ui(shown, x, y + 5, rec.pulse > 0 and "lgreen" or "gray")
  x = x + G.uiWidth(shown) + 12
  if idleTxt and x + G.uiWidth(idleTxt) + stateW + 36 < leftEdge then
    G.ui(idleTxt, x, y + 5, "gray")
    x = x + G.uiWidth(idleTxt) + 12
  end
  G.ui(stTxt, x, y + 5, ledCol)
  x = x + stateW + 12
  self.statusRight, self.statusRightX, self.statusLeftEnd = right, rightX, x
  if rec.state == ST.ERROR then
    UI.label(app.core.error(self.id), x, y + 5, leftEdge - x - 12, "alarm")
  end
  G.ui(right, rightX, y + 5, "gray")
  self.completionBox, self.transferBox = nil, nil
  if self.downloadPicking or self.hotNotePicking then
    local verb = self.hotNotePicking and "Edit" or "Download"
    local hint = (self.hotNotePicking and "HOT NOTE" or "DOWNLOAD")
      .. ": click filename  |  Esc cancel"
    if G.uiWidth(hint) > vw - 16 then
      hint = "Click filename / Esc cancel"
    end
    G.panel(4, y + 1, vw - 8, STATUS_H - 2, "ink", "cyan")
    if self.hoverFilename then
      local cancel = "Esc cancel"
      local label = verb .. " " .. self.hoverFilename
      local utf8 = require("utf8")
      local width = vw - G.uiWidth(cancel) - 32
      while #label > 0 and G.uiWidth(label .. "…") > width do
        label = label:sub(1, (utf8.offset(label, -1) or 1) - 1)
      end
      if label ~= verb .. " " .. self.hoverFilename then
        label = label .. "…"
      end
      G.ui(label, 8, y + 5, "yellow")
      G.ui(cancel, vw - G.uiWidth(cancel) - 8, y + 5, "cyan")
    else
      G.ui(hint, 8, y + 5, "yellow")
    end
    return
  end
  local transfer = rec.quickTransfer
    or (
      rec.lastTransfer
      and app.time - (rec.lastTransfer.finishedAt or 0) < 12
      and rec.lastTransfer
    )
  if transfer then
    local st = transfer.status or {}
    local progress = (st.total or 0) > 0
        and string.format(" %d%%", math.floor((st.done or 0) * 100 / st.total))
      or "..."
    local label = (transfer.op == "upload" and "UPLOAD " or "DOWNLOAD ")
      .. (transfer.name or "file")
      .. (rec.quickTransfer and progress or (transfer.error and " - retry" or " - done"))
    local width = math.max(0, leftEdge - 12)
    local utf8 = require("utf8")
    while G.uiWidth(label) > width - 8 and #label > 0 do
      label = label:sub(1, (utf8.offset(label, -1) or 1) - 1)
    end
    if width > 60 then
      G.panel(4, y + 1, width, STATUS_H - 2, "ink", transfer.error and "alarm" or "cyan")
      G.ui(label, 8, y + 5, transfer.error and "alarm" or "cyan")
      self.transferBox = { 4, y + 1, width, STATUS_H - 2 }
    end
  elseif self.suggestion or self.fileHint then
    local width = math.max(0, leftEdge - 12)
    local text = self.suggestion and ("-> " .. self.suggestion .. "   (Right / ^Space)")
      or self.fileHint
    local utf8 = require("utf8")
    while G.uiWidth(text) > width - 8 and #text > 0 do
      text = text:sub(1, (utf8.offset(text, -1) or 1) - 1)
    end
    if width > 60 then
      G.panel(4, y + 1, width, STATUS_H - 2, "ink", "cyan")
      G.ui(text, 8, y + 5, "cyan")
      self.completionBox = self.suggestion and { 4, y + 1, width, STATUS_H - 2 } or nil
    end
  end
end

-- Push a transform whose unit is one screen pixel, origin at the grid's
-- top-left (including the content offset and the bell shake).
function Term:pushGridSpace(dxVirtual)
  local app = self.app
  local D, fx = app.D, app.fx
  love.graphics.push()
  love.graphics.origin()
  love.graphics.translate(
    (D.ox + fx.shakeX) * D.s + self.px + math.floor((dxVirtual or 0) * D.s),
    (D.oy + fx.shakeY) * D.s + self.py
  )
end

function Term:draw()
  local app = self.app
  local G, D = app.G, app.D
  local cfg = app.cfg.get()
  local rec = app.sessions.get(self.id)
  if not rec then
    return
  end
  local vw, vh = D.vw, D.vh
  G.color("black")
  love.graphics.rectangle("fill", 0, 0, vw, vh)

  local zoom = self.zoom or D.termZoom
  local crtOpts, prevOpts = self.crtOpts, self.prevOpts
  crtOpts.crt = cfg.crt ~= false
  crtOpts.barrel = cfg.barrel and 0.04 or 0
  crtOpts.retro = cfg.retro ~= false
  crtOpts.phosphor = cfg.phosphor
  prevOpts.crt, prevOpts.barrel, prevOpts.retro = crtOpts.crt, crtOpts.barrel, crtOpts.retro
  prevOpts.phosphor = crtOpts.phosphor
  if self.prev and self.prev.view then
    self:pushGridSpace(self.prev.x)
    self.prev.view:draw(0, 0, zoom, prevOpts)
    love.graphics.pop()
  end
  local tv = self:view()
  local sx = math.floor(self.slide.x)
  self:pushGridSpace(sx)
  tv:draw(0, 0, zoom, crtOpts)
  self:drawGhost(tv, zoom)
  self:drawFileLink(tv, zoom)
  love.graphics.pop()

  -- scrollback badge (UI chrome, drawn at the UI scale)
  local off = app.core.scrollOffset(self.id)
  if off > 0 then
    local total = app.core.scrollbackLen(self.id)
    local label = string.format("^ %d/%d", off, total)
    local w = G.uiWidth(label) + 8
    local bx = math.floor(self.ox + self.gw) - w - 4
    G.panel(bx, self.oy + 4, w, 14, "ink", "cyan", 0.9)
    G.ui(label, bx + 4, self.oy + 7, "cyan")
  end

  -- connecting / error veil
  if rec.state ~= app.core.ST.CONNECTED then
    local ST = app.core.ST
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.rectangle("fill", self.ox, self.oy, self.gw, self.gh)
    local msg
    local col = "amber"
    if rec.state == ST.CONNECTING then
      local dots = string.rep(".", math.floor(self.t * 3) % 4)
      msg = "CONNECTING " .. app.cfg.who(rec.user, rec.host) .. dots
    elseif rec.state == ST.ERROR then
      msg = "ERROR: " .. app.core.error(self.id)
      col = "alarm"
    else
      msg = "SESSION CLOSED  (Ctrl+Esc: lobby)"
      col = "gray"
    end
    msg = UI.fit(msg, math.max(0, self.gw - 40))
    local w = G.uiWidth(msg) + 24
    local cx = math.floor(self.ox + (self.gw - w) / 2)
    local cy = math.floor(self.oy + self.gh / 2) - 12
    G.frame(cx, cy, w, 24, 1)
    G.ui(msg, cx + 12, cy + 8, col)
  end

  if self.ai and self.aiW.w > 0.5 then
    local size = math.floor(self.aiW.w)
    if Term.aiDock(D) == "bottom" then
      self.ai:draw(0, vh - STATUS_H - size, vw, size, self.t)
    else
      local top = self.top or TAB_H
      self.ai:draw(vw - size, top, size, vh - top - STATUS_H, self.t)
    end
  end

  self:drawTabStrip(rec)
  self:drawStatus(rec)
  if self.toast then
    local msg = "F2 or Esc Esc returns to the lobby"
    local w = G.uiWidth(msg) + 24
    local tx = math.floor((vw - w) / 2)
    local ty = (self.top or TAB_H) + 8
    G.frame(tx, ty, w, 24, self.toast.a)
    G.ui(msg, tx + 12, ty + 8, "yellow", self.toast.a)
  end
end

Term.STATUS_H = STATUS_H
Term.TAB_H = TAB_H
Term.CWD_H = CWD_H
return Term
