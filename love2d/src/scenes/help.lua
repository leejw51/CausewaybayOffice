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
  { "Esc", "raw ESC to the shell (vim-safe); closes a panel" },
  { "F2 / Ctrl+Esc / Esc Esc", "back to the lobby (Esc double-tap: 300 ms)" },
  { "M", "world map (lobby)" },
  { "Right-click / wheel on top bar", "context menu (lobby, map, rename...)" },
  { "Cmd+V / Ctrl+Shift+V", "paste into terminal" },
  { "Ctrl+Shift+U / Ctrl+Shift+D", "upload / click a terminal filename to download" },
  { "Cmd/Ctrl+click a filename", "download from the current remote folder" },
  { "Ctrl+Shift+F", "files: browse, upload, download (or drop a file)" },
  { "Ctrl+Shift+K", "local history / command assist" },
  { "M / G in lobby", "world map / map2 session grid" },
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
  return s
end

function Help:update(dt)
  self.t = self.t + dt
end

function Help:keypressed()
  self.app.pop(self)
end

function Help:mousepressed()
  self.app.pop(self)
end

function Help:draw()
  local app = self.app
  local G, D = app.G, app.D
  local W, H = 420, 32 + #ROWS * 11 + 30
  local a = self.alpha or 1
  local x, y = UI.frame("KEYS", W, H, D.vw, D.vh, a, "icon_ai")
  for i, r in ipairs(ROWS) do
    local ry = y + 28 + (i - 1) * 11
    G.ui(r[1], x + 14, ry, "yellow")
    G.ui(r[2], x + 176, ry, "white")
  end
  local ver = "core " .. app.core.version .. (app.core.mock and "  (mock)" or "")
  G.ui(ver, x + 14, y + H - 18, "dgray")
  UI.hints({ { "any key", "close" } }, x + W - 100, y + H - 20, 90)
end

return Help
