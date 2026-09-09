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

-- CRT post pipeline, after cool-retro-term (github.com/Swordfish90/cool-retro-term):
--   1. burn-in   : ping-pong canvas at native res, max(prev - decay, text), so
--                  glyphs linger and fade like phosphor
--   2. bloom     : quarter-res copy blurred in two separable passes
--   3. screen    : curvature, jitter, horizontal sync tear, RGB shift, static
--                  noise, a sweeping glow line, flicker, scanlines, vignette,
--                  then bloom added on top
-- Every stage but the last is skipped when opts.retro is off, which leaves the
-- original scanline + barrel look untouched. fx.retro holds the intensities;
-- the profile is roughly cool-retro-term's "Default Amber" with colour kept.
fx.retro = {
  bloom = 1.0, -- halo strength; glyphs are also pushed over-bright by it
  bg = { 16 / 255, 24 / 255, 48 / 255 }, -- terminal ground, subtracted before blurring
  burnIn = 0.45, -- 0 = instant decay, 1 = long persistence
  noise = 0.07,
  flicker = 0.08,
  jitter = 0.18,
  hsync = 0.06,
  rgbShift = 0.5,
  glowLine = 0.04,
  chroma = 0.55, -- phosphor modes: 0 = pure monochrome, 1 = keep every hue
}
-- cool-retro-term's classic tubes (fontColor of its Default Amber / Green /
-- White profiles). opts.phosphor picks one; "off" keeps the true colours.
fx.PHOSPHORS = { "off", "amber", "green", "white" }
fx.phosphorColor = {
  amber = { 1.0, 0.506, 0.0 },
  green = { 0.05, 0.8, 0.41 },
  white = { 0.94, 0.94, 0.94 },
}

local crtStates = setmetatable({}, { __mode = "k" }) -- canvas -> burn/bloom canvases

local function makeNoise()
  local n = 256
  local data = love.image.newImageData(n, n)
  local rnd = love.math.random
  data:mapPixel(function()
    return rnd(), rnd(), rnd(), rnd()
  end)
  local img = love.graphics.newImage(data)
  img:setWrap("repeat", "repeat")
  img:setFilter("linear", "linear")
  return img
end

local function newShader(src, what)
  local ok, sh = pcall(love.graphics.newShader, src)
  if ok then
    return sh
  end
  print("[fx] " .. what .. " shader failed: " .. tostring(sh))
  return nil
end

