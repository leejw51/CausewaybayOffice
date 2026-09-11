-- AI setup page (SETUP in the assistant, or Ctrl+G).
-- Four tabs, 1-4 or a click switch them:
--
--   TOOLS  the harness the assist page can call: built-ins plus the user's
--          command tools (src/tools.lua). ADD / EDIT / DEL / ON-OFF; every
--          change is saved to tools.jsonl and used by the very next request,
--          the same way the AI's own define_tool works. AUTO RUN enables
--          confined writes; shell/outside access still needs approval.
--   KEYS   API keys per provider (masked, Enter edits, Del removes) and the
--          model names; keys go to SQLite and apikeys.jsonl through the core.
--   PLAY   playground: pick a provider, send a prompt (or PING / TOOLS TEST)
--          and watch the stream, the elapsed time and any function call, so
--          "is the AI working" has an answer before it matters.
--   MCP    the MCP server: START / STOP, the URL (COPY), the `claude mcp
--          add` line, auto-start, the port and request counters.

local UI = require("src.ui")
local Config = require("src.config")
local Tools = require("src.tools")

local Agi = {}
Agi.__index = Agi

Agi.TABS = { "tools", "keys", "play", "mcp" }
Agi.LABELS = { tools = "TOOLS", keys = "KEYS", play = "PLAYGROUND", mcp = "MCP" }
Agi.PING = "Reply with exactly CBO_PONG and nothing else."
Agi.TOOLS_TEST = "What is on my terminal screen? Use the read_screen tool, then answer in one line."
Agi.PLAY_SYSTEM = "You are a connectivity test for a terminal app. Answer briefly."

local ROW_H = 14

function Agi.new(app, p)
  local s = setmetatable({}, Agi)
  s.app = app
  s.tab = Agi.LABELS[p.tab] and p.tab or "tools"
  s.sessionId = p.sessionId
  s.panel = p.panel
  s.sel = 1
  s.scroll = 0
  s.t = 0
  s.buttons = {}
  s.form = nil -- tool editor {fields, focus, original}
  s.edit = nil -- key / model / port editor {kind, provider, field}
  s.play = {
    provider = Config.get().defaultProvider or "openai",
    prompt = UI.field("", Agi.PING, { maxLen = 4000, historyKey = "agi.play" }),
    req = nil,
    text = "",
    status = "",
    log = {},
    tools = false,
    startedAt = 0,
  }
  s.play.prompt.focused = true
  -- Re-read the store on every open, so a tools.jsonl edited by hand shows
  -- up here (the registry is saved on every change, so this loses nothing).
  Tools.load(app.core)
  return s
end

function Agi:leave()
  if self.play.req then
    self.app.core.llmCancel(self.play.req)
    self.app.core.llmFree(self.play.req)
    self.play.req = nil
  end
end

function Agi:setTab(tab)
  if tab ~= self.tab then
    self.tab, self.sel, self.scroll = tab, 1, 0
    self.form, self.edit = nil, nil
    self.play.prompt.focused = tab == "play"
    self.app.audio.play("click")
  end
end

-- ---- tools tab ---------------------------------------------------------------

function Agi:toolRows()
  return Tools.all()
end

function Agi:selectedTool()
  return self:toolRows()[self.sel]
end

function Agi:openForm(tool)
  local function field(placeholder, value)
    local f = UI.field("", value or "", { placeholder = placeholder, maxLen = 400 })
    return f
  end
  self.form = {
    original = tool,
    fields = {
      { "name", field("name (letters, digits, _)", tool and tool.name) },
      { "description", field("what it does", tool and tool.description) },
      { "command", field("command template, {param} placeholders", tool and tool.command) },
      {
        "params",
        field(
          "param names, comma separated",
          tool and table.concat(Tools.paramsOf(tool.params), ", ")
        ),
      },
    },
    focus = 1,
  }
  self.form.fields[1][2].focused = true
  self.app.audio.play("open")
end

