-- Palette (Raiden MSX family + rust accent), chroma-key sprite loader with
-- labelled placeholders for missing assets, and the two fonts:
--   G.fontUI   PressStart2P 8px  (headings, labels)
--   G.fontTerm Unifont 16px      (terminal + any body text: CJK/Hangul/Czech)
-- Everything is rasterized once at native size and drawn at integer scale.

local G = {}

G.palette = {
  black = { 0.00, 0.00, 0.00 },
  navy = { 0.06, 0.09, 0.19 },
  ink = { 0.10, 0.10, 0.35 },
  dblue = { 0.35, 0.33, 0.88 },
  lblue = { 0.50, 0.46, 0.95 },
  cyan = { 0.40, 0.86, 0.94 },
  dgreen = { 0.23, 0.64, 0.25 },
  green = { 0.24, 0.72, 0.29 },
  lgreen = { 0.45, 0.82, 0.49 },
  dred = { 0.73, 0.37, 0.32 },
  rust = { 0.86, 0.40, 0.27 },
  lred = { 1.00, 0.54, 0.49 },
  dyellow = { 0.80, 0.76, 0.37 },
  yellow = { 0.87, 0.82, 0.53 },
  magenta = { 0.72, 0.40, 0.71 },
  dgray = { 0.30, 0.32, 0.40 },
  gray = { 0.62, 0.64, 0.70 },
  lgray = { 0.80, 0.80, 0.80 },
  white = { 1.00, 1.00, 1.00 },
  termbg = { 0.063, 0.094, 0.188 },
  -- OFFICE accents (STYLE.md 1.2)
  rust_dark = { 0.62, 0.275, 0.19 },
  neon_pink = { 1.0, 0.31, 0.64 },
  neon_cyan = { 0.24, 0.95, 0.95 },
  night_navy = { 0.055, 0.063, 0.19 },
  panel_navy = { 0.10, 0.12, 0.31 },
  amber = { 1.0, 0.69, 0.0 },
  phosphor = { 0.2, 1.0, 0.4 },
  alarm = { 1.0, 0.23, 0.19 },
  led_off = { 0.23, 0.23, 0.27 },
  beige = { 0.79, 0.75, 0.63 },
}

G.chroma = nil
G.imgs = {}
G.placeholders = {} -- Image -> true when it stands in for a missing asset
G.fontUI = nil
G.fontTerm = nil
G.ASSETS = "assets/"

function G.init()
  G.chroma = love.graphics.newShader([[
    vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
      vec4 c = Texel(tex, uv);
      if (c.g < 0.46 && c.r > 0.70 && c.b > 0.70) {
        float hot = (c.r + c.b) * 0.5 - c.g;
        if (hot > 0.42) {
          c.a = 0.0;
        }
      }
      return c * color;
    }
  ]])
  G.loadFonts()
end

local function tryFont(path, size, hinting)
  local ok, f = pcall(love.graphics.newFont, path, size, hinting)
  if ok then
    f:setFilter("nearest", "nearest")
    return f
  end
  local d = love.graphics.newFont(size)
  d:setFilter("nearest", "nearest")
  return d
end

function G.loadFonts()
  G.fontUI = tryFont(G.ASSETS .. "fonts/PressStart2P.ttf", 8, "mono")
  G.fontTerm = tryFont(G.ASSETS .. "fonts/unifont.otf", 16, "mono")
  -- UI fallback glyphs must share the 8px label height.
  pcall(function()
    G.fontUI:setFallbacks(tryFont(G.ASSETS .. "fonts/unifont.otf", 8, "mono"))
  end)
  love.graphics.setFont(G.fontTerm)
end