function fx.initCRT()
  fx.noiseImg = makeNoise()
  fx.crt = newShader(
    [[
    extern float scale;      // integer pixel scale
    extern float scanline;   // 0..1 darkness of odd lines
    extern float vignette;   // 0..1
    extern float barrel;     // 0 = off
    extern vec2 size;        // draw size in screen px
    extern float retro;      // 1 = cool-retro-term stages on
    extern float time;
    extern Image noiseTex;   // 256x256 random rgba, repeat
    extern Image burnTex;    // phosphor persistence buffer (native res)
    extern Image bloomTex;   // blurred quarter-res copy
    extern float bloom;
    extern float noise;
    extern float glowLine;
    extern float jitter;
    extern float rgbShift;
    extern float brightness;     // per-frame flicker
    extern float syncScale;      // per-frame horizontal sync tear
    extern float syncFreq;
    extern float mono;           // 1 = phosphor tube colouring on
    extern vec3 phosphor;        // tube colour
    extern float chroma;         // how much of the original hue survives

    // cool-retro-term convertWithChroma: luminance drives the tube colour,
    // chroma blends the original hue back in
    vec3 tube(vec3 c) {
      if (mono < 0.5) {
        return c;
      }
      float grey = dot(c, vec3(0.21, 0.72, 0.04));
      vec3 fg = mix(phosphor, c * phosphor / max(grey, 0.0001), chroma);
      return fg * grey;
    }

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
      vec2 sp = p; // static (undistorted-by-time) coords for scanline/burn/bloom
      vec3 col;
      if (retro > 0.5) {
        // horizontal sync: a sine tear that rolls with time
        p.x += sin((p.y + time) * syncFreq) * syncScale;
        vec4 nz = Texel(noiseTex, p * 6.0 + vec2(fract(time / 0.051), fract(time / 0.237)));
        // jitter: whole-picture wobble driven by the noise texture
        vec2 tp = p + (nz.ba - 0.5) * vec2(0.007, 0.002) * jitter;
        // rgb shift: chromatic fringing left/right
        vec2 d = vec2(rgbShift * 1.5 / size.x * scale, 0.0);
        // phosphor smear: strokes bleed half a native pixel sideways, so the
        // magnified bitmap font reads as soft light instead of hard stairs
        vec2 sm = vec2(0.5 / size.x * scale, 0.0);
        vec3 c0 = (Texel(tex, tp).rgb * 2.0 + Texel(tex, tp + sm).rgb + Texel(tex, tp - sm).rgb) * 0.25;
        vec3 cr = (Texel(tex, tp + d).rgb * 2.0 + Texel(tex, tp + d + sm).rgb + Texel(tex, tp + d - sm).rgb) * 0.25;
        vec3 cl = (Texel(tex, tp - d).rgb * 2.0 + Texel(tex, tp - d + sm).rgb + Texel(tex, tp - d - sm).rgb) * 0.25;
        col.r = cl.r * 0.10 + cr.r * 0.30 + c0.r * 0.60;
        col.g = cl.g * 0.20 + cr.g * 0.20 + c0.g * 0.60;
        col.b = cl.b * 0.30 + cr.b * 0.10 + c0.b * 0.60;
        // phosphor persistence: old glyphs linger below the fresh ones
        vec3 burn = Texel(burnTex, sp).rgb;
        col = max(col, burn * 0.65);
        // static noise (weaker toward the edges) + a glowing line sweeping down
        float dist = length(vec2(0.5) - uv);
        float g = nz.a * noise * (1.0 - dist * 1.3);
        float py = sp.y * size.y / scale;
        float rows = size.y / scale;
        // (a soft leading edge instead of cool-retro-term's hard cut)
        float tail = rows * 0.35;
        float lead = py - (rows + tail) * fract(time * 0.12);
        g += smoothstep(-tail, 0.0, lead) * (1.0 - smoothstep(0.0, tail * 0.25, lead)) * glowLine;
        col += vec3(g);
        col = tube(col);
      } else {
        col = Texel(tex, p).rgb;
      }
      if (retro > 0.5 && scale >= 2.0) {
        // cool-retro-term raster: each native row is a bright phosphor line
        // with dark gaps, visible once a row spans 2+ screen pixels
        float fy = fract(sp.y * size.y / scale) * 2.0 - 1.0;
        float mask = 1.0 - abs(fy);
        vec3 hi = ((1.0 + 0.3) - (0.2 * col)) * col;
        vec3 lo = ((1.0 - 0.3) + (0.1 * col)) * col;
        col = mix(col, mix(lo, hi, mask), scanline * 6.0);
      } else {
        // 1:1 scanlines: every other native pixel row darkened
        float line = mod(floor(sp.y * size.y / scale), 2.0);
        col *= 1.0 - scanline * line;
      }
      if (retro > 0.5) {
        // phosphor glow: the glyph itself runs hot, and its blurred light
        // spills into the surrounding cells
        col *= 1.0 + 0.35 * bloom;
        col += clamp(tube(Texel(bloomTex, sp).rgb) * bloom, 0.0, 0.85);
        col *= brightness;
      }
      vec2 dd = sp - 0.5;
      float v = 1.0 - vignette * dot(dd, dd) * 1.6;
      col *= v;
      return vec4(col, 1.0) * color;
    }
  ]],
    "CRT"
  )
  fx.burnSh = newShader(
    [[
    extern Image prevTex;
    extern float decay;
    vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
      vec3 cur = Texel(tex, uv).rgb;
      vec3 prev = Texel(prevTex, uv).rgb - vec3(decay);
      return vec4(max(prev, cur), 1.0);
    }
  ]],
    "burn-in"
  )
  fx.lightSh = newShader(
    [[
    extern vec3 bg;
    vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
      vec3 c = max(Texel(tex, uv).rgb - bg, vec3(0.0));
      return vec4(c * 2.5, 1.0);
    }
  ]],
    "bloom-light"
  )
  fx.blurSh = newShader(
    [[
    extern vec2 dir; // (1/w, 0) or (0, 1/h)
    vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
      vec3 c = Texel(tex, uv).rgb * 0.227;
      c += (Texel(tex, uv + dir * 1.385).rgb + Texel(tex, uv - dir * 1.385).rgb) * 0.316;
      c += (Texel(tex, uv + dir * 3.231).rgb + Texel(tex, uv - dir * 3.231).rgb) * 0.070;
      return vec4(c, 1.0) * color;
    }
  ]],
    "blur"
  )
end

local function crtState(canvas)
  local st = crtStates[canvas]
  if st then
    return st
  end
  local w, h = canvas:getWidth(), canvas:getHeight()
  local function cv(cw, ch, filter)
    local c = love.graphics.newCanvas(cw, ch)
    c:setFilter(filter, filter)
    c:renderTo(function()
      love.graphics.clear(0, 0, 0, 1)
    end)
    return c
  end
  local bw, bh = math.max(1, math.floor(w / 2)), math.max(1, math.floor(h / 2))
  st = {
    burnA = cv(w, h, "linear"), -- linear so the half-res bloom keeps 1 px strokes
    burnB = cv(w, h, "linear"),
    bloomA = cv(bw, bh, "linear"),
    bloomB = cv(bw, bh, "linear"),
    blurDir = { 0, 0 },
    lastTime = fx.time,
  }
  crtStates[canvas] = st
  return st
