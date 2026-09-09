-- Settings overlay: provider / models / API keys (masked) / keepalive / CRT /
-- font scale. Up/Down select, Left/Right adjust, Enter edits text rows.

local UI = require("src.ui")
local Config = require("src.config")

local Settings = {}
Settings.__index = Settings

local W, H = 400, 304

function Settings.new(app)
  local s = setmetatable({}, Settings)
  s.app = app
  s.cfg = Config.get()
  s.sel = 1
  s.t = 0
  s.scroll = 0
  s.editing = nil -- {row, field}
  s.rows = {
    { id = "provider", label = "AI provider", kind = "cycle" },
    {
      id = "model_openai",
      label = "openai model",
      kind = "text",
      get = function()
        return s.cfg.models.openai
      end,
      set = function(v)
        s.cfg.models.openai = v
      end,
      placeholder = Config.DEFAULT_MODELS.openai,
    },
    {
      id = "model_anthropic",
      label = "anthropic model",
      kind = "text",
      get = function()
        return s.cfg.models.anthropic
      end,
      set = function(v)
        s.cfg.models.anthropic = v
      end,
      placeholder = Config.DEFAULT_MODELS.anthropic,
    },
    {
      id = "model_xai",
      label = "xai model",
      kind = "text",
      get = function()
        return s.cfg.models.xai
      end,
      set = function(v)
        s.cfg.models.xai = v
      end,
      placeholder = Config.DEFAULT_MODELS.xai,
    },
    { id = "key_openai", label = "openai key", kind = "key", provider = "openai" },
    { id = "key_anthropic", label = "anthropic key", kind = "key", provider = "anthropic" },
    { id = "key_xai", label = "xai key", kind = "key", provider = "xai" },
    { id = "keepalive", label = "keepalive (s)", kind = "number", min = 0, max = 300, step = 5 },
    { id = "display", label = "display", kind = "display" },
    { id = "orientation", label = "orientation", kind = "orientation" },
    { id = "bezel", label = "CRT bezel", kind = "bool" },
    { id = "crt", label = "CRT scanlines", kind = "bool" },
    { id = "barrel", label = "CRT barrel", kind = "bool" },
    { id = "fontScale", label = "UI scale", kind = "scale" },
    { id = "termZoom", label = "terminal zoom", kind = "zoom" },
    { id = "keyClicks", label = "key clicks", kind = "bool" },
    { id = "sound", label = "sound", kind = "bool" },
    { id = "record", label = "record terminal", kind = "privacy" },
    { id = "embed", label = "OpenAI indexing", kind = "privacy" },
  }
  return s
end

function Settings:leave()
  Config.save()
  local app = self.app
  app.audio.enabled = self.cfg.sound ~= false
  app.audio.clicks = self.cfg.keyClicks == true
  for _, rec in ipairs(app.sessions.list) do
    app.core.setKeepalive(rec.id, self.cfg.keepaliveSeconds or 15)
  end
end

function Settings:update(dt)
  self.t = self.t + dt
end

function Settings:valueText(row)
  local cfg = self.cfg
  if row.kind == "privacy" then
    local on = row.id == "record" and self.app.core.recordEnabled()
      or row.id == "embed" and self.app.core.kvGet("embed.enabled") == "1"
    return on and "ON" or "off"
  elseif row.kind == "cycle" then
    return cfg.defaultProvider
  elseif row.kind == "text" then
    local v = row.get()
    return v ~= "" and v or ("(" .. row.placeholder .. ")")
  elseif row.kind == "key" then
    local k, src = Config.apiKey(row.provider)
    if src and src ~= "settings" then
      return Config.mask(k) .. "  from " .. src
    end
    return Config.mask(cfg.apiKeys[row.provider])
  elseif row.kind == "number" then
    local v = cfg.keepaliveSeconds or 15
    return v == 0 and "off" or tostring(v)
  elseif row.kind == "bool" then
    return cfg[row.id] and "ON" or "off"
  elseif row.kind == "scale" then
    return string.format("x%.1f", cfg.fontScale or 1)
  elseif row.kind == "zoom" then
    return string.format("%dx  (Ctrl+= / Ctrl+-)", cfg.termZoom or 1)
  elseif row.kind == "display" then
    return (self.app.D.fullscreen and "fullscreen (desktop)" or "window") .. "  (F11)"
  elseif row.kind == "orientation" then
    local D = self.app.D
    local eff = D.portrait and "portrait" or "landscape"
    return (cfg.orientation or "auto")
      .. ((cfg.orientation or "auto") == "auto" and ("  = " .. eff) or "")
      .. "  (Ctrl+O)"
  end
  return ""