-- Placeholder: bordered box in `col` with the asset name written inside.
function G.placeholder(w, h, col, label)
  w, h = math.max(4, math.floor(w)), math.max(4, math.floor(h))
  col = col or G.palette.magenta
  local c = love.graphics.newCanvas(w, h)
  c:setFilter("nearest", "nearest")
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setScissor()
  love.graphics.setCanvas(c)
  love.graphics.clear(col[1] * 0.35, col[2] * 0.35, col[3] * 0.35, 1)
  love.graphics.setColor(col[1], col[2], col[3], 1)
  love.graphics.rectangle("line", 0.5, 0.5, w - 1, h - 1)
  love.graphics.line(0, 0, w, h)
  love.graphics.line(w, 0, 0, h)
  if label and G.fontUI and w >= 40 and h >= 12 then
    love.graphics.setFont(G.fontUI)
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.printf(label, 2, math.floor(h / 2) - 4, w - 4, "center")
  end
  love.graphics.setCanvas()
  love.graphics.pop()
  local img = love.graphics.newImage(c:newImageData())
  img:setFilter("nearest", "nearest")
  return img
end

local function tightChroma(data)
  local w, h = data:getDimensions()
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r, g, b, a = data:getPixel(x, y)
      if a > 0 and g < 0.42 and r > 0.75 and b > 0.75 then
        data:setPixel(x, y, 0, 0, 0, 0)
      end
    end
  end
end

-- Raw source image (cached). Tries .png then .jpg. nil when missing.
local rawCache = {}
function G.raw(name)
  if rawCache[name] ~= nil then
    return rawCache[name] or nil
  end
  local img = nil
  for _, ext in ipairs({ ".png", ".jpg" }) do
    local path = G.ASSETS .. name .. ext
    if love.filesystem.getInfo(path) then
      local ok, im = pcall(love.graphics.newImage, path)
      if ok then
        img = im
        break
      end
    end
  end
  rawCache[name] = img or false
  return img
end

local function keyedCanvas(img, tw, th, chroma, quad)
  local c = love.graphics.newCanvas(tw, th)
  c:setFilter("nearest", "nearest")
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setScissor() -- callers may be mid-frame with a scissor set
  love.graphics.setCanvas(c)
  love.graphics.clear(0, 0, 0, 0)
  if chroma then
    love.graphics.setShader(G.chroma)
  end
  love.graphics.setColor(1, 1, 1, 1)
  if quad then
    local _, _, qw, qh = quad:getViewport()
    love.graphics.draw(img, quad, 0, 0, 0, tw / qw, th / qh)
  else
    love.graphics.draw(img, 0, 0, 0, tw / img:getWidth(), th / img:getHeight())
  end
  love.graphics.setShader()
  love.graphics.setCanvas()
  love.graphics.pop()
  return c
end

-- Load assets/<name>.png resampled to tw x th with magenta keyed out on the
-- GPU. Small results get a per-pixel clean-up pass and become Images; big
-- ones (backgrounds, bezel) stay Canvases. Never errors: a missing/broken
-- file yields a labelled placeholder.
function G.sprite(name, tw, th, opts)
  opts = opts or {}
  local key = name .. ":" .. tostring(tw) .. "x" .. tostring(th) .. (opts.noChroma and ":o" or "")
  if G.imgs[key] then
    return G.imgs[key]
  end
  local img = G.raw(name)
  local out
  if not img then
    out = G.placeholder(tw or 32, th or 32, opts.color or G.palette.magenta, name)
    G.placeholders[out] = true
  else
    tw, th = tw or img:getWidth(), th or img:getHeight()
    img:setFilter("linear", "linear")
    local c = keyedCanvas(img, tw, th, not opts.noChroma)
    -- always bake to an Image: a Canvas loses its contents across
    -- love.window.setMode / fullscreen (the world map went blank after F11).
    -- The per-pixel chroma clean-up stays limited to small sprites.
    local data = c:newImageData()
    if not opts.noChroma and tw * th <= 65536 then
      tightChroma(data)
    end
    out = love.graphics.newImage(data)
    c:release()
    out:setFilter("nearest", "nearest")
    if opts.wrap then
      out:setWrap("repeat", "repeat")
    end
  end
  G.imgs[key] = out
  return out
end

function G.isPlaceholder(img)
  return G.placeholders[img] == true
end

function G.exists(name)
  return G.raw(name) ~= nil
