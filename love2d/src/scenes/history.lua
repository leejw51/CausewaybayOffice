-- Local recording search and command assistance. Results are never executed
-- by selection: command entries open the terminal-input review overlay.
local UI = require("src.ui")
local History = {}
History.__index = History
local modes = { "search", "complete", "next" }
function History.new(app, p)
  local rec = app.sessions.get(p.id)
  local h = setmetatable({
    app = app,
    id = p.id,
    hostId = rec and rec.hostId or 0,
    mode = 1,
    sel = 1,
    results = {},
    t = 0,
  }, History)
  h.field = UI.field(
    "",
    "",
    { placeholder = "search local history", historyKey = "search.history", restore = true }
  )
  h.field.focused = true
  h:refresh()
  return h
end
function History:refresh()
  local core, q = self.app.core, self.field.value
  if self.mode == 2 then
    self.results = core.complete(self.hostId, q, 20)
  elseif self.mode == 3 then
    self.results = core.predictNext(self.hostId, 20)
  elseif q == "" then
    self.results = core.recentCommands(self.hostId, 20)
  else
    self.results = core.historySearch(q, "", 30)
  end
  self.last, self.sel = q, 1
end
function History:update(dt)
  self.t = self.t + dt
  if self.last ~= self.field.value then
    self:refresh()
  end
end
function History:keypressed(key, m)
  if key == "escape" then
    self.app.pop(self)
  elseif key == "tab" then
    self.mode = self.mode % #modes + 1
    self:refresh()
  elseif key == "up" then
    self.sel = math.max(1, self.sel - 1)
  elseif key == "down" then
    self.sel = math.min(#self.results, self.sel + 1)
  elseif key == "return" or key == "kpenter" then
    local row = self.results[self.sel]
    if row then
      local cmd = row.cmd or (row.kind == "command" and row.title)
      if cmd then
        self.app.push("paste", { id = self.id, text = cmd })
      else
        love.system.setClipboardText(row.snippet or row.title or "")
        self.app.toast("Copied history excerpt")
      end
    end
  else
    self.field:keypressed(key, m)
  end
end
function History:textinput(t)
  self.field:textinput(t)
end
function History:draw()
  local app = self.app
  local D, G = app.D, app.G
  local w, h = math.min(440, D.vw - 8), math.min(290, D.vh - 8)
  local x, y =
    UI.frame("HISTORY / " .. modes[self.mode]:upper(), w, h, D.vw, D.vh, self.alpha, "icon_search")
  self.field:draw(x + 12, y + 28, w - 24, self.t, 0)
  local n = math.max(1, math.floor((h - 106) / 20))
  local first = math.max(1, self.sel - n + 1)
  for i = first, math.min(#self.results, first + n - 1) do
    local row = self.results[i]
    local yy = y + 54 + (i - first) * 20
    if i == self.sel then
      G.panel(x + 10, yy, w - 20, 19, "ink", "neon_pink")
    end
    local label = (row.cmd or row.title or row.snippet or ""):gsub("[\r\n\t]", " ")
    local _, lines = G.fontTerm:getWrap(label, w - 28)
    G.text(lines[1] or "", x + 14, yy + 1, i == self.sel and "yellow" or "white")
  end
  if #self.results == 0 then
    G.ui("No history. Recording is in Settings.", x + 12, y + 58, "dgray")
  end
  G.ui("Local search; Tab: search / complete / next", x + 12, y + h - 38, "cyan")
  UI.hints(
    { { "Enter", "review/copy" }, { "↑↓", "select" }, { "Esc", "close" } },
    x + 12,
    y + h - 18,
    w - 24
  )
end
return History