end

function Settings:adjust(row, dir)
  local cfg = self.cfg
  local app = self.app
  if row.kind == "privacy" then
    if app.core.mock then
      app.toast("Recording requires the real core")
      return
    end
    local on = self:valueText(row) == "ON"
    if not on then
      self.confirmPrivacy = row
      return
    end
    if row.id == "record" then
      app.core.setRecording(false)
    else
      app.core.kvSet("embed.enabled", "0")
    end
  elseif row.kind == "cycle" then
    local list = Config.PROVIDERS
    local i = 1
    for k, p in ipairs(list) do
      if p == cfg.defaultProvider then
        i = k
      end
    end
    cfg.defaultProvider = list[((i - 1 + dir) % #list) + 1]
  elseif row.kind == "number" then
    cfg.keepaliveSeconds =
      math.max(row.min, math.min(row.max, (cfg.keepaliveSeconds or 15) + dir * row.step))
  elseif row.kind == "bool" then
    cfg[row.id] = not cfg[row.id]
    if row.id == "bezel" then
      app.setBezel(cfg.bezel)
    end
  elseif row.kind == "scale" then
    local v = (cfg.fontScale or 1) + dir * 0.5
    cfg.fontScale = math.max(0.5, math.min(3, v))
    app.D.setUserScale(cfg.fontScale)
    app.resize(love.graphics.getDimensions())
  elseif row.kind == "zoom" then
    cfg.termZoom = app.D.setTermZoom((cfg.termZoom or 1) + dir)
    app.resize(love.graphics.getDimensions())
  elseif row.kind == "display" then
    app.toggleFullscreen()
  elseif row.kind == "orientation" then
    local list = app.D.ORIENTATIONS
    local i = 1
    for k, o in ipairs(list) do
      if o == (cfg.orientation or "auto") then
        i = k
      end
    end
    app.setOrientation(list[((i - 1 + dir) % #list) + 1])
  elseif row.kind == "text" or row.kind == "key" then
    self:beginEdit(row)
    return
  end
  app.audio.play("click")
end

function Settings:beginEdit(row)
  local init = row.kind == "text" and row.get() or ""
  self.editing = {
    row = row,
    field = UI.field(
      "",
      init,
      { masked = row.kind == "key", maxLen = 512, historyKey = "settings." .. row.id }
    ),
  }
  self.editing.field.focused = true
end

function Settings:commitEdit()
  local e = self.editing
  if not e then
    return
  end
  local v = e.field.value
  if e.row.kind == "text" then
    e.row.set(v)
  elseif e.row.kind == "key" then
    self.cfg.apiKeys[e.row.provider] = v
  end
  e.field:remember()
  self.editing = nil
  Config.save()
  self.app.audio.play("select")
end

function Settings:keypressed(key, m)
  local app = self.app
  if self.confirmPrivacy then
    if key == "escape" then
      self.confirmPrivacy = nil
    elseif key == "return" or key == "kpenter" then
      if self.confirmPrivacy.id == "record" then
        app.core.setRecording(true)
      else
        local key = Config.apiKey("openai")
        if key == "" then
          app.toast("Set an OpenAI key first")
          return
        end
        app.core.kvSet("apikey.openai", self.cfg.apiKeys.openai or "")
        app.core.kvSet("embed.enabled", "1")
      end
      self.confirmPrivacy = nil
    end
    return
  end
  if self.editing then
    if key == "escape" then
      self.editing = nil
    elseif key == "return" or key == "kpenter" then
      self:commitEdit()
    else
      self.editing.field:keypressed(key, m)
    end
    return
  end
  local row = self.rows[self.sel]
  if key == "escape" then
    app.pop(self)
  elseif key == "up" then
    self.sel = ((self.sel - 2) % #self.rows) + 1
    app.audio.play("click")
  elseif key == "down" or key == "tab" then
    self.sel = (self.sel % #self.rows) + 1
    app.audio.play("click")
  elseif key == "left" then
    self:adjust(row, -1)
  elseif key == "right" then
    self:adjust(row, 1)
  elseif key == "return" or key == "kpenter" or key == "space" then
    self:adjust(row, 1)
  elseif key == "delete" or key == "backspace" then
    if row.kind == "key" then
      self.cfg.apiKeys[row.provider] = ""
    elseif row.kind == "text" then
      row.set("")
    end
  end
end

function Settings:textinput(t)
  if self.editing then
    self.editing.field:textinput(t)
  end
end

function Settings:layout()
  local D = self.app.D
  local w, h = math.min(W, D.vw - 8), math.min(H, D.vh - 8)
  local visible = math.max(1, math.floor((h - 54) / 14))
  self.scroll = math.max(0, math.min(self.scroll, self.sel - 1))
  self.scroll = math.max(self.scroll, self.sel - visible)
  return w, h, math.floor((D.vw - w) / 2), math.floor((D.vh - h) / 2), visible
end

function Settings:mousepressed(mx, my, b)
  if b ~= 1 then
    return
  end
  local D = self.app.D
  if self.confirmPrivacy or self.editing then
    return
  end
  local W, H, x, y, visible = self:layout()
  for i = self.scroll + 1, math.min(#self.rows, self.scroll + visible) do
    if UI.inside(mx, my, x + 6, y + 28 + (i - self.scroll - 1) * 14, W - 12, 14) then
      if self.sel == i then
        self:adjust(self.rows[i], 1)
      end
      self.sel = i
      return
    end
  end
  if not UI.inside(mx, my, x, y, W, H) and not self.editing then
    self.app.pop(self)
  end
end

function Settings:draw()
  local app = self.app
  local G, D = app.G, app.D
  local a = self.alpha or 1
  local W, H, _, _, visible = self:layout()
  local x, y = UI.frame("SETTINGS", W, H, D.vw, D.vh, a, "icon_settings")
  for i = self.scroll + 1, math.min(#self.rows, self.scroll + visible) do
    local row = self.rows[i]
    local ry = y + 28 + (i - self.scroll - 1) * 14
    local selected = i == self.sel
    if selected then
      G.panel(x + 10, ry - 1, W - 20, 13, "ink", "neon_pink")
    end
    if row.kind == "key" then
      G.drawIcon("icon_key", x + 132, ry - 3, 16)
    end
    UI.label(
      row.label,
      x + 16,
      ry + 2,
      row.kind == "key" and 112 or 128,
      selected and "neon_pink" or "gray"
    )
    local vt = self:valueText(row)
    -- clip the value to the frame (portrait frames are narrower than a key + its source)
    vt = UI.fit(vt, W - 166 - 28)
    local col = "white"
    if row.kind == "bool" then
      col = self.cfg[row.id] and "lgreen" or "dgray"
    elseif row.kind == "key" then
      col = vt:find("not set") and "dgray" or "cyan"
    end
    G.ui(vt, x + 166, ry + 2, col)
    if
      selected
      and (
        row.kind == "cycle"
        or row.kind == "number"
        or row.kind == "scale"
        or row.kind == "zoom"
        or row.kind == "display"
        or row.kind == "orientation"
      )
    then
      G.ui("<", x + 152, ry + 2, "yellow")
      G.ui(">", x + W - 18, ry + 2, "yellow")
    end
  end
  if self.confirmPrivacy then
    G.panel(x + 8, y + 30, W - 16, H - 54, "navy", "amber")
    local text = self.confirmPrivacy.id == "record"
        and "Record terminal input/output, including remote passwords? History is unencrypted. Disable before secrets.\n\nEnter enables; Esc cancels."
      or "Send recorded history and saved host details to OpenAI for indexing? Includes sensitive text. API charges apply.\n\nEnter enables; Esc cancels."
    UI.wrapped(text, x + 16, y + 38, W - 32, "white")
  end
  if self.editing then
    local e = self.editing
    local ex, ey = x + 20, y + math.floor(H / 2) - 20
    G.panel(ex, ey, W - 40, 44, "navy", "cyan")
    UI.label("Edit " .. e.row.label, ex + 6, ey + 4, W - 52, "cyan")
    e.field:draw(ex + 6, ey + 16, W - 52, self.t, 0)
  end
  UI.hints({
    { "↑↓", "row" },
    { "←→", "change" },
    { "Enter", "edit" },
    { "Del", "clear" },
    { "Esc", "save+close" },
  }, x + 12, y + H - 18, W - 24)
end

return Settings
