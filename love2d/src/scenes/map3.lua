-- Live monitor wall: Rust generation snapshots, shared GPU terminal canvases.
local UI = require("src.ui")
local Keys = require("src.keys")
local Map3 = {}
Map3.__index = Map3
function Map3.new(app, params)
  local self = setmetatable({
    app = app,
    t = 0,
    sel = 1,
    capacity = 100,
    buttons = {},
    cards = {},
    camera = { x = 0, y = 0, z = 1 },
  }, Map3)
  local saved = app.cfg.get().map3View
  saved = type(saved) == "table" and saved or {}
  if saved.capacity == "fit" then
    self.capacity = nil
  end
  self.field = UI.field(
    "",
    type(saved.query) == "string" and saved.query or "",
    { placeholder = "search name, user, host or port" }
  )
  self.command = UI.field("", "pwd", { placeholder = "command for shown nodes" })
  self.selectedId = saved.selected
  self.lastQuery = self.field.value:lower()
  self:refresh()
  for i, rec in ipairs(self.entries) do
    if params and rec.id == params.select then
      self.sel = i
      self.selectedId = rec.id
    end
  end
  local function finite(v, fallback)
    return type(v) == "number" and v == v and math.abs(v) < 1000000 and v or fallback
  end
  self.camera = {
    x = finite(saved.x, 0),
    y = finite(saved.y, 0),
    z = math.max(1, math.min(12, finite(saved.zoom, 1))),
  }
  self.target = { x = self.camera.x, y = self.camera.y, z = self.camera.z }
  return self
end
function Map3:remember()
  if self.simulation then
    return
  end
  local c = self.target or self.camera
  local value = {
    capacity = self.capacity and tostring(self.capacity) or "fit",
    query = self.field.value,
    selected = self.selectedId or 0,
    x = c.x,
    y = c.y,
    zoom = c.z,
  }
  local old = self.app.cfg.get().map3View or {}
  local changed = false
  for k, v in pairs(value) do
    if old[k] ~= v then
      changed = true
    end
  end
  if old.selected ~= value.selected then
    changed = true
  end
  if changed then
    self.app.cfg.get().map3View = value
    self.saveAt = self.t + 0.5
  end
