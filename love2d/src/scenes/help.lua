-- Help overlay (F1): key list. Any key closes.

local UI = require("src.ui")

local Help = {}
Help.__index = Help

local ROWS = {
  { "F1", "this help" },
  { "Ctrl+N", "new connection" },
  { "Enter", "open selected session (lobby)" },
  { "Ctrl+Tab / Ctrl+Shift+Tab", "next / previous session" },
  { "Ctrl+K", "fuzzy search sessions" },
  { "Ctrl+R", "rename session" },
  { "Delete", "close session (lobby)" },
  { "Ctrl+,", "settings (keys, provider, CRT)" },
  { "Right / Ctrl+Space", "Accept the ghost completion (Right: terminal only)" },
  { "Ctrl+Shift+Space", "AI sidekick panel" },
  { "Shift+Tab in the AI panel", "chat <-> notes (saved locally, searchable, fed to the chat)" },
  { "AUTO NOTE (terminal bar)", "screen -> AI summary -> note (raw capture without a key)" },
  { "Esc", "raw ESC to the shell (vim-safe); closes a panel" },
  { "F2 / Ctrl+Esc / Esc Esc", "back to the lobby (Esc double-tap: 300 ms)" },
  { "MAP 1 / MAP 2", "choose and remember the lobby layout" },
  { "Right-click / wheel on top bar", "context menu (lobby, rename, files)" },
  { "Cmd+V / Ctrl+Shift+V", "paste into terminal" },
  { "Ctrl+Shift+U / Ctrl+Shift+D", "upload / click a terminal filename to download" },
  { "Cmd/Ctrl+click a filename", "download from the current remote folder" },
  { "Ctrl+Shift+F", "files: browse, upload, download (or drop a file)" },
  { "Ctrl+Shift+K", "local history / command assist" },
  { "Tab / Esc in Map 2", "next filter / clear search and filters" },
  { "Cmd+C", "copy selection (else ^C)" },
  { "Mouse drag / wheel", "select text / scrollback" },
  { "F11", "fullscreen / window (Settings > display)" },
  { "Ctrl+O", "orientation: auto / landscape / portrait" },
  { "Map: arrows, Enter, [ ]", "move along paths, walk + connect, page" },
  { "Ctrl+F3", "fps counter" },
}

function Help.new(app)
  local s = setmetatable({}, Help)
  s.app = app
  s.t = 0
  s.scroll = 0
  return s
end

function Help:update(dt)
  self.t = self.t + dt
end

function Help:keypressed(key)
  if key == "down" or key == "pagedown" then
    self:wheelmoved(0, key == "down" and -1 or -8)
  elseif key == "up" or key == "pageup" then
    self:wheelmoved(0, key == "up" and 1 or 8)
  else
    self.app.pop(self)
  end
end

function Help:wheelmoved(_, dy)
  self.scroll = math.max(0, math.min(self.maxScroll or 0, self.scroll - dy * 20))
end

function Help:mousepressed()
  self.app.pop(self)
end

function Help:draw()
  local app = self.app
  local G, D = app.G, app.D
  local W, H = math.min(620, D.vw - 16), math.min(500, D.vh - 16)
  local a = self.alpha or 1
  local x, y = UI.frame("KEYS", W, H, D.vw, D.vh, a, "icon_ai")
  local keyW = math.floor((W - 40) * 0.42)
  local bodyW = W - 40 - keyW
  local rows, total = {}, 0
  for _, r in ipairs(ROWS) do
    local _, keys = G.fontUI:getWrap(r[1], keyW)
    local _, body = G.fontUI:getWrap(r[2], bodyW)
    local height = math.max(#keys, #body) * 12 + 12
    rows[#rows + 1] = { keys = keys, body = body, top = total, height = height }
    total = total + height
  end
  local viewH = H - 62
  self.maxScroll = math.max(0, total - viewH)
  self.scroll = math.min(self.scroll, self.maxScroll)
  love.graphics.push("all")
  UI.clip(x + 12, y + 28, W - 24, viewH)
  for _, row in ipairs(rows) do
    local ry = y + 30 + row.top - self.scroll
    for i, line in ipairs(row.keys) do
      G.ui(line, x + 14, ry + (i - 1) * 12, "yellow")
    end
    for i, line in ipairs(row.body) do
      G.ui(line, x + 26 + keyW, ry + (i - 1) * 12, "white")
    end
    G.panel(x + 14, ry + row.height - 6, W - 28, 1, "dblue", "dblue")
  end
  love.graphics.pop()
  UI.hints({ { "↑↓ / wheel", "scroll" }, { "Esc", "close" } }, x + 12, y + H - 20, W - 24)
end

return Help