end

-- Background layer: nil when missing (callers draw a procedural fallback).
-- opts.chroma keys the magenta sky out (mid/near layers).
function G.layer(name, tw, th, opts)
  if not G.exists(name) then
    return nil
  end
  opts = opts or {}
  return G.sprite(name, tw, th, { noChroma = not opts.chroma, wrap = true })
end

-- Icons: whole 1024 box drawn at `size` (they carry their own margin).
function G.icon(name, size)
  return G.sprite(name, size, size)
end

-- Draw an icon so its glyph fills a `box` px slot (source margin ~25%).
function G.drawIcon(name, x, y, box, a)
  local size = math.floor(box * 1.4 + 0.5)
  local off = math.floor((size - box) / 2)
  love.graphics.setColor(1, 1, 1, a or 1)
  love.graphics.draw(G.icon(name, size), math.floor(x) - off, math.floor(y) - off)
end

-- Strips ------------------------------------------------------------------
-- A 1280x720 strip of n equal cells. Each cell is measured (sub-sampled scan
-- for non-chroma pixels) so the frame crop follows the drawn content, then
-- rendered into an fw x fh frame. mode "each" crops every cell to its own
-- bbox (LED lamps that drift), "union" keeps one crop for all cells (keeps
-- the intended animation offsets).
local function isChroma(r, g, b)
  return g < 0.46 and r > 0.70 and b > 0.70 and ((r + b) * 0.5 - g) > 0.42
end

local function cellBounds(data, n, stride)
  local w, h = data:getDimensions()
  local cw = math.floor(w / n)
  local out = {}
  for i = 0, n - 1 do
    local x0, y0, x1, y1 = cw, h, 0, 0
    for y = 0, h - 1, stride do
      for x = 0, cw - 1, stride do
        local r, g, b, a = data:getPixel(i * cw + x, y)
        if a > 0.5 and not isChroma(r, g, b) then
          if x < x0 then
            x0 = x
          end
          if x > x1 then
            x1 = x
          end
          if y < y0 then
            y0 = y
          end
          if y > y1 then
            y1 = y
          end
        end
      end
    end
    if x1 < x0 then
      x0, y0, x1, y1 = 0, 0, cw - 1, h - 1
    end
    out[i + 1] = { x = x0, y = y0, w = x1 - x0 + stride, h = y1 - y0 + stride }
  end
  return out, cw
end

