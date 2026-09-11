-- Boot: CRT power-on flash, logo_hero key art fades in, title drops in
-- (expo-out). Any key / click, or 2.5s, moves on to the lobby.

local Boot = {}
Boot.__index = Boot

function Boot.new(app)
  local s = setmetatable({}, Boot)
  s.app = app
  s.t = 0
  s.logo = { y = -60, a = 0 }
  s.art = { a = 0 }
  s.sub = { a = 0 }
  s.done = false
  return s
end

function Boot:enter()
  local fx = self.app.fx
  fx.fade.a = 0
  fx.flash(1, 0.9, 0.95, 1, 0.5)
  fx.after(0.4, function()
    fx.tween(self.art, { a = 1 }, 0.6, "expoOut")
  end)
  fx.tween(self.logo, { y = 0, a = 1 }, 0.9, "expoOut")
  fx.after(0.7, function()
    fx.tween(self.sub, { a = 1 }, 0.6, "expoOut")
  end)
end

function Boot:advance()
  if self.done then
    return
  end
  -- switch() refuses during a transition; stay armed so the next Space works
  if self.app.switch("lobby") then
    self.done = true
    self.app.audio.play("select")
  end
end

-- The title waits for the player: only Space moves on. No timer, no click.
function Boot:update(dt)
  self.t = self.t + dt
end

function Boot:keypressed(key)
  if key == "space" then
    self:advance()
  end
end

function Boot:mousepressed()
  -- clicks do nothing here: Space is the only way in
end

-- Key art covers the content rect (16:9 source, centre-cropped).
function Boot:drawArt()
  local app = self.app
  local G, D = app.G, app.D
  local vw, vh = D.vw, D.vh
  if not G.exists("logo_hero") then
    app.drawSkyline(self.t * 4, 1)
    return
  end
  local k = math.max(vw / 1280, vh / 720)
  local w, h = math.ceil(1280 * k), math.ceil(720 * k)
  local img = G.sprite("logo_hero", w, h, { noChroma = true })
  love.graphics.setColor(0.055, 0.063, 0.19, 1)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(self.art.a, self.art.a, self.art.a, 1)
  love.graphics.draw(img, math.floor((vw - w) / 2), math.floor((vh - h) / 2))
end

function Boot:draw()
  local app = self.app
  local G, D = app.G, app.D
  local vw, vh = D.vw, D.vh
  local t = self.t

  self:drawArt()

  -- power-on: a bright horizontal line that opens into the picture
  if t < 0.45 then
    local k = app.fx.ease.expoOut(t / 0.45)
    local h = math.max(1, math.floor(vh * k))
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("fill", 0, 0, vw, math.floor((vh - h) / 2))
    love.graphics.rectangle("fill", 0, math.floor((vh + h) / 2), vw, vh)
    love.graphics.setColor(1, 1, 1, 1 - k)
    love.graphics.rectangle("fill", 0, math.floor(vh / 2) - 1, vw, 2)
  end

  -- title in the sky band (top third), PressStart2P 16px = 8px font x2
  local title = "CAUSEWAYBAY OFFICE"
  local scale = 2
  local tw = G.uiWidth(title) * scale
  local lx = math.floor((vw - tw) / 2)
  local ly = math.floor(vh * 0.12 + self.logo.y)
  love.graphics.setFont(G.fontUI)
  love.graphics.setColor(0, 0, 0, 0.7 * self.logo.a)
  love.graphics.print(title, lx + 2, ly + 2, 0, scale, scale)
  local r, g, b = G.rgb("rust")
  love.graphics.setColor(r, g, b, self.logo.a)
  love.graphics.print(title, lx, ly, 0, scale, scale)
  love.graphics.setColor(1, 0.9, 0.7, self.logo.a * (0.3 + 0.2 * math.sin(t * 5)))
  love.graphics.rectangle("fill", lx, ly + 8 * scale + 3, tw, 1)

  local sub = "retro ssh workstation  ·  香港 銅鑼灣"
  local sx = math.floor((vw - G.textWidth(sub)) / 2)
  G.text(sub, sx + 1, ly + 25, "black", 0.6 * self.sub.a)
  G.text(sub, sx, ly + 24, "cyan", self.sub.a)

  if t > 1.2 then
    local blink = 0.5 + 0.5 * math.sin(t * 6)
    local msg = "PRESS SPACE"
    local mx = math.floor((vw - G.uiWidth(msg)) / 2)
    G.ui(msg, mx + 1, math.floor(vh * 0.9) + 1, "black", 0.6 * blink)
    G.ui(msg, mx, math.floor(vh * 0.9), "yellow", blink)
  end
  G.ui("v0.1.1  core " .. app.core.version, 6, vh - 12, "gray", 0.7)
end

return Boot