end

-- Burn-in and bloom passes for `canvas`; returns the two textures the screen
-- shader samples. Restores whatever canvas/shader/blend state was active.
local function retroPasses(canvas, st, r)
  local dt = math.min(0.1, math.max(0, fx.time - st.lastTime))
  st.lastTime = fx.time
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("replace", "premultiplied")
  -- burn-in: new = max(prev - decay, text); decay rate 6/s .. 0.8/s
  local rate = 6 - 5.2 * math.min(1, math.max(0, r.burnIn))
  fx.burnSh:send("prevTex", st.burnA)
  fx.burnSh:send("decay", rate * dt)
  love.graphics.setCanvas(st.burnB)
  love.graphics.setShader(fx.burnSh)
  love.graphics.draw(canvas, 0, 0)
  st.burnA, st.burnB = st.burnB, st.burnA
  -- bloom: keep only the light above the ground colour, at half res, then
  -- three separable blur iterations (about a 14 px halo at native res)
  local bw, bh = st.bloomA:getWidth(), st.bloomA:getHeight()
  fx.lightSh:send("bg", r.bg)
  love.graphics.setShader(fx.lightSh)
  love.graphics.setCanvas(st.bloomA)
  love.graphics.draw(st.burnA, 0, 0, 0, bw / canvas:getWidth(), bh / canvas:getHeight())
  love.graphics.setShader(fx.blurSh)
  for _ = 1, 3 do
    st.blurDir[1], st.blurDir[2] = 1 / bw, 0
    fx.blurSh:send("dir", st.blurDir)
    love.graphics.setCanvas(st.bloomB)
    love.graphics.draw(st.bloomA, 0, 0)
    st.blurDir[1], st.blurDir[2] = 0, 1 / bh
    fx.blurSh:send("dir", st.blurDir)
    love.graphics.setCanvas(st.bloomA)
    love.graphics.draw(st.bloomB, 0, 0)
  end
  love.graphics.pop()
  return st.burnA, st.bloomA
end

-- Blit a canvas through the CRT shader at integer scale. opts.crt == false
-- (or opts.enabled == false) skips the shader; opts.retro == true adds the
-- cool-retro-term stages. Allocation-free per call.
local crtSize = { 0, 0 }
local NO_OPTS = {}
function fx.drawCRT(canvas, x, y, scale, opts)
  opts = opts or NO_OPTS
  local enabled = opts.enabled ~= false and opts.crt ~= false and fx.crt
  if enabled then
    local sh = fx.crt
    local retro = opts.retro == true and fx.burnSh and fx.blurSh and fx.lightSh
    sh:send("scale", scale)
    sh:send("scanline", opts.scanline or 0.12)
    sh:send("vignette", opts.vignette or 0.25)
    sh:send("barrel", opts.barrel or 0)
    crtSize[1], crtSize[2] = canvas:getWidth() * scale, canvas:getHeight() * scale
    sh:send("size", crtSize)
    sh:send("retro", retro and 1 or 0)
    -- the retro path magnifies with linear filtering (soft phosphor); the
    -- plain path keeps the crisp nearest-neighbour pixels
    local want = retro and "linear" or "nearest"
    if canvas:getFilter() ~= want then
      canvas:setFilter(want, want)
    end
    if retro then
      local r = fx.retro
      local burn, bloom = retroPasses(canvas, crtState(canvas), r)
      local t = fx.time
      sh:send("time", t)
      sh:send("noiseTex", fx.noiseImg)
      sh:send("burnTex", burn)
      sh:send("bloomTex", bloom)
      sh:send("bloom", r.bloom)
      sh:send("noise", r.noise)
      sh:send("glowLine", r.glowLine)
      sh:send("jitter", r.jitter)
      sh:send("rgbShift", r.rgbShift)
      -- per-frame scalars, as cool-retro-term computes them in its vertex stage
      local n1 = love.math.noise(t * 7.3, 0.37)
      local n2 = love.math.noise(t * 0.9, 5.11)
      sh:send("brightness", 1 + (n1 - 0.5) * r.flicker)
      local strength = 0.05 + 0.3 * r.hsync
      local rv = strength - n2
      sh:send("syncScale", (rv > 0 and rv or 0) * strength * (r.hsync > 0 and 1 or 0))
      sh:send("syncFreq", 4 + 36 * n1)
      local tube = fx.phosphorColor[opts.phosphor or "off"]
      sh:send("mono", tube and 1 or 0)
      sh:send("phosphor", tube or fx.phosphorColor.amber)
      sh:send("chroma", r.chroma)
    end
    love.graphics.setShader(sh)
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