end
Map3.ART = {
  CAT = { " /\\_/\\", "( o.o )", " > ^ <" },
  BTC = { "   | |", "  _|_|_", " |  _  )", " |  _  \\", " |_____/", "   | |", " BITCOIN" },
}
function Map3:sendArt(kind)
  local art = Map3.ART[kind]
  if not art then
    return
  end
  local quoted = {}
  for _, line in ipairs(art) do
    quoted[#quoted + 1] = "'" .. line .. "'"
  end
  self.command.value = "printf '%s\\n' " .. table.concat(quoted, " ")
  self:sendCommand()
end
function Map3:sendWordArt()
  local command, err = require("src.ascii_banner").command(self.command.value)
  if not command then
    self.app.toast(err)
    return
  end
  self:sendCommand(command)
end
function Map3:recipients()
  local result = {}
  for _, rec in ipairs(self.entries) do
    if
      rec.simulated
      or (
        not rec.closing
        and self.app.sessions.get(rec.id) == rec
        and self.app.core.state(rec.id) == self.app.core.ST.CONNECTED
      )
    then
      result[#result + 1] = rec
    end
  end
  return result
end
function Map3:sendCommand(command)
  command = command or self.command.value
  if not command:find("%S") then
    return
  end
  if command:find("[%z\1-\31\127]") then
    self.app.toast("Enter a single-line command")
    return
  end
  self:refresh()
  local targets = self:recipients()
  for _, rec in ipairs(targets) do
    if rec.simulated then
      self.simulation:send(rec, command)
    else
      self.app.core.write(rec.id, command .. "\r")
    end
  end
  self.app.toast(
    string.format(
      "%s to %d shown nodes",
      self.simulation and "Simulated command" or "Command sent",
      #targets
    )
  )
end
function Map3:source()
  return self.simulation and self.simulation.list or self.app.sessions.list
end
function Map3:view(rec)
  return rec.simulated and self.simulation:view(rec) or self.app.view(rec.id)
end
function Map3:toggleSimulation()
  if self.simulation then
    self.simulation:release()
    self.simulation = nil
    self.field.value = self.realQuery or ""
    self.selectedId = self.realSelected
    self.lastQuery = self.field.value:lower()
  else
    self:remember()
    self.app.cfg.save()
    self.realView = self.app.cfg.get().map3View
    self.realQuery, self.realSelected = self.field.value, self.selectedId
    self.simulation = require("src.monitor_sim").new()
    self.field.value, self.selectedId = "", nil
  end
  self.field.focused = false
  self:refresh()
  if self.simulation then
    self:fit(100)
  else
    local saved = self.realView
    self.capacity = nil
    if saved.capacity ~= "fit" then
      self.capacity = 100
    end
    self:layout()
    self:move(saved.x, saved.y, saved.zoom)
  end
end
function Map3:refresh()
  local selected = self.selectedId
  self.entries = {}
  local query = self.field.value:lower()
  for _, rec in ipairs(self:source()) do
    local hay = (tostring(rec.name or "") .. " " .. tostring(rec.user or "") .. "@" .. tostring(
      rec.host or ""
    ) .. ":" .. tostring(rec.port or 22)):lower()
    local matches = true
    for term in query:gmatch("%S+") do
      if not hay:find(term, 1, true) then
        matches = false
        break
      end
    end
    if matches then
      self.entries[#self.entries + 1] = rec
    end
  end
  if query ~= self.lastQuery then
    self.sel, selected = 1, nil
    self.lastQuery = query
    self:move(0, 0, 1)
  end
  for i, rec in ipairs(self.entries) do
    if rec.id == selected then
      self.sel = i
    end
  end
  self.sel = math.max(1, math.min(self.sel, #self.entries))
  self.selectedId = self.entries[self.sel] and self.entries[self.sel].id
  self:layout()
end
function Map3:layout()
  local D = self.app.D
  self.top, self.bottom = 142, D.vh - 28
  local n = math.max(self.capacity or 1, #self.entries)
  self.cols =
    math.max(1, math.ceil(math.sqrt(n * D.vw / math.max(1, self.bottom - self.top) * 0.65)))
  self.rows = math.ceil(n / self.cols)
  self.w = (D.vw - 16) / self.cols
  self.h = (self.bottom - self.top - 8) / self.rows
  self.gap = math.min(8, self.w * 0.08, self.h * 0.08)
end
function Map3:resize()
  -- A window mode change can discard the contents of GPU canvases.
  for _, rec in ipairs(self.entries) do
    self:view(rec).dirty = true
  end
  self:layout()
  self:fit(self.capacity)
end
function Map3:move(x, y, z)
  self.target = { x = x, y = y, z = z }
  self.app.fx.cancel(self.motion)
  self.motion = self.app.fx.tween(self.camera, { x = x, y = y, z = z }, 0.22, "expoInOut")
  self:remember()
end
function Map3:fit(capacity)
  self.capacity = capacity
  self:layout()
  self:move(0, 0, 1)
end
function Map3:focus()
  local x = 8 + ((self.sel - 1) % self.cols + 0.5) * self.w
  local y = self.top + (math.floor((self.sel - 1) / self.cols) + 0.5) * self.h
  self:move(
    self.app.D.vw / 2 - x,
    (self.top + self.bottom) / 2 - y,
    math.min(12, math.max(1, math.min(self.cols, self.rows)))
  )
end
function Map3:leave()
  self:remember()
  self.app.cfg.save()
  self.app.fx.cancel(self.motion)
  if self.simulation then
    self.simulation:release()
    self.simulation = nil
  end
end
function Map3:update(dt)
  self.t = self.t + dt
  self:refresh()
  self:remember()
  if self.saveAt and self.t >= self.saveAt then
    self.app.cfg.save()
    self.saveAt = nil
  end
  if self.simulation then
    self.simulation:update(dt, self.entries)
  end
  -- A generation check is cheap; unchanged terminals keep their GPU canvas.
  for _, rec in ipairs(self.entries) do
    if not rec.simulated then
      self:view(rec):update(dt)
    end
  end
end
function Map3:selectionFocus()
  local c = self.cards[self.sel]
  return c and { x = (c.x + c.w / 2) / self.app.D.vw, y = (c.y + c.h / 2) / self.app.D.vh }
    or { x = 0.5, y = 0.5 }
end
function Map3:open()
  local rec = self.entries[self.sel]
  if rec and rec.simulated then
    self:focus()
    return
  end
  if rec and self.app.sessions.get(rec.id) == rec then
    self.app.audio.play("select")
    self.app.switch("terminal", { id = rec.id })
  end
end
function Map3:textinput(t)
  if self.command.focused then
    self.command:textinput(t)
    return
  end
  if self.field.focused then
    self.field:textinput(t)
    self:refresh()
  end
end
function Map3:keypressed(key, m)
  if self.command.focused then
    if key == "escape" or key == "tab" then
      self.command.focused = false
    elseif key == "return" or key == "kpenter" then
      self:sendCommand()
    else
      self.command:keypressed(key, m)
    end
    return
  end
  if key == "tab" then
    self.field.focused = not self.field.focused
    return
  end
  if self.field.focused then
    if key == "escape" then
      self.field.value, self.field.focused = "", false
      self:refresh()
    elseif key == "return" or key == "kpenter" then
      self.field.focused = false
    else
      self.field:keypressed(key, m)
      self:refresh()
    end
    return
  end
  local chord = Keys.appChord(key, m)
  if key == "return" or key == "kpenter" then
    self:open()
  elseif key == "escape" or key == "0" then
    self:fit()
  elseif key == "space" then
    self:focus()
  elseif key == "=" or key == "+" then
    self:zoomBy(1)
  elseif key == "-" then
    self:zoomBy(-1)
  elseif key == "left" or key == "right" or key == "up" or key == "down" then
    local delta = ({ left = -1, right = 1, up = -self.cols, down = self.cols })[key]
    self.sel = math.max(1, math.min(#self.entries, self.sel + delta))
    self.selectedId = self.entries[self.sel] and self.entries[self.sel].id
    if self.camera.z > 1.01 then
      self:focus()
    end
    self.app.audio.play("select")
  elseif chord == "new" then
    self.app.push("connect", { fromTerminal = true })
  elseif chord == "settings" then
    self.app.push("settings")
  elseif chord == "help" then
    self.app.push("help")
  elseif chord == "search" then
    self.app.push("search")
  elseif key == "delete" then
    local rec = self.entries[self.sel]
    if rec and not rec.simulated then
      self.app.disconnectSession(rec, self:selectionFocus())
    end
  end
end
function Map3:zoomBy(dy)
  local c = self.target or self.camera
  self:move(c.x, c.y, math.max(1, math.min(12, c.z * 1.25 ^ dy)))
end
function Map3:wheelmoved(dx, dy)
  local mac = love.system.getOS() == "OS X"
  local zoom = love.keyboard.isDown("lgui", "rgui", "lctrl", "rctrl")
  if mac and not zoom then
    local c = self.target or self.camera
    self:move(c.x + dx * 18 / c.z, c.y + dy * 18 / c.z, c.z)
  else
    self:zoomBy(dy)
  end
end
function Map3:mousepressed(x, y, b)
  if b == 1 then
    self.command.focused = UI.inside(x, y, 156, 112, self.app.D.vw - 250, 24)
    if self.command.focused then
      self.field.focused = false
      return
    end
    self.field.focused = UI.inside(x, y, 8, 80, self.app.D.vw - 16, 24)
    if self.field.focused then
      return
    end
    for _, btn in ipairs(self.buttons) do
      if UI.inside(x, y, btn.x, btn.y, btn.w, btn.h) then
        btn.fn()
        return
      end
    end
  end
  if y < self.top or y > self.bottom then
    return
  end
  if b == 1 or b == 2 or b == 3 then
    self.drag = { x = x, y = y, moved = false, button = b }
  end
end
function Map3:mousemoved(_, _, dx, dy)
  if not self.drag then
    return
  end
  if math.abs(dx) + math.abs(dy) > 0 then
    self.drag.moved = true
    local c = self.target or self.camera
    self:move(c.x + dx / c.z, c.y + dy / c.z, c.z)
  end
end
function Map3:mousereleased(x, y, b)
  local drag = self.drag
  self.drag = nil
  if not drag or drag.moved or b ~= 1 then
    return
  end
  for i, c in ipairs(self.cards) do
    if UI.inside(x, y, c.x, c.y, c.w, c.h) then
      if self.sel == i and self.lastClick and self.t - self.lastClick < 0.35 then
        self:open()
      end
      self.sel, self.selectedId, self.lastClick = i, self.entries[i].id, self.t
      self.app.audio.play("select")
      return
    end
  end
end
function Map3:draw()
  local app, lg = self.app, love.graphics
  local G, D = app.G, app.D
  self:layout()
  self.buttons, self.cards = {}, {}
  G.color("navy")
  lg.rectangle("fill", 0, 0, D.vw, D.vh)
  local cx, cy = D.vw / 2, (self.top + self.bottom) / 2
  local boot = app.fx.ease.expoInOut(math.min(1, self.t / 0.28))
  for i, rec in ipairs(self.entries) do
    local z = self.camera.z
    local x = cx + (8 + (i - 1) % self.cols * self.w - cx + self.camera.x) * z
    local y = cy + (self.top + math.floor((i - 1) / self.cols) * self.h - cy + self.camera.y) * z
    local w, h = (self.w - self.gap) * z, (self.h - self.gap) * z
    self.cards[i] = { x = x, y = y, w = w, h = h }
    if x + w > 0 and x < D.vw and y + h > self.top and y < self.bottom then
      local selected = i == self.sel
      -- Draw the whole computer in normalized coordinates so the casing,
      -- keyboard and recessed CRT remain proportional at every zoom level.
      local function box(rx, ry, rw, rh, r, g, b)
        lg.setColor(r, g, b, 1)
        lg.rectangle("fill", x + rx * w, y + ry * h, rw * w, rh * h)
      end
      box(0.025, 0.03, 0.975, 0.96, 0.025, 0.025, 0.04)
      if selected then
        box(0, 0, 1, 0.99, 0.35, 0.88, 0.91)
      end
      -- Monitor shell: lit top edge, aged plastic front, deep screen bevel.
      box(0.035, 0.01, 0.93, 0.76, 0.34, 0.33, 0.29)
      box(0.035, 0.01, 0.90, 0.735, 0.83, 0.81, 0.72)
      box(0.045, 0.018, 0.88, 0.016, 0.91, 0.87, 0.73)
      box(0.055, 0.045, 0.86, 0.63, 0.43, 0.42, 0.35)
      box(0.068, 0.058, 0.834, 0.61, 0.20, 0.22, 0.19)
      box(0.082, 0.073, 0.805, 0.58, 0.035, 0.055, 0.045)
      -- Compact-computer chin: rainbow badge and inset floppy drive.
      local rainbow = {
        { 0.35, 0.70, 0.30 },
        { 0.96, 0.79, 0.25 },
        { 0.95, 0.48, 0.20 },
        { 0.83, 0.24, 0.28 },
        { 0.60, 0.32, 0.65 },
        { 0.26, 0.60, 0.83 },
      }
      for stripe, color in ipairs(rainbow) do
        box(0.087, 0.686 + (stripe - 1) * 0.006, 0.033, 0.006, unpack(color))
      end
      box(0.61, 0.693, 0.245, 0.019, 0.48, 0.47, 0.42)
      box(0.62, 0.697, 0.223, 0.008, 0.12, 0.14, 0.14)
      box(0.785, 0.709, 0.045, 0.012, 0.64, 0.62, 0.54)
      -- Keyboard computer underneath the display, with stepped front lip.
      box(0.025, 0.78, 0.95, 0.19, 0.42, 0.42, 0.36)
      box(0.025, 0.768, 0.93, 0.183, 0.83, 0.81, 0.73)
      box(0.04, 0.777, 0.90, 0.008, 0.94, 0.90, 0.78)
      box(0.095, 0.80, 0.68, 0.119, 0.29, 0.30, 0.28)
      for row = 0, 3 do
        for key = 0, 11 do
          if row < 3 or key < 3 or key > 8 then
            box(0.104 + key * 0.055, 0.807 + row * 0.027, 0.047, 0.021, 0.68, 0.67, 0.60)
            box(0.108 + key * 0.055, 0.809 + row * 0.027, 0.036, 0.004, 0.94, 0.92, 0.84)
          end
        end
      end
      box(0.27, 0.888, 0.32, 0.021, 0.77, 0.75, 0.67)
      box(0.795, 0.837, 0.135, 0.065, 0.63, 0.62, 0.55)
      box(0.80, 0.841, 0.125, 0.055, 0.89, 0.87, 0.79)
      local sx, sy, sw, sh = x + w * 0.09, y + h * 0.08, w * 0.79, h * 0.565
      local tv = self:view(rec)
      local pw, ph = tv:pixelSize()
      if pw > 0 and ph > 0 then
        local scale = math.min(sw / pw, sh / ph)
        if scale > 0 then
          lg.push("all")
          lg.translate(sx + sw / 2, sy + sh / 2)
          lg.scale(1, math.max(0.001, boot))
          tv:draw(-pw * scale / 2, -ph * scale / 2, scale)
          lg.pop()
        end
      end
      if w > 95 and h > 65 then
        local name = rec.name == rec.host and app.cfg.hostShown(rec.host) or rec.name
        G.ui(UI.fit(name or "SESSION", w * 0.43), x + w * 0.14, y + h * 0.692, "ink")
        G.led(
          x + w * 0.88,
          y + h * 0.805,
          rec.state == app.core.ST.CONNECTED and "lgreen" or "amber",
          true,
          self.t
        )
        local badge = string.format("CBO / %02d", i)
        local badgeScale =
          math.min(1, w * 0.112 / G.uiWidth(badge), h * 0.04 / G.fontUI:getHeight())
        lg.push("all")
        lg.translate(x + w * 0.806, y + h * 0.85)
        lg.scale(badgeScale)
        G.ui(badge, 0, 0, "ink")
        lg.pop()
      end
    end
  end
  if #self.entries == 0 then
    UI.wrapped(
      (
        #app.sessions.list > 0 and "No matching sessions. Clear or change your search."
        or "Your monitor wall is ready. + NEW connects a terminal; every session gets its own live screen."
      ),
      20,
      self.top + 30,
      D.vw - 40,
      "cyan"
    )
  end
  G.panel(0, 0, D.vw, self.top - 4, "navy", "rust")
  G.ui("MONITOR WALL", 8, 9, "rust")
  require("src.lobby_views").draw(app, self.buttons, "map3", D.vw - 8, 5)
  local x = 8
  local function button(label, fn)
    local w = G.uiWidth(label) + 12
    G.panel(x, 32, w, 19, "ink", "cyan")
    G.ui(label, x + 6, 38, "white")
    self.buttons[#self.buttons + 1] = { x = x, y = 32, w = w, h = 19, fn = fn }
    x = x + w + 5
  end
  button("+ NEW", function()
    app.push("connect", { fromTerminal = true })
  end)
  button("FIT ALL", function()
    self:fit()
  end)
  button("100 VIEW", function()
    self:fit(100)
  end)
  button("FOCUS", function()
    self:focus()
  end)
  if D.vw - x > 220 then
    UI.label(
      string.format(
        "%s / %d SCREENS",
        self.simulation and "SIMULATION" or "RUST + LOVE",
        #self.entries
      ),
      x + 5,
      38,
      D.vw - x - 13,
      "gray"
    )
  end
  for i, label in ipairs({ "-", "+" }) do
    local bx = 8 + (i - 1) * 28
    G.panel(bx, 56, 24, 19, "ink", "cyan")
    G.ui(label, bx + 8, 62, "white")
    self.buttons[#self.buttons + 1] = {
      id = i == 1 and "zoomOut" or "zoomIn",
      x = bx,
      y = 56,
      w = 24,
      h = 19,
      fn = function()
        self:zoomBy(i == 1 and -1 or 1)
      end,
    }
  end
  local simLabel = self.simulation and "STOP SIM" or "SIMULATE"
  local simW = G.uiWidth(simLabel) + 12
  local simX = D.vw - simW - 8
  G.panel(simX, 56, simW, 19, "ink", self.simulation and "amber" or "cyan")
  G.ui(simLabel, simX + 6, 62, self.simulation and "amber" or "white")
  self.buttons[#self.buttons + 1] = {
    id = "simulate",
    x = simX,
    y = 56,
    w = simW,
    h = 19,
    fn = function()
      self:toggleSimulation()
    end,
  }
  UI.label(
    string.format(
      "ZOOM %d%%  /  %d OF %d SESSIONS",
      math.floor(self.camera.z * 100 + 0.5),
      #self.entries,
      #self:source()
    ),
    68,
    62,
    simX - 76,
    "gray"
  )
  self.field:draw(8, 80, D.vw - 16, self.t, 0)
  for i, label in ipairs({ "CAT", "BTC" }) do
    local bx = 8 + (i - 1) * 36
    G.panel(bx, 112, 32, 24, "ink", "cyan")
    G.ui(label, bx + 4, 120, "cyan")
    self.buttons[#self.buttons + 1] = {
      id = "art" .. label,
      x = bx,
      y = 112,
      w = 32,
      h = 24,
      fn = function()
        self:sendArt(label)
      end,
    }
  end
  G.panel(80, 112, 72, 24, "ink", "cyan")
  G.ui("ART", 80 + (72 - G.uiWidth("ART")) / 2, 120, "cyan")
  self.buttons[#self.buttons + 1] = {
    id = "wordArt",
    x = 80,
    y = 112,
    w = 72,
    h = 24,
    fn = function()
      self:sendWordArt()
    end,
  }
  self.command:draw(156, 112, D.vw - 250, self.t, 0)
  local sendX = D.vw - 88
  local count = #self:recipients()
  G.panel(sendX, 112, 80, 24, "ink", count > 0 and "amber" or "gray")
  G.ui("SEND " .. count, sendX + 6, 120, "amber")
  self.buttons[#self.buttons + 1] = {
    id = "sendCommand",
    x = sendX,
    y = 112,
    w = 80,
    h = 24,
    fn = function()
      self:sendCommand()
    end,
  }

  G.panel(0, self.bottom, D.vw, D.vh - self.bottom, "navy", "dblue")
  local bw = require("src.lobby_views").disconnect(
    app,
    self.buttons,
    not self.simulation and self.entries[self.sel] or nil,
    D.vw - 8,
    self.bottom + 3,
    self:selectionFocus()
  )
  UI.hints({
    { love.system.getOS() == "OS X" and "Cmd+scroll" or "wheel", "zoom" },
    { "drag", "pan" },
    { "Space", "focus" },
    { "0", "fit" },
    { "Enter", "open" },
  }, 8, self.bottom + 10, D.vw - bw - 24)
end
return Map3
