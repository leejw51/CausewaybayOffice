-- Game feel toolbox: easing, tweens, fades, screen shake, particle bursts,
-- flash, typewriter reveal, and the CRT post shader.

local fx = {}

-- Easing (t in 0..1) --------------------------------------------------------

fx.ease = {}

function fx.ease.linear(t)
  return t
end

function fx.ease.expoIn(t)
  if t <= 0 then
    return 0
  end
  if t >= 1 then
    return 1
  end
  return 2 ^ (10 * (t - 1))
end

function fx.ease.expoOut(t)
  if t <= 0 then
    return 0
  end
  if t >= 1 then
    return 1
  end
  return 1 - 2 ^ (-10 * t)
end

function fx.ease.expoInOut(t)
  if t <= 0 then
    return 0
  end
  if t >= 1 then
    return 1
  end
  if t < 0.5 then
    return 0.5 * 2 ^ (20 * t - 10)
  end
  return 1 - 0.5 * 2 ^ (-20 * t + 10)
end

function fx.ease.backOut(t)
  if t <= 0 then
    return 0
  end
  if t >= 1 then
    return 1
  end
  local c1 = 1.70158
  local c3 = c1 + 1
  local u = t - 1
  return 1 + c3 * u * u * u + c1 * u * u
end

function fx.clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

function fx.lerp(a, b, t)
  return a + (b - a) * t
end

-- Exponential approach (frame-rate independent smoothing).
function fx.approach(cur, target, dt, speed)
  return target + (cur - target) * math.exp(-(speed or 12) * dt)
end

-- Tweens ---------------------------------------------------------------------

local tweens = {}