local stripCache = {}
-- Anchored character strips ("anchor" mode): AI-generated frames drift by a
-- few source px, so every frame is cropped to its own content bbox, drawn at
-- one common scale and pinned by the bbox's bottom-centre to the cell's
-- bottom-centre (feet never move). Frames whose bbox deviates more than
-- `deviant` (fraction, default 0.06) from the median are dropped; `pick = 2`
-- keeps only the most similar pair (hands up / hands down). `lockBelow` /
-- `lockAbove` (fractions of the frame height) copy frame 1 into every other
-- frame outside the band between them, so only that band (the hands at the
-- keyboard) animates and the head / torso / legs never shimmer.
local function median(t)
  local s = {}
  for i, v in ipairs(t) do
    s[i] = v
  end
  table.sort(s)
  return s[math.ceil(#s / 2)]
end

local function chooseFrames(boxes, opts)
  local n = #boxes
  local ws, hs = {}, {}
  for i, b in ipairs(boxes) do
    ws[i], hs[i] = b.w, b.h
  end
  local mw, mh = median(ws), median(hs)
  local tol = opts.deviant or 0.06
  local keep = {}
  for i, b in ipairs(boxes) do
    if math.abs(b.w - mw) <= mw * tol and math.abs(b.h - mh) <= mh * tol then
      keep[#keep + 1] = i
    end
  end
  if #keep < 2 then
    keep = {}
    for i = 1, n do
      keep[i] = i
    end
  end
  if opts.pick == 2 and #keep > 2 then
    local best, bi, bj = math.huge, keep[1], keep[2]
    for a = 1, #keep do
      for c = a + 1, #keep do
        local p, q = boxes[keep[a]], boxes[keep[c]]
        local d = math.abs(p.w - q.w) + math.abs(p.h - q.h)
        if d < best then
          best, bi, bj = d, keep[a], keep[c]
        end
      end
    end
    keep = { bi, bj }
  end
  return keep
end

function G.strip(name, n, fw, fh, opts)
  opts = opts or {}
  local key = name
    .. ":"
    .. n
    .. ":"
    .. fw
    .. "x"
    .. tostring(fh)
    .. ":"
    .. tostring(opts.mode)
    .. tostring(opts.pick)
    .. tostring(opts.lockBelow)
    .. tostring(opts.lockAbove)
  if stripCache[key] then
    return stripCache[key]
  end
  local strip = { n = n, fw = fw, fh = fh or fw, quads = {}, placeholder = false, anchors = {} }
  local img = G.raw(name)
  if not img then
    strip.img = G.placeholder(fw * n, strip.fh, G.palette.magenta, name)
    strip.placeholder = true
  elseif opts.mode == "anchor" then
    local path = love.filesystem.getInfo(G.ASSETS .. name .. ".png")
        and (G.ASSETS .. name .. ".png")
      or (G.ASSETS .. name .. ".jpg")
    local data = love.image.newImageData(path)
    local boxes, cw = cellBounds(data, n, 2)
    local chosen = chooseFrames(boxes, opts)
    strip.source = chosen
    n = #chosen
    strip.n = n
    -- common scale from the median box so the figure keeps one size
    local ws, hs = {}, {}
    for i, ci in ipairs(chosen) do
      ws[i], hs[i] = boxes[ci].w, boxes[ci].h
    end
    local mw, mh = median(ws), median(hs)
    if not fh then
      fh = math.max(1, math.floor(fw * mh / math.max(1, mw) + 0.5))
      strip.fh = fh
    end
    local k = math.min(fw / mw, fh / mh)
    strip.scale = k
    local sw, sh = img:getDimensions()
    local c = love.graphics.newCanvas(fw * n, fh)
    c:setFilter("nearest", "nearest")
    img:setFilter("linear", "linear")
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setCanvas(c)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setShader(G.chroma)
    love.graphics.setColor(1, 1, 1, 1)
    for i, ci in ipairs(chosen) do
      local b = boxes[ci]
      local dw, dh = b.w * k, b.h * k
      -- bottom-centre of the content lands on the cell's bottom-centre (integers)
      local dx = (i - 1) * fw + math.floor(fw / 2 - dw / 2 + 0.5)
      local dy = math.floor(fh - dh + 0.5)
      local q = love.graphics.newQuad((ci - 1) * cw + b.x, b.y, b.w, b.h, sw, sh)
      love.graphics.draw(img, q, dx, dy, 0, k, k)
      strip.anchors[i] = { x = fw / 2, y = fh }
    end
    love.graphics.setShader()
    love.graphics.setCanvas()
    love.graphics.pop()
    local out = c:newImageData()
    tightChroma(out)
    -- everything below lockBelow / above lockAbove is copied from frame 1
    -- (head, torso, legs, chair, desk stay pixel-identical; only the band
    -- between them, the hands at the keyboard, animates)
    local function lockRows(y0, y1)
      for i = 2, n do
        for y = y0, y1 do
          for x = 0, fw - 1 do
            local r, g, b, a = out:getPixel(x, y)
            out:setPixel((i - 1) * fw + x, y, r, g, b, a)
          end
        end
      end
    end
    if opts.lockBelow then
      lockRows(math.floor(fh * opts.lockBelow), fh - 1)
    end
    if opts.lockAbove then
      lockRows(0, math.floor(fh * opts.lockAbove) - 1)
    end
    strip.data = out
    strip.img = love.graphics.newImage(out)
    strip.img:setFilter("nearest", "nearest")
  else
    local path = love.filesystem.getInfo(G.ASSETS .. name .. ".png")
        and (G.ASSETS .. name .. ".png")
      or (G.ASSETS .. name .. ".jpg")
    local data = love.image.newImageData(path)
    local boxes, cw = cellBounds(data, n, 4)
    if opts.mode ~= "each" then
      local u = { x = math.huge, y = math.huge, x1 = 0, y1 = 0 }
      for _, b in ipairs(boxes) do
        u.x, u.y = math.min(u.x, b.x), math.min(u.y, b.y)
        u.x1, u.y1 = math.max(u.x1, b.x + b.w), math.max(u.y1, b.y + b.h)
      end
      for i = 1, n do
        boxes[i] = { x = u.x, y = u.y, w = u.x1 - u.x, h = u.y1 - u.y }
      end
    end
    if not fh then
      -- frame height follows the content so nothing is squashed
      local b = boxes[1]
      fh = math.max(1, math.floor(fw * b.h / math.max(1, b.w) + 0.5))
      strip.fh = fh
    end
    -- pad each crop to the target aspect so the frame is never distorted
    local sw, sh = img:getDimensions()
    local c = love.graphics.newCanvas(fw * n, fh)
    c:setFilter("nearest", "nearest")
    img:setFilter("linear", "linear")
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setCanvas(c)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setShader(G.chroma)
    love.graphics.setColor(1, 1, 1, 1)
    for i = 1, n do
      local b = boxes[i]
      local bw, bh = b.w, b.h
      local aspect = fw / fh
      if bw / bh < aspect then
        bw = bh * aspect
      else
        bh = bw / aspect
      end
      local bx = (i - 1) * cw + b.x + (b.w - bw) / 2
      local by = b.y + (b.h - bh) / 2
      local q = love.graphics.newQuad(bx, by, bw, bh, sw, sh)
      love.graphics.draw(img, q, (i - 1) * fw, 0, 0, fw / bw, fh / bh)
    end
    love.graphics.setShader()
    love.graphics.setCanvas()
    love.graphics.pop()
    local out = c:newImageData()
    tightChroma(out)
    strip.img = love.graphics.newImage(out)
    strip.img:setFilter("nearest", "nearest")
  end
  for i = 1, n do
    strip.quads[i] = love.graphics.newQuad((i - 1) * fw, 0, fw, strip.fh, fw * n, strip.fh)
  end
  stripCache[key] = strip
  return strip
end

function G.drawFrame(strip, i, x, y, scale, a)
  local q = strip.quads[((i - 1) % strip.n) + 1]
  love.graphics.setColor(1, 1, 1, a or 1)
  love.graphics.draw(strip.img, q, math.floor(x), math.floor(y), 0, scale or 1, scale or 1)
end

-- Draw an anchored frame with its feet (bottom-centre) at integer (x, y);
-- sx = -1 flips horizontally around the anchor. Returns the drawn origin.
function G.drawAnchored(strip, i, x, y, sx, a)
  local q = strip.quads[((i - 1) % strip.n) + 1]
  x, y = math.floor(x + 0.5), math.floor(y + 0.5)
  love.graphics.setColor(1, 1, 1, a or 1)
  local half = math.floor(strip.fw / 2)
  if sx and sx < 0 then
    love.graphics.draw(strip.img, q, x + half, y - strip.fh, 0, -1, 1)
  else
    love.graphics.draw(strip.img, q, x - half, y - strip.fh)
  end
  return x - half, y - strip.fh
end

-- Measured content anchor (bottom-centre) of a rendered frame, in frame px.
function G.frameAnchor(strip, i)
  if not strip.data then
    return nil
  end
  local x0, x1, y1 = strip.fw, -1, -1
  local base = (i - 1) * strip.fw
  for y = 0, strip.fh - 1 do
    for x = 0, strip.fw - 1 do
      local _, _, _, a = strip.data:getPixel(base + x, y)
      if a > 0.5 then
        if x < x0 then
          x0 = x
        end
        if x > x1 then
          x1 = x
        end
        if y > y1 then
          y1 = y
        end
      end
    end
  end
  if x1 < 0 then
    return nil
  end
  return (x0 + x1) / 2, y1 + 1
end

-- Fraction of pixels that differ between two frames inside a sub-rect.
function G.frameDiff(strip, i, j, x0, y0, w, h)
  local diff, total = 0, 0
  local bi, bj = (i - 1) * strip.fw, (j - 1) * strip.fw
  for y = y0, y0 + h - 1 do
    for x = x0, x0 + w - 1 do
      local r1, g1, b1, a1 = strip.data:getPixel(bi + x, y)
      local r2, g2, b2, a2 = strip.data:getPixel(bj + x, y)
      total = total + 1
      if
        math.abs(a1 - a2) > 0.5
        or (a1 > 0.5 and (math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2)) > 0.25)
      then
        diff = diff + 1
      end
    end
  end
  return diff / math.max(1, total)
end

-- LEDs: led_strip cells 0 green, 1 amber, 2 red, 3 off.
G.LED = { on = 1, connecting = 2, error = 3, off = 4 }
function G.ledStrip(size)
  return G.strip("led_strip", 4, size, size, { mode = "each" })
end

-- Card frame 9-slice ---------------------------------------------------------
-- card_frame.png: frame bbox 86..938 in 1024, 64px insets. Pre-keyed at 192
-- (0.1875): bbox 16..176, corner 12.
local nine = nil
local NINE_SRC, NINE_BBOX, NINE_CORNER = 192, 16, 12
function G.nineSlice()
  if nine then
    return nine
  end
  local img = G.sprite("card_frame", NINE_SRC, NINE_SRC)
  local ok = not G.isPlaceholder(img)
  nine = { img = img, ok = ok, c = NINE_CORNER, quads = {} }
  local b0, b1 = NINE_BBOX, NINE_SRC - NINE_BBOX
  local c = NINE_CORNER
  local xs = { b0, b0 + c, b1 - c, b1 }
  local ys = { b0, b0 + c, b1 - c, b1 }
  for row = 1, 3 do
    for col = 1, 3 do
      nine.quads[(row - 1) * 3 + col] = love.graphics.newQuad(
        xs[col],
        ys[row],
        xs[col + 1] - xs[col],
        ys[row + 1] - ys[row],
        NINE_SRC,
        NINE_SRC
      )
    end
  end
  return nine
end

-- Draw the card frame stretched to (x, y, w, h). Falls back to G.panel.
function G.frame(x, y, w, h, a, tint)
  local n = G.nineSlice()
  x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  if not n.ok or h < 24 then
    G.panel(x, y, w, h, "navy", "rust", a)
    return
  end
  local c = math.min(n.c, 8, math.floor(w / 4), math.floor(h / 4))
  local t = tint or 1
  love.graphics.setColor(t, t, t, a or 1)
  local xs = { x, x + c, x + w - c, x + w }
  local ys = { y, y + c, y + h - c, y + h }
  for row = 1, 3 do
    for col = 1, 3 do
      local q = n.quads[(row - 1) * 3 + col]
      local _, _, qw, qh = q:getViewport()
      local dw, dh = xs[col + 1] - xs[col], ys[row + 1] - ys[row]
      if dw > 0 and dh > 0 then
        love.graphics.draw(n.img, q, xs[col], ys[row], 0, dw / qw, dh / qh)
      end
    end
  end
end

-- CRT bezel ------------------------------------------------------------------
-- Source geometry (1280x720): frame 310..970 x 74..648, hole 384..895 x
-- 144..546. Drawn as edge/corner pieces around any hole rect so the plastic
-- keeps a fixed thickness (G.BEZEL insets, virtual px) whatever the window.
G.BEZEL = { l = 15, t = 14, r = 15, b = 20 }
local BZ =
  { FL = 310, HL = 384, HR = 895, FR = 970, FT = 74, HT = 144, HB = 546, FB = 648, E = 14, S = 740 }
local bezelImg = nil
function G.bezelImage()
  if bezelImg == nil then
    if G.exists("bezel") then
      bezelImg = G.sprite("bezel", 640, 360)
    else
      bezelImg = false
    end
  end
  return bezelImg or nil
end

local bq = nil
local function piece(img, sx, sy, sw, sh, dx, dy, dw, dh)
  if dw <= 0 or dh <= 0 or sw <= 0 or sh <= 0 then
    return
  end
  bq = bq or love.graphics.newQuad(0, 0, 1, 1, 640, 360)
  bq:setViewport(sx * 0.5, sy * 0.5, sw * 0.5, sh * 0.5)
  love.graphics.draw(img, bq, math.floor(dx), math.floor(dy), 0, dw / (sw * 0.5), dh / (sh * 0.5))
end

-- Hole rect (x, y, w, h) in virtual px. Draws the plastic around it.
function G.drawBezel(x, y, w, h)
  local img = G.bezelImage()
  local I = G.BEZEL
  if not img then
    -- procedural fallback: beige frame
    love.graphics.setColor(0.79, 0.75, 0.63, 1)
    love.graphics.rectangle("fill", x - I.l, y - I.t, w + I.l + I.r, I.t)
    love.graphics.rectangle("fill", x - I.l, y + h, w + I.l + I.r, I.b)
    love.graphics.rectangle("fill", x - I.l, y, I.l, h)
    love.graphics.rectangle("fill", x + w, y, I.r, h)
    return
  end
  local B = BZ
  local kx, ky = I.l / (B.HL - B.FL), I.t / (B.HT - B.FT)
  local e = B.E
  local ex, ey = e * kx, e * ky
  love.graphics.setColor(1, 1, 1, 1)
  -- corners (include the hole's black chamfers)
  piece(img, B.FL, B.FT, B.HL + e - B.FL, B.HT + e - B.FT, x - I.l, y - I.t, I.l + ex, I.t + ey)
  piece(
    img,
    B.HR - e,
    B.FT,
    B.FR - B.HR + e,
    B.HT + e - B.FT,
    x + w - ex,
    y - I.t,
    I.r + ex,
    I.t + ey
  )
  piece(
    img,
    B.FL,
    B.HB - e,
    B.HL + e - B.FL,
    B.FB - B.HB + e,
    x - I.l,
    y + h - ey,
    I.l + ex,
    I.b + ey
  )
  piece(
    img,
    B.HR - e,
    B.HB - e,
    B.FR - B.HR + e,
    B.FB - B.HB + e,
    x + w - ex,
    y + h - ey,
    I.r + ex,
    I.b + ey
  )
  -- edges
  piece(img, B.HL + e, B.FT, B.HR - B.HL - 2 * e, B.HT - B.FT, x + ex, y - I.t, w - 2 * ex, I.t)
  piece(img, B.FL, B.HT + e, B.HL - B.FL, B.HB - B.HT - 2 * e, x - I.l, y + ey, I.l, h - 2 * ey)
  piece(img, B.HR, B.HT + e, B.FR - B.HR, B.HB - B.HT - 2 * e, x + w, y + ey, I.r, h - 2 * ey)
  -- bottom edge: stretched plain part + fixed part with the power LED
  local fixedW = (B.HR - e - B.S) * kx
  piece(img, B.HL + e, B.HB, B.S - B.HL - e, B.FB - B.HB, x + ex, y + h, w - 2 * ex - fixedW, I.b)
  piece(img, B.S, B.HB, B.HR - e - B.S, B.FB - B.HB, x + w - ex - fixedW, y + h, fixedW, I.b)
end

-- Parallax -------------------------------------------------------------------
-- Three 16:9 layers scaled to the content height, looping horizontally.
-- Speeds from STYLE.md (px/frame at 60 fps -> px/s): far 3, mid 9, near 21.
G.PARALLAX = {
  { "bg_causeway_far", 3, false, 0 },
  { "bg_causeway_mid", 9, true, 3 },
  { "bg_causeway_near", 21, true, 8 },
}
local plx = {}
-- Backdrop height for a content rectangle. Landscape fills the height (the
-- 16:9 strip is wider than the view and scrolls). Portrait fits the width
-- instead: the strip sits on the floor at its natural proportion and the sky
-- gradient covers the rest, so the tram never towers over the hero.
function G.parallaxHeight(vw, vh)
  if vw and vh > vw then
    return math.min(vh, math.floor(vw * 9 / 16 + 0.5))
  end
  return vh
end

function G.parallaxLayers(vw, vh)
  if vh == nil then
    vw, vh = nil, vw -- legacy (vh) call: landscape sizing
  end
  local lh = G.parallaxHeight(vw, vh)
  local lw = math.floor(lh * 16 / 9 + 0.5)
  local key = lw .. "x" .. lh
  if plx[key] then
    return plx[key]
  end
  local layers = {}
  for i, def in ipairs(G.PARALLAX) do
    layers[i] = {
      img = G.layer(def[1], lw, lh, { chroma = def[3] }),
      speed = def[2],
      mouse = def[4],
      w = lw,
      h = lh,
    }
  end
  plx[key] = layers
  return layers
end

-- t seconds, mouseK in -1..1, dim 0..1 brightness.
function G.drawParallax(t, vw, vh, mouseK, dim, yBase)
  local layers = G.parallaxLayers(vw, vh)
  yBase = yBase or vh
  local drawn = false
  for _, L in ipairs(layers) do
    if L.img then
      drawn = true
      local off = (t * L.speed + (mouseK or 0) * L.mouse) % L.w
      love.graphics.setColor(dim, dim, dim, 1)
      for x = -off, vw, L.w do
        love.graphics.draw(L.img, math.floor(x), yBase - L.h)
      end
    end
  end
  return drawn
end

function G.color(name, a)
  local c = G.palette[name] or G.palette.white
  love.graphics.setColor(c[1], c[2], c[3], a or 1)
end

function G.rgb(name)
  local c = G.palette[name] or G.palette.white
  return c[1], c[2], c[3]
end

-- 0xRRGGBB -> r,g,b (cached tables).
local rgbCache = {}
function G.hex(v)
  local c = rgbCache[v]
  if not c then
    c = { math.floor(v / 65536) % 256 / 255, math.floor(v / 256) % 256 / 255, v % 256 / 255 }
    rgbCache[v] = c
  end
  return c[1], c[2], c[3]
end

-- Text helpers. All positions are in virtual px; caller has scaled the
-- coordinate system (love.graphics.scale(D.s)) so nothing here scales.
function G.ui(text, x, y, colName, a)
  love.graphics.setFont(G.fontUI)
  if colName then
    G.color(colName, a)
  end
  love.graphics.print(text, math.floor(x), math.floor(y))
end

function G.text(text, x, y, colName, a)
  love.graphics.setFont(G.fontTerm)
  if colName then
    G.color(colName, a)
  end
  love.graphics.print(text, math.floor(x), math.floor(y))
end

function G.uiWidth(text)
  return G.fontUI:getWidth(text)
end

function G.textWidth(text)
  return G.fontTerm:getWidth(text)
end

-- Retro panel: filled box + 1px light bevel.
function G.panel(x, y, w, h, fill, edge, a)
  x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  local f = G.palette[fill or "navy"]
  love.graphics.setColor(f[1], f[2], f[3], a or 1)
  love.graphics.rectangle("fill", x, y, w, h)
  local e = G.palette[edge or "dblue"]
  love.graphics.setColor(e[1], e[2], e[3], a or 1)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
end

-- Small blinking LED.
function G.led(x, y, colName, on, t)
  local c = G.palette[colName] or G.palette.gray
  local glow = on and (0.75 + 0.25 * math.sin((t or 0) * 4)) or 0.25
  love.graphics.setColor(c[1] * glow, c[2] * glow, c[3] * glow, 1)
  love.graphics.rectangle("fill", x, y, 4, 4)
  love.graphics.setColor(1, 1, 1, on and 0.5 or 0.1)
  love.graphics.rectangle("fill", x, y, 1, 1)
end

return G