function Agi:formFocus(i)
  local f = self.form
  if not f then
    return
  end
  f.fields[f.focus][2].focused = false
  f.focus = ((i - 1) % #f.fields) + 1
  f.fields[f.focus][2].focused = true
end

function Agi:saveForm()
  local f = self.form
  if not f then
    return false
  end
  local spec = {}
  for _, row in ipairs(f.fields) do
    spec[row[1]] = row[2].value
  end
  if f.original then
    spec.enabled = f.original.enabled
  end
  local tool, err = Tools.add(spec, self.app.core)
  if not tool then
    self.app.toast(err or "could not save the tool")
    self.app.audio.play("error")
    return false
  end
  if f.original and f.original.name ~= spec.name then
    Tools.remove(f.original.name, self.app.core)
  end
  self.form = nil
  self:harnessChanged()
  return true
end

-- Registry changed: tell the user it is live (the panel does the same when
-- the model defines a tool).
function Agi:harnessChanged()
  if self.panel and self.panel.harnessChanged then
    self.panel:harnessChanged()
  else
    self.app.toast("Harness updated live: " .. #Tools.all() .. " tools ready")
  end
end

function Agi:deleteTool()
  local t = self:selectedTool()
  if not t or t.builtin then
    self.app.toast("Built-in tools can be switched off, not removed")
    return false
  end
  Tools.remove(t.name, self.app.core)
  self.sel = math.max(1, math.min(self.sel, #self:toolRows()))
  self:harnessChanged()
  return true
end

function Agi:toggleTool()
  local t = self:selectedTool()
  if not t then
    return
  end
  Tools.setEnabled(t.name, t.enabled == false, self.app.core)
  self.app.audio.play("click")
end

-- ---- keys tab -----------------------------------------------------------------

function Agi:keyRows()
  local rows = {}
  for _, provider in ipairs(Config.PROVIDERS) do
    rows[#rows + 1] = { provider = provider }
  end
  return rows
end

function Agi:beginEdit(kind, provider)
  local cfg = Config.get()
  local init = ""
  if kind == "model" then
    init = cfg.models[provider] or ""
  elseif kind == "port" then
    init = tostring(cfg.mcpPort or 8765)
  end
  self.edit = {
    kind = kind,
    provider = provider,
    field = UI.field("", init, {
      masked = kind == "key",
      numeric = kind == "port",
      maxLen = kind == "port" and 5 or 512,
      placeholder = kind == "key" and "paste the key, Enter saves, Esc cancels"
        or (kind == "model" and Config.DEFAULT_MODELS[provider] or "port, 0 = any"),
    }),
  }
  self.edit.field.focused = true
  self.app.audio.play("open")
end

function Agi:commitEdit()
  local e = self.edit
  if not e then
    return
  end
  local v = e.field.value
  if e.kind == "key" then
    Config.setApiKey(e.provider, v)
    self.app.toast(v == "" and (e.provider .. " key removed") or (e.provider .. " key saved"))
  elseif e.kind == "model" then
    Config.get().models[e.provider] = v
    Config.save()
  elseif e.kind == "port" then
    Config.get().mcpPort = math.max(0, math.min(65535, tonumber(v) or 8765))
    Config.save()
  end
  self.edit = nil
  self.app.audio.play("select")
end

function Agi:clearKey(provider)
  Config.setApiKey(provider, "")
  self.app.toast(provider .. " key removed")
  self.app.audio.play("close")
end

-- ---- playground -----------------------------------------------------------------

function Agi:playSend(prompt, withTools)
  local p = self.play
  if p.req then
    return false
  end
  prompt = (prompt or p.prompt.value):gsub("%s+$", "")
  if prompt == "" then
    return false
  end
  local core = self.app.core
  local key = Config.apiKey(p.provider)
  if key == "" and not core.mock then
    p.status = "FAIL: no API key for " .. p.provider .. " (KEYS tab)"
    self.app.audio.play("error")
    return false
  end
  local req, err = core.llmStart({
    provider = p.provider,
    apiKey = key,
    model = Config.model(p.provider),
    system = Agi.PLAY_SYSTEM,
    messages = { { role = "user", content = prompt } },
    tools = withTools and Tools.forLlm() or nil,
  })
  if not req then
    p.status = "FAIL: " .. tostring(err)
    self.app.audio.play("error")
    return false
  end
  p.req, p.text, p.tools = req, "", withTools and true or false
  p.startedAt = love.timer.getTime()
  p.status = "waiting"
  p.calls = nil
  self.app.audio.play("open")
  return true
end

function Agi:playUpdate()
  local p = self.play
  if not p.req then
    return
  end
  local core = self.app.core
  p.text = p.text .. core.llmTakeDelta(p.req)
  local st = core.llmState(p.req)
  local secs = love.timer.getTime() - p.startedAt
  if st == core.LLM.DONE or st == core.LLM.ERROR then
    p.text = p.text .. core.llmTakeDelta(p.req)
    local calls = st == core.LLM.DONE and core.llmTakeCalls(p.req) or {}
    local err = st == core.LLM.ERROR and core.llmError(p.req) or nil
    core.llmFree(p.req)
    p.req = nil
    local names = {}
    for _, c in ipairs(calls) do
      names[#names + 1] = c.name
    end
    p.calls = names
    local ok = not err and (p.text ~= "" or #calls > 0)
    if err then
      p.status = string.format("FAIL %.1fs: %s", secs, err)
    elseif p.tools then
      p.status = #calls > 0
          and string.format("OK %.1fs: tool call %s", secs, table.concat(names, ", "))
        or string.format("OK %.1fs, but no tool call was made", secs)
    else
      p.status = string.format("OK %.1fs", secs)
    end
    table.insert(
      p.log,
      1,
      string.format(
        "%s  %s  %s  %s",
        os.date("%H:%M:%S"),
        p.provider,
        ok and "ok" or "FAIL",
        string.format("%.1fs", secs)
      )
    )
    p.log[9] = nil
    self.app.audio.play(ok and "select" or "error")
  elseif st == core.LLM.STREAMING and p.text ~= "" then
    p.status = string.format("streaming  %.0fs", secs)
  else
    p.status = string.format("waiting  %.0fs", secs)
  end
end

function Agi:cycleProvider(dir)
  local p = self.play
  local list = Config.PROVIDERS
  for i, name in ipairs(list) do
    if name == p.provider then
      p.provider = list[((i - 1 + (dir or 1)) % #list) + 1]
      break
    end
  end
  self.app.audio.play("click")
end

-- ---- mcp -----------------------------------------------------------------------

function Agi:mcpInfo()
  return self.app.core.mcpInfo()
end

function Agi:toggleMcp()
  local info = self:mcpInfo()
  local ok, err = self.app.setMcp(not info.running)
  if not ok then
    self.app.toast("MCP: " .. tostring(err))
    self.app.audio.play("error")
    return
  end
  self.app.toast(info.running and "MCP server stopped" or "MCP server started")
  self.app.audio.play(info.running and "close" or "open")
end

function Agi.redactMcpUrl(url)
  return (tostring(url or ""):gsub("(/mcp/)[^/%s]+", "%1[hidden]"))
end

function Agi:claudeCommand(forDisplay)
  local info = self:mcpInfo()
  if not info.running or info.url == "" then
    return ""
  end
  local url = forDisplay and Config.private() and Agi.redactMcpUrl(info.url) or info.url
  return "claude mcp add --transport http office " .. url
end

-- ---- input ----------------------------------------------------------------------

function Agi:update(dt)
  self.t = self.t + dt
  self:playUpdate()
end

function Agi:keypressed(key, m)
  local app = self.app
  if self.edit then
    if key == "escape" then
      self.edit = nil
    elseif key == "return" or key == "kpenter" then
      self:commitEdit()
    else
      self.edit.field:keypressed(key, m)
    end
    return
  end
  if self.form then
    if key == "escape" then
      self.form = nil
    elseif key == "return" or key == "kpenter" then
      self:saveForm()
    elseif key == "tab" or key == "down" then
      self:formFocus(self.form.focus + (m.shift and -1 or 1))
    elseif key == "up" then
      self:formFocus(self.form.focus - 1)
    else
      self.form.fields[self.form.focus][2]:keypressed(key, m)
    end
    return
  end
  if key == "escape" then
    if self.tab == "play" and self.play.req then
      app.core.llmCancel(self.play.req)
      return
    end
    app.pop(self)
    return
  end
  local n = tonumber(key)
  if n and Agi.TABS[n] and not (self.tab == "play" and self.play.prompt.focused and not m.ctrl) then
    self:setTab(Agi.TABS[n])
    return
  end
  if self.tab == "tools" then
    local rows = self:toolRows()
    if key == "up" then
      self.sel = ((self.sel - 2) % #rows) + 1
    elseif key == "down" then
      self.sel = (self.sel % #rows) + 1
    elseif key == "space" then
      self:toggleTool()
    elseif key == "a" or key == "n" then
      self:openForm(nil)
    elseif key == "e" or key == "return" or key == "kpenter" then
      local t = self:selectedTool()
      if t and not t.builtin then
        self:openForm(t)
      elseif t then
        self:toggleTool()
      end
    elseif key == "d" or key == "delete" or key == "backspace" then
      self:deleteTool()
    elseif key == "r" then
      Config.get().aiAutoRun = not Config.get().aiAutoRun
      Config.save()
    elseif key == "t" then
      Config.get().aiTools = Config.get().aiTools == false
      Config.save()
    end
  elseif self.tab == "keys" then
    local rows = self:keyRows()
    local row = rows[self.sel]
    if key == "up" then
      self.sel = ((self.sel - 2) % #rows) + 1
    elseif key == "down" or key == "tab" then
      self.sel = (self.sel % #rows) + 1
    elseif key == "return" or key == "kpenter" then
      self:beginEdit("key", row.provider)
    elseif key == "delete" or key == "backspace" then
      self:clearKey(row.provider)
    elseif key == "m" then
      self:beginEdit("model", row.provider)
    elseif key == "space" then
      Config.get().defaultProvider = row.provider
      Config.save()
      if self.panel then
        self.panel.provider = row.provider
      end
      app.audio.play("click")
    end
  elseif self.tab == "play" then
    local p = self.play
    if key == "tab" then
      self:cycleProvider(m.shift and -1 or 1)
    elseif key == "return" or key == "kpenter" then
      self:playSend(nil, false)
    elseif key == "p" and m.ctrl then
      self:playSend(Agi.PING, false)
    elseif key == "t" and m.ctrl then
      self:playSend(Agi.TOOLS_TEST, true)
    elseif key == "pagedown" or key == "pageup" then
      self.scroll = math.max(0, self.scroll + (key == "pagedown" and 64 or -64))
    else
      p.prompt:keypressed(key, m)
    end
  elseif self.tab == "mcp" then
    if key == "space" or key == "return" or key == "kpenter" then
      self:toggleMcp()
    elseif key == "c" then
      self:copy(self:mcpInfo().url, "MCP URL copied")
    elseif key == "l" then
      self:copy(self:claudeCommand(), "claude mcp add command copied")
    elseif key == "a" then
      Config.get().mcpAuto = not Config.get().mcpAuto
      Config.save()
      app.audio.play("click")
    elseif key == "p" then
      self:beginEdit("port")
    end
  end
end

function Agi:copy(text, toast)
  if not text or text == "" then
    self.app.toast("Nothing to copy: start the server first")
    return false
  end
  love.system.setClipboardText(text)
  self.app.fx.flash(0.15, 0.4, 0.86, 0.94, 0.25)
  self.app.audio.play("select")
  self.app.toast(toast or "Copied")
  return true
end

function Agi:textinput(t)
  if self.edit then
    self.edit.field:textinput(t)
  elseif self.form then
    self.form.fields[self.form.focus][2]:textinput(t)
  elseif self.tab == "play" then
    self.play.prompt:textinput(t)
  end
end

function Agi:wheelmoved(_, dy)
  self.scroll = math.max(0, self.scroll - dy * 24)
end

function Agi:mousepressed(mx, my, b)
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
  if
    self.frame
    and not UI.inside(mx, my, unpack(self.frame))
    and not self.edit
    and not self.form
  then
    self.app.pop(self)
  end
end

-- ---- draw ------------------------------------------------------------------------

-- Small button; registers the click box. Returns its width.
function Agi:button(label, x, y, fn, col, lit)
  local G = self.app.G
  local bw = G.uiWidth(label) + 10
  G.panel(x, y, bw, 16, lit and "dblue" or "ink", lit and "cyan" or (col or "rust"), 0.95)
  G.ui(label, x + 5, y + 4, lit and "cyan" or (col or "yellow"))
  self.buttons[#self.buttons + 1] = { x = x, y = y, w = bw, h = 16, fn = fn }
  return bw
end

-- A row of buttons from the left; wraps. Returns the y below the rows.
function Agi:buttonRow(list, x, y, maxW)
  local bx, by = x, y
  for _, b in ipairs(list) do
    local bw = self.app.G.uiWidth(b[1]) + 10
    if bx + bw > x + maxW and bx > x then
      bx, by = x, by + 19
    end
    self:button(b[1], bx, by, b[2], b[3], b[4])
    bx = bx + bw + 4
  end
  return by + 19
end

function Agi:draw()
  local app = self.app
  local D, G = app.D, app.G
  local w, h = D.vw - 16, D.vh - 16
  local a = self.alpha or 1
  local x, y = UI.frame("AI SETUP  " .. Agi.LABELS[self.tab], w, h, D.vw, D.vh, a, "icon_ai")
  self.frame = { x, y, w, h }
  self.buttons = {}
  -- tabs
  local tx = x + 12
  for i, tab in ipairs(Agi.TABS) do
    local label = i .. " " .. Agi.LABELS[tab]
    tx = tx
      + self:button(label, tx, y + 28, function()
        self:setTab(tab)
      end, nil, tab == self.tab)
      + 4
  end
  local top = y + 50
  local bodyH = h - 50 - 24
  love.graphics.push("all")
  UI.clip(x + 6, top, w - 12, bodyH)
  if self.tab == "tools" then
    self:drawTools(x + 12, top, w - 24, bodyH)
  elseif self.tab == "keys" then
    self:drawKeys(x + 12, top, w - 24, bodyH)
  elseif self.tab == "play" then
    self:drawPlay(x + 12, top, w - 24, bodyH)
  else
    self:drawMcp(x + 12, top, w - 24, bodyH)
  end
  love.graphics.pop()
  local hints
  if self.edit or self.form then
    hints = { { "Enter", "save" }, { "Tab/↑↓", "field" }, { "Esc", "cancel" } }
  elseif self.tab == "tools" then
    hints = {
      { "A", "add" },
      { "E/Enter", "edit" },
      { "D", "delete" },
      { "Space", "on/off" },
      { "R", "auto run" },
      { "T", "tools on/off" },
      { "Esc", "close" },
    }
  elseif self.tab == "keys" then
    hints = {
      { "Enter", "set / change key" },
      { "Del", "remove key" },
      { "M", "model" },
      { "Space", "default" },
      { "Esc", "close" },
    }
  elseif self.tab == "play" then
    hints = {
      { "Enter", "send" },
      { "Tab", "provider" },
      { "^P", "ping" },
      { "^T", "tools test" },
      { "Esc", self.play.req and "cancel" or "close" },
    }
  else
    hints = {
      { "Space", "start/stop" },
      { "C", "copy URL" },
      { "L", "copy claude line" },
      { "A", "auto start" },
      { "P", "port" },
      { "Esc", "close" },
    }
  end
  UI.hints(hints, x + 12, y + h - 18, w - 24)
end

function Agi:drawTools(x, y, w, h)
  local G, cfg = self.app.G, Config.get()
  local by = self:buttonRow({
    {
      "ADD",
      function()
        self:openForm(nil)
      end,
      "green",
    },
    {
      "EDIT",
      function()
        local t = self:selectedTool()
        if t and not t.builtin then
          self:openForm(t)
        else
          self.app.toast("Select a user tool to edit")
        end
      end,
    },
    {
      "DEL",
      function()
        self:deleteTool()
      end,
      "lred",
    },
    {
      "ON/OFF",
      function()
        self:toggleTool()
      end,
    },
    {
      "AUTO RUN " .. (cfg.aiAutoRun and "on" or "off"),
      function()
        cfg.aiAutoRun = not cfg.aiAutoRun
        Config.save()
      end,
      nil,
      cfg.aiAutoRun == true,
    },
    {
      "TOOLS " .. (cfg.aiTools == false and "off" or "on"),
      function()
        cfg.aiTools = cfg.aiTools == false
        Config.save()
      end,
      nil,
      cfg.aiTools ~= false,
    },
  }, x, y, w)
  UI.label(
    string.format(
      "%d tools live (%d user). AUTO RUN: workspace writes only. Shell / outside access requires approval.",
      #Tools.all(),
      #Tools.user
    ),
    x,
    by + 2,
    w,
    "gray"
  )
  by = by + 14
  if self.form then
    self:drawForm(x, by, w)
    return
  end
  local rows = self:toolRows()
  local visible = math.max(1, math.floor((y + h - by - 4) / (ROW_H * 2)))
  self.sel = math.max(1, math.min(self.sel, #rows))
  self.scroll = math.max(0, math.min(self.scroll, (self.sel - 1) * ROW_H * 2))
  self.scroll = math.max(self.scroll, (self.sel - visible) * ROW_H * 2)
  local first = math.floor(self.scroll / (ROW_H * 2)) + 1
  for i = first, math.min(#rows, first + visible) do
    local t = rows[i]
    local ry = by + (i - first) * ROW_H * 2
    local selected = i == self.sel
    if selected then
      G.panel(x - 4, ry - 1, w + 8, ROW_H * 2 - 2, "ink", "neon_pink")
    end
    local on = t.enabled ~= false
    G.ui(on and "[on]" or "[  ]", x, ry + 2, on and "lgreen" or "dgray")
    local name = Tools.describe(t)
    G.ui(
      UI.fit(name, w - 120),
      x + 36,
      ry + 2,
      selected and "neon_pink" or (t.builtin and "cyan" or "yellow")
    )
    G.ui(t.builtin and "core" or "user", x + w - 40, ry + 2, "gray")
    local desc = t.description or ""
    if t.command then
      desc = desc .. "   $ " .. t.command
    end
    UI.label(desc, x + 36, ry + 14, w - 40, "gray")
    self.buttons[#self.buttons + 1] = {
      x = x - 4,
      y = ry - 1,
      w = w + 8,
      h = ROW_H * 2 - 2,
      fn = function()
        if self.sel == i then
          if t.builtin then
            self:toggleTool()
          else
            self:openForm(t)
          end
        end
        self.sel = i
      end,
    }
  end
end

function Agi:drawForm(x, y, w)
  local G = self.app.G
  local f = self.form
  G.panel(x - 4, y, w + 8, 4 * 26 + 30, "navy", "cyan")
  UI.label(
    f.original and ("EDIT TOOL " .. f.original.name) or "NEW TOOL",
    x + 4,
    y + 6,
    w - 8,
    "cyan"
  )
  for i, row in ipairs(f.fields) do
    local fy = y + 20 + (i - 1) * 26
    row[2].label = row[1]
    row[2]:draw(x + 4, fy, w - 8, self.t, 90)
    self.buttons[#self.buttons + 1] = {
      x = x + 4,
      y = fy,
      w = w - 8,
      h = 20,
      fn = function()
        self:formFocus(i)
      end,
    }
  end
  local by = y + 20 + 4 * 26 + 2
  self:buttonRow({
    {
      "SAVE",
      function()
        self:saveForm()
      end,
      "green",
    },
    {
      "CANCEL",
      function()
        self.form = nil
      end,
    },
  }, x + 4, by, w - 8)
end

function Agi:drawKeys(x, y, w, h)
  local G, cfg = self.app.G, Config.get()
  UI.label(
    "Add a key, choose a provider, then return to chat. PLAYGROUND tests the connection.",
    x,
    y + 2,
    w,
    "gray"
  )
  local by = y + 16
  local rows = self:keyRows()
  for i, row in ipairs(rows) do
    local ry = by + (i - 1) * 44
    local selected = i == self.sel
    local provider = row.provider
    local key, src = Config.apiKey(provider)
    if selected then
      G.panel(x - 4, ry - 2, w + 8, 42, "ink", "neon_pink")
    end
    G.drawIcon("icon_key", x, ry, 16)
    G.ui(provider:upper(), x + 20, ry + 4, selected and "neon_pink" or "white")
    if cfg.defaultProvider == provider then
      G.ui("default", x + 20 + G.uiWidth(provider:upper()) + 8, ry + 4, "cyan")
    end
    -- The buttons own the row's first line; the key and model lines sit
    -- below them so nothing is drawn underneath a button.
    local stored = (cfg.apiKeys[provider] or "") ~= ""
    local shown
    if key == "" then
      shown = "(not set)"
    elseif not stored and src then
      shown = Config.mask(key) .. "  from " .. src .. " (environment)"
    else
      shown = Config.mask(key)
    end
    UI.label("key: " .. shown, x + 20, ry + 20, w - 26, key == "" and "dgray" or "cyan")
    UI.label("model: " .. Config.model(provider), x + 20, ry + 31, w - 26, "gray")
    local bx = x + w - 4
    local btns = {
      {
        "DEFAULT",
        function()
          cfg.defaultProvider = provider
          Config.save()
          if self.panel then
            self.panel.provider = provider
          end
        end,
      },
      {
        "MODEL",
        function()
          self.sel = i
          self:beginEdit("model", provider)
        end,
      },
      -- Only a key stored here can be removed; an environment variable is
      -- the shell's, so the button is not offered for one.
      stored and {
        "REMOVE",
        function()
          self:clearKey(provider)
        end,
        "lred",
      } or nil,
      {
        stored and "CHANGE" or "SET KEY",
        function()
          self.sel = i
          self:beginEdit("key", provider)
        end,
        "green",
      },
    }
    local ordered = {}
    for _, b in pairs(btns) do
      ordered[#ordered + 1] = b
    end
    btns = ordered
    for _, b in ipairs(btns) do
      local bw = G.uiWidth(b[1]) + 10
      bx = bx - bw
      self:button(b[1], bx, ry + 2, b[2], b[3])
      bx = bx - 4
    end
    self.buttons[#self.buttons + 1] = {
      x = x - 4,
      y = ry - 2,
      w = w - (x + w - bx) - 4,
      h = 42,
      fn = function()
        self.sel = i
      end,
    }
  end
  if self.edit then
    local e = self.edit
    local ey = by + #rows * 44 + 6
    G.panel(x - 4, ey, w + 8, 44, "navy", "cyan")
    UI.label(
      (e.kind == "key" and "API key for " or (e.kind == "model" and "model for " or "MCP port "))
        .. (e.provider or ""),
      x + 4,
      ey + 4,
      w - 8,
      "cyan"
    )
    e.field:draw(x + 4, ey + 18, w - 8, self.t, 0)
  end
end

function Agi:drawPlay(x, y, w, h)
  local G = self.app.G
  local p = self.play
  local key = Config.apiKey(p.provider)
  local provBtns = {}
  for _, prov in ipairs(Config.PROVIDERS) do
    provBtns[#provBtns + 1] = {
      prov:upper(),
      function()
        p.provider = prov
      end,
      nil,
      prov == p.provider,
    }
  end
  local by = self:buttonRow(provBtns, x, y, w)
  UI.label(
    string.format(
      "%s  model %s  key %s",
      p.provider,
      Config.model(p.provider),
      key == "" and (self.app.core.mock and "(mock)" or "MISSING") or Config.mask(key)
    ),
    x,
    by + 2,
    w,
    key == "" and not self.app.core.mock and "lred" or "gray"
  )
  by = by + 14
  local sendW = G.uiWidth("SEND") + 12
  p.prompt:draw(x, by, w - sendW - 4, self.t, 0)
  self:button("SEND", x + w - sendW, by + 2, function()
    self:playSend(nil, false)
  end, "green")
  by = by + 24
  by = self:buttonRow({
    {
      "PING",
      function()
        self:playSend(Agi.PING, false)
      end,
    },
    {
      "TOOLS TEST",
      function()
        self:playSend(Agi.TOOLS_TEST, true)
      end,
    },
    {
      "CANCEL",
      function()
        if p.req then
          self.app.core.llmCancel(p.req)
        end
      end,
    },
    {
      "CLEAR",
      function()
        p.text, p.status, p.log, p.calls = "", "", {}, nil
      end,
    },
  }, x, by, w)
  local col = "gray"
  if p.status:find("^OK") then
    col = "lgreen"
  elseif p.status:find("^FAIL") then
    col = "lred"
  elseif p.req then
    col = "amber"
  end
  UI.label(
    p.status ~= "" and p.status or "Send a prompt, or PING. TOOLS TEST asks for a read_screen call.",
    x,
    by + 2,
    w,
    col
  )
  by = by + 14
  local logW = math.min(180, math.floor(w * 0.35))
  local textW = w - logW - 8
  local textH = y + h - by - 4
  G.panel(x, by, textW, textH, "black", "dblue")
  love.graphics.push("all")
  UI.clip(x + 2, by + 2, textW - 4, textH - 4)
  local shown = p.text
  if p.req and math.floor(self.t * 4) % 2 == 0 then
    shown = shown .. "▌"
  end
  if p.calls and #p.calls > 0 then
    shown = shown .. "\n[tool calls: " .. table.concat(p.calls, ", ") .. "]"
  end
  local _, lines = G.fontTerm:getWrap(shown, textW - 8)
  local total = #lines * 16
  local maxScroll = math.max(0, total - (textH - 8))
  self.scroll = math.min(self.scroll, maxScroll)
  UI.wrapped(shown, x + 4, by + 4 - self.scroll, textW - 8, "white")
  love.graphics.pop()
  G.panel(x + textW + 8, by, logW, textH, "ink", "dblue")
  G.ui("LOG", x + textW + 12, by + 4, "gray")
  for i, line in ipairs(p.log) do
    UI.label(
      line,
      x + textW + 12,
      by + 4 + i * 12,
      logW - 8,
      line:find("FAIL") and "lred" or "lgreen"
    )
  end
end

function Agi:drawMcp(x, y, w, h)
  local G, cfg = self.app.G, Config.get()
  local help =
    "Ask in Claude Code; it can read this terminal and send answers here. Chat SEND uses the selected API provider."
  local helpH = UI.wrapHeight(help, w)
  UI.wrapped(help, x, y, w, "cyan")
  y, h = y + helpH + 8, h - helpH - 8
  local info = self:mcpInfo()
  local running = info.running == true
  local by = self:buttonRow({
    {
      running and "STOP" or "START",
      function()
        self:toggleMcp()
      end,
      running and "lred" or "green",
    },
    {
      "COPY URL",
      function()
        self:copy(info.url, "MCP URL copied")
      end,
    },
    {
      "COPY CLAUDE LINE",
      function()
        self:copy(self:claudeCommand(), "claude mcp add command copied")
      end,
    },
    {
      "AUTO START " .. (cfg.mcpAuto and "on" or "off"),
      function()
        cfg.mcpAuto = not cfg.mcpAuto
        Config.save()
      end,
      nil,
      cfg.mcpAuto == true,
    },
    {
      "PORT " .. tostring(cfg.mcpPort or 8765),
      function()
        self:beginEdit("port")
      end,
    },
  }, x, y, w)
  G.ui(running and "RUNNING" or "STOPPED", x, by + 4, running and "lgreen" or "dgray")
  by = by + 18
  G.panel(x, by, w, 24, "black", running and "cyan" or "dblue")
  local url = running and info.url or "(start the server to get the URL)"
  if Config.private() then
    url = Agi.redactMcpUrl(url)
  end
  G.text(UI.fit(url, w - 8, true), x + 4, by + 4, running and "cyan" or "dgray")
  by = by + 30
  -- The whole command, wrapped: it is meant to be read and retyped, not
  -- only copied, so it must not end in an ellipsis.
  local cmd = self:claudeCommand(true)
  if cmd == "" then
    cmd = "claude mcp add --transport http office <url>"
  end
  UI.label("Claude Code:", x, by, w, "gray")
  local cmdH = UI.wrapHeight(cmd, w - 8) + 8
  G.panel(x, by + 12, w, cmdH, "black", "dblue")
  UI.wrapped(cmd, x + 4, by + 16, w - 8, "white")
  by = by + 18 + cmdH
  local stats = string.format(
    -- Most useful first: the row shares its width with the scroll hint, so
    -- what gets cut should be the least interesting field.
    "requests %d   inbox %d   session %s   client %s",
    tonumber(info.requests) or 0,
    tonumber(info.inbox) or 0,
    tostring(info.session or -1),
    (info.last_client and info.last_client ~= "") and info.last_client or "-"
  )
  -- The scroll affordance shares the counters' row (the key-hints row owns
  -- the frame's last line). `mcpScroll` is measured after the block is
  -- drawn, so the room is reserved from the previous frame's measurement.
  local scrollHint = (self.mcpScroll or 0) > 0 and "▼ scroll" or nil
  local hintW = scrollHint and (G.uiWidth(scrollHint) + 6) or 0
  UI.label(stats, x, by, w - hintW, "gray")
  if scrollHint then
    G.ui(scrollHint, x + w - hintW + 6, by, "dgray")
  end
  by = by + 16
  -- Trimmed to the frame: the tool list is what a reader acts on, so it
  -- comes first and the rest scrolls (wheel / PgUp-PgDn) below it.
  local text = table.concat({
    "office_screen        the terminal screen (this session by default)",
    "office_cwd           the shell folder",
    "office_sessions      the live ssh sessions",
    "office_send          show text in the assist page (code gets RUN / PRACTICE)",
    "office_practice      start a coding practice from the given lines",
    "office_type          propose terminal input; the user reviews it first",
    "office_notes_search  search your notes      office_note_add  save one",
    "",
    "Any MCP client on this machine (Claude Code, Codex, an IDE) can connect:",
    "loopback only, and the token in the path is generated once and kept in",
    "the local database. Claude Code already runs on your own plan, so let it",
    "read the screen and answer here instead of spending this office's credit.",
  }, "\n")
  local room = y + h - by
  love.graphics.push("all")
  UI.clip(x, by, w, room)
  local drawn = UI.wrapped(text, x, by - self.scroll, w, "white")
  love.graphics.pop()
  self.mcpScroll = math.max(0, drawn - room)
  self.scroll = math.min(self.scroll, self.mcpScroll)

  if self.edit then
    local ey = y + h - 50
    G.panel(x - 4, ey, w + 8, 44, "navy", "cyan")
    UI.label(
      "MCP port (0 = any free port; restart the server to apply)",
      x + 4,
      ey + 4,
      w - 8,
      "cyan"
    )
    self.edit.field:draw(x + 4, ey + 18, w - 8, self.t, 0)
  end
end

return Agi