-- fx.tween(obj, {field = target, ...}, duration, easeName, onDone) -> handle
function fx.tween(obj, to, dur, ease, onDone)
  local tw = {
    obj = obj,
    from = {},
    to = to,
    t = 0,
    dur = math.max(0.0001, dur or 0.3),
    ease = fx.ease[ease or "expoOut"] or fx.ease.expoOut,
    onDone = onDone,
    alive = true,
  }
  for k, v in pairs(to) do
    tw.from[k] = obj[k] or 0
  end
  -- replace tweens targeting the same fields on this object
  for _, other in ipairs(tweens) do
    if other.obj == obj and other.alive then
      for k in pairs(to) do
        if other.to[k] ~= nil then
          other.to[k] = nil
        end
      end
    end
  end
  tweens[#tweens + 1] = tw
  return tw
end

-- Cancels a tween or a timer handle (fx.after). Safe on nil / finished ones.
function fx.cancel(tw)
  if tw then
    tw.alive = false
  end
end

local function updateTweens(dt)
  local i = 1
  while i <= #tweens do
    local tw = tweens[i]
    if tw.alive then
      tw.t = tw.t + dt
      local u = tw.ease(fx.clamp(tw.t / tw.dur, 0, 1))
      for k, target in pairs(tw.to) do
        tw.obj[k] = tw.from[k] + (target - tw.from[k]) * u
      end
      if tw.t >= tw.dur then
        tw.alive = false
        if tw.onDone then
          tw.onDone()
        end
      end
    end
    if not tw.alive then
      table.remove(tweens, i)
    else
      i = i + 1
    end
  end
end

-- Timers ---------------------------------------------------------------------

local timers = {}

-- fx.after(delay, fn) -> handle; fx.cancel(handle) drops it before it fires
-- (scenes cancel their timers in leave() so nothing runs on a dead scene).
function fx.after(delay, fn)
  local tm = { t = delay, fn = fn, alive = true }
  timers[#timers + 1] = tm
  return tm
end

function fx.timerCount()
  local n = 0
  for _, tm in ipairs(timers) do
    if tm.alive then
      n = n + 1
    end
  end
  return n
end

local function updateTimers(dt)
  local i = 1
  while i <= #timers do
    local tm = timers[i]
    if not tm.alive then
      table.remove(timers, i)
    else
      tm.t = tm.t - dt
      if tm.t <= 0 then
        table.remove(timers, i)
        tm.alive = false
        tm.fn()
      else
        i = i + 1
      end
    end
  end
end

-- Fade (full-screen black overlay) ------------------------------------------

fx.fade = { a = 0 }

function fx.fadeOut(dur, onDone)
  fx.tween(fx.fade, { a = 1 }, dur or 0.25, "expoIn", onDone)
end

function fx.fadeIn(dur, onDone)
  fx.tween(fx.fade, { a = 0 }, dur or 0.45, "expoOut", onDone)
end

-- Scene transition: fade to black, swap, fade back. `swap` is called at the
-- darkest point. Nothing cuts.
function fx.transition(swap, outDur, inDur)
  if fx.transitioning then
    return false
  end
  fx.transitioning = true
  fx.fadeOut(outDur or 0.22, function()
    if swap then
      swap()
    end
    fx.fadeIn(inDur or 0.5, function()
      fx.transitioning = false
    end)
  end)
  return true
end

function fx.drawFade(w, h)
  if fx.fade.a > 0.001 then
    love.graphics.setColor(0.055, 0.063, 0.19, fx.fade.a) -- night_navy
    love.graphics.rectangle("fill", 0, 0, w, h)
  end
end

-- Flash (white-ish overlay that decays exponentially) -----------------------

fx.flashV = { a = 0, r = 1, g = 1, b = 1 }

function fx.flash(strength, r, g, b, dur)
  fx.flashV.a = math.max(fx.flashV.a, strength or 0.6)
  fx.flashV.r, fx.flashV.g, fx.flashV.b = r or 1, g or 1, b or 1
  fx.tween(fx.flashV, { a = 0 }, dur or 0.35, "expoOut")
end

function fx.drawFlash(w, h)
  local f = fx.flashV
  if f.a > 0.002 then
    love.graphics.setColor(f.r, f.g, f.b, f.a)
    love.graphics.rectangle("fill", 0, 0, w, h)
  end
end

-- Screen shake ---------------------------------------------------------------

local shake = { amp = 0, t = 0, dur = 0 }
fx.shakeX, fx.shakeY = 0, 0

function fx.shake(amp, dur)
  shake.amp = math.max(shake.amp, amp or 4)
  shake.dur = math.max(shake.dur, dur or 0.3)
  shake.t = 0
end

local function updateShake(dt)
  if shake.dur <= 0 then
    fx.shakeX, fx.shakeY = 0, 0
    return
  end
  shake.t = shake.t + dt
  local k = 1 - fx.clamp(shake.t / shake.dur, 0, 1)
  k = k * k
  local a = shake.amp * k
  fx.shakeX = math.floor((love.math.random() * 2 - 1) * a + 0.5)
  fx.shakeY = math.floor((love.math.random() * 2 - 1) * a + 0.5)
  if shake.t >= shake.dur then
    shake.dur, shake.amp = 0, 0
    fx.shakeX, fx.shakeY = 0, 0
  end
end

-- Particles ------------------------------------------------------------------

local particles = {}

-- Hard bound on the pool: a long walk (dust every 120 ms) or a burst storm can
-- never grow it without limit; the oldest particle makes room for a new one.
fx.MAX_PARTICLES = 512
local function push(p)
  if #particles >= fx.MAX_PARTICLES then
    table.remove(particles, 1)
  end
  particles[#particles + 1] = p
end

-- fx.burst(x, y, n, {r,g,b}, speed)
function fx.burst(x, y, n, col, speed)
  col = col or { 1, 0.6, 0.3 }
  speed = speed or 90
  for _ = 1, n or 24 do
    local ang = love.math.random() * math.pi * 2
    local v = speed * (0.4 + love.math.random() * 0.8)
    push({
      x = x,
      y = y,
      vx = math.cos(ang) * v,
      vy = math.sin(ang) * v - speed * 0.4,
      life = 0.5 + love.math.random() * 0.5,
      t = 0,
      size = love.math.random(1, 3),
      r = col[1],
      g = col[2],
      b = col[3],
    })
  end
end

-- Sprite burst (particle_spark strip): no gravity, drag 0.9, 4 frames over
-- the particle's life. `strip` comes from gfx.strip.
function fx.sparkBurst(x, y, n, strip, speed)
  speed = speed or 120
  for _ = 1, n or 24 do
    local ang = love.math.random() * math.pi * 2
    local v = speed * (0.5 + love.math.random() * 0.8)
    push({
      x = x,
      y = y,
      vx = math.cos(ang) * v,
      vy = math.sin(ang) * v,
      life = 0.45 + love.math.random() * 0.3,
      t = 0,
      strip = strip,
      size = love.math.random() < 0.5 and 8 or 16,
      drag = true,
    })
  end
end

-- Confetti: strip pieces (frame = piece index) thrown up with gravity and
-- drag, spinning. Dust: a short-lived footstep puff playing the strip once.
function fx.confettiBurst(x, y, n, strip, speed)
  speed = speed or 140
  for i = 1, n or 24 do
    local ang = -math.pi / 2 + (love.math.random() - 0.5) * math.pi * 1.2
    local v = speed * (0.5 + love.math.random() * 0.8)
    push({
      x = x,
      y = y,
      vx = math.cos(ang) * v,
      vy = math.sin(ang) * v,
      life = 0.9 + love.math.random() * 0.5,
      t = 0,
      strip = strip,
      frame = ((i - 1) % (strip and strip.n or 1)) + 1,
      size = 6 + love.math.random(0, 4),
      gravity = 260,
      drag = true,
      dragK = 0.985,
      spin = (love.math.random() - 0.5) * 12,
      rot = love.math.random() * math.pi * 2,
      kind = "confetti",
    })
  end
end

function fx.dustPuff(x, y, strip, dir)
  push({
    x = x,
    y = y,
    vx = -(dir or 1) * 14,
    vy = -8,
    life = 0.28,
    t = 0,
    strip = strip,
    size = 8,
    kind = "dust",
    drag = true,
    dragK = 0.9,
  })
end

function fx.particleCount(kind)
  if not kind then
    return #particles
  end
  local n = 0
  for _, p in ipairs(particles) do
    if p.kind == kind then
      n = n + 1
    end
  end
  return n
end

local function updateParticles(dt)
  local i = 1
  while i <= #particles do
    local p = particles[i]
    p.t = p.t + dt
    if p.drag then
      local k = (p.dragK or 0.9) ^ (dt * 60)
      p.vx, p.vy = p.vx * k, p.vy * k
      if p.gravity then
        p.vy = p.vy + p.gravity * dt
      end
    else
      p.vy = p.vy + 160 * dt
    end
    if p.spin then
      p.rot = p.rot + p.spin * dt
    end
    p.x = p.x + p.vx * dt
    p.y = p.y + p.vy * dt
    if p.t >= p.life then
      table.remove(particles, i)
    else
      i = i + 1
    end
  end
end

function fx.drawParticles()
  for _, p in ipairs(particles) do
    local a = 1 - p.t / p.life
    if p.strip then
      local frame = p.frame or math.min(p.strip.n, 1 + math.floor((p.t / p.life) * p.strip.n))
      local q = p.strip.quads[frame]
      love.graphics.setColor(1, 1, 1, math.min(1, a * 1.5))
      local sc = p.size / p.strip.fw
      if p.rot then
        local hw, hh = p.strip.fw / 2, p.strip.fh / 2
        love.graphics.draw(p.strip.img, q, math.floor(p.x), math.floor(p.y), p.rot, sc, sc, hw, hh)
      else
        love.graphics.draw(
          p.strip.img,
          q,
          math.floor(p.x - p.size / 2),
          math.floor(p.y - p.size / 2),
          0,
          sc,
          sc
        )
      end
    else
      love.graphics.setColor(p.r, p.g, p.b, a)
      local s = p.size
      love.graphics.rectangle("fill", math.floor(p.x), math.floor(p.y), s, s)
    end
  end
end

-- Typewriter -----------------------------------------------------------------

-- Reveals text at `cps` chars/second, utf8-aware. tw:update(dt), tw.text
-- holds the visible prefix, tw.done when complete.
function fx.typewriter(text, cps)
  local utf8 = require("utf8")
  local tw = { full = text or "", cps = cps or 60, acc = 0, n = 0, text = "", done = false }
  tw.total = utf8.len(tw.full) or #tw.full
  function tw:update(dt)
    if self.done then
      return
    end
    self.acc = self.acc + dt * self.cps
    local n = math.floor(self.acc)
    if n > self.n then
      self.n = math.min(n, self.total)
      local off = utf8.offset(self.full, self.n + 1)
      self.text = off and self.full:sub(1, off - 1) or self.full
      if self.n >= self.total then
        self.done = true
      end
    end
  end
  function tw:append(more)
    self.full = self.full .. more
    self.total = utf8.len(self.full) or #self.full
    self.done = false
  end
  function tw:skip()
    self.n = self.total
    self.text = self.full
    self.done = true
  end
  return tw
end

-- CRT shader -----------------------------------------------------------------

fx.crt = nil

function fx.initCRT()
  local ok, sh = pcall(
    love.graphics.newShader,
    [[
    extern float scale;      // integer pixel scale
    extern float scanline;   // 0..1 darkness of odd lines
    extern float vignette;   // 0..1
    extern float barrel;     // 0 = off
    extern vec2 size;        // draw size in screen px
    vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
      vec2 p = uv;
      if (barrel > 0.0) {
        vec2 c = p - 0.5;
        float r2 = dot(c, c);
        p = 0.5 + c * (1.0 + barrel * r2);
        if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) {
          return vec4(0.0, 0.0, 0.0, color.a);
        }
      }
      vec4 col = Texel(tex, p);
      float line = mod(floor(p.y * size.y / scale), 2.0);
      col.rgb *= 1.0 - scanline * line;
      vec2 d = p - 0.5;
      float v = 1.0 - vignette * dot(d, d) * 1.6;
      col.rgb *= v;
      return col * color;
    }
  ]]
  )
  if ok then
    fx.crt = sh
  else
    print("[fx] CRT shader failed: " .. tostring(sh))
  end
end

-- Blit a canvas through the CRT shader at integer scale. opts.crt == false
-- (or opts.enabled == false) skips the shader. Allocation-free per call.
local crtSize = { 0, 0 }
local NO_OPTS = {}
function fx.drawCRT(canvas, x, y, scale, opts)
  opts = opts or NO_OPTS
  local enabled = opts.enabled ~= false and opts.crt ~= false and fx.crt
  if enabled then
    fx.crt:send("scale", scale)
    fx.crt:send("scanline", opts.scanline or 0.12)
    fx.crt:send("vignette", opts.vignette or 0.25)
    fx.crt:send("barrel", opts.barrel or 0)
    crtSize[1], crtSize[2] = canvas:getWidth() * scale, canvas:getHeight() * scale
    fx.crt:send("size", crtSize)
    love.graphics.setShader(fx.crt)
  end
  love.graphics.setColor(1, 1, 1, opts.alpha or 1)
  love.graphics.draw(canvas, x, y, 0, scale, scale)
  if enabled then
    love.graphics.setShader()
  end
end

-- Global update ---------------------------------------------------------------

fx.time = 0

function fx.update(dt)
  fx.time = fx.time + dt
  updateTweens(dt)
  updateTimers(dt)
  updateShake(dt)
  updateParticles(dt)
end

function fx.reset()
  tweens, timers, particles = {}, {}, {}
  fx.fade.a = 0
  fx.flashV.a = 0
  fx.transitioning = false
end

return fx
