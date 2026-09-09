-- Draws a session's CboCell grid. Text is rendered to an offscreen canvas at
-- native cell size (8x16) only when the core's generation changes; every
-- frame we just blit it at integer scale through the CRT shader and draw the
-- breathing cursor on top (outside the shader so it stays crisp).
--
-- TV:draw works in *screen* pixels: the caller sets up a transform whose unit
-- is one screen pixel (see scenes/terminal.lua) and passes the terminal zoom
-- (1 or 2) as the scale, so an 8x16 Unifont cell is exactly 8x16 (or 16x32)
-- device pixels whatever the UI's chunky pixel scale is. No table is
-- allocated per frame here; the glyph run buffer is reused across renders.

local utf8 = require("utf8")
local ffi = require("ffi")
local G = require("src.gfx")
local fx = require("src.fx")

local TV = {}
TV.__index = TV

local CW, CH = 8, 16
local ATTR_UNDERLINE, ATTR_DIM = 4, 32
local TERM_BG = 0x101830
local NO_OPTS = {}

function TV.new(core, id)
  local tv = setmetatable({}, TV)
  tv.core = core
  tv.id = id
  tv.gen = -1
  tv.cols, tv.rows = 0, 0
  tv.canvas = nil
  tv.cells = nil
  tv.cx, tv.cy, tv.cvis = 0, 0, true
  tv.breath = 0
  tv.sel = nil
  tv.dirty = true
  tv.buf = {} -- glyph run buffer, reused by renderCells
  tv.renders = 0 -- canvas redraws so far (perf counter)
  tv.placements = {} -- visible kitty placements from the core (reused table)
  tv.images = {} -- image key -> { img = Image, w, h, seen = time }
  tv.imageFails = {} -- keys whose payload could not be decoded
  tv.cellPxSent = false
  return tv
end

-- Layout in native cell units: cols x rows cells => pixel size.
function TV:pixelSize()
  return self.cols * CW, self.rows * CH
end

local function safeChar(cp)
  if cp >= 0xD800 and cp <= 0xDFFF then
    cp = 0xFFFD
  end
  if cp > 0x10FFFF then
    cp = 0xFFFD
  end
  return utf8.char(cp)
end

-- Resolve cell colours + attrs. Returns fg r,g,b,a and bg hex.
local function resolve(cell)
  local fg, bg, attr = cell.fg, cell.bg, cell.attr
  local r, g, b = G.hex(fg)
  local a = 1
  if bit.band(attr, ATTR_DIM) ~= 0 then
    a = 0.6
  end
  return r, g, b, a, bg
end

-- Print one run of equal-style glyphs (buf[1..n]) at column runX; returns 0.
local function flushRun(buf, n, runX, y, r, g, b, a, ul)
  if n > 0 then
    love.graphics.setColor(r, g, b, a)
    love.graphics.print(table.concat(buf, "", 1, n), runX * CW, y)
    if ul then
      love.graphics.rectangle("fill", runX * CW, y + CH - 2, n * CW, 1)
    end
  end
  return 0
end

-- Kitty images ---------------------------------------------------------------

local IMAGE_TTL = 60 -- seconds an unplaced texture stays cached

-- Turn a stored payload (PNG, or raw RGB/RGBA, optionally zlib) into an
-- Image. Returns nil, err when it cannot be decoded.
function TV.decodeImage(info, bytes)
  if not info or not bytes or #bytes == 0 then
    return nil, "empty"
  end
  if info.compressed then
    local ok, res = pcall(love.data.decompress, "string", "zlib", bytes)
    if not ok then
      return nil, "zlib: " .. tostring(res)
    end
    bytes = res
  end
  local data
  if info.format == 100 then
    local ok, res = pcall(function()
      return love.image.newImageData(love.filesystem.newFileData(bytes, "kitty.png"))
    end)
    if not ok then
      return nil, "png: " .. tostring(res)
    end
    data = res
  else
    local w, h = info.width, info.height
    local bpp = info.format == 24 and 3 or 4
    if w <= 0 or h <= 0 or #bytes < w * h * bpp then
      return nil, "short raw payload"
    end
    data = love.image.newImageData(w, h)
    local dst = ffi.cast("uint8_t*", data:getFFIPointer())
    if bpp == 4 then
      ffi.copy(dst, bytes, w * h * 4)
    else
      local src = ffi.cast("const uint8_t*", bytes)
      for i = 0, w * h - 1 do
        dst[i * 4] = src[i * 3]
        dst[i * 4 + 1] = src[i * 3 + 1]
        dst[i * 4 + 2] = src[i * 3 + 2]
        dst[i * 4 + 3] = 255
      end
    end
  end
  local img = love.graphics.newImage(data)
  img:setFilter("nearest", "nearest")
  return img, nil, data:getWidth(), data:getHeight()
end

-- Make sure every placement has a texture; forget stale ones.
function TV:syncImages(now)
  local core = self.core
  for _, p in ipairs(self.placements) do
    local entry = self.images[p.key]
    if entry then
      entry.seen = now
    elseif core and not self.imageFails[p.key] then
      local info = core.imageInfo(self.id, p.key)
      local img, err, w, h =
        TV.decodeImage(info, info and core.imageData(self.id, p.key, info.bytes))
      if img then
        self.images[p.key] = { img = img, w = w, h = h, seen = now }
      else
        self.imageFails[p.key] = err or "?"
        print(("[term] image %d: %s"):format(p.key, tostring(err)))
      end
    end
  end
  for key, entry in pairs(self.images) do
    if now - entry.seen > IMAGE_TTL then
      entry.img:release()
      self.images[key] = nil
    end
  end
end

-- Draw placements with z in [zmin, zmax] into the current canvas (cell units).
function TV:drawImages(zmin, zmax)
  for _, p in ipairs(self.placements) do
    local entry = self.images[p.key]
    if entry and p.z >= zmin and p.z <= zmax then
      local sw = (p.sw > 0) and p.sw or entry.w
      local sh = (p.sh > 0) and p.sh or entry.h
      if sw > 0 and sh > 0 then
        local quad = love.graphics.newQuad(p.sx, p.sy, sw, sh, entry.w, entry.h)
        local dw, dh = p.cols * CW, p.rows * CH
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(entry.img, quad, p.col * CW, p.row * CH, 0, dw / sw, dh / sh)
      end
    end
  end
end

function TV:imageCount()
  local n = 0
  for _ in pairs(self.images) do
    n = n + 1
  end
  return n
end

-- Public: render the grid into the canvas from a cells array (also used by
-- tests with a hand-built snapshot).
function TV:renderCells(cells, cols, rows)
  self.cells, self.cols, self.rows = cells, cols, rows
  local pw, ph = cols * CW, rows * CH
  if not self.canvas or self.canvas:getWidth() ~= pw or self.canvas:getHeight() ~= ph then
    self.canvas = love.graphics.newCanvas(pw, ph)
    self.canvas:setFilter("nearest", "nearest")
  end
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setScissor()
  love.graphics.setCanvas(self.canvas)
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")
  local tr, tg, tb = G.hex(TERM_BG)
  love.graphics.clear(tr, tg, tb, 1)
  love.graphics.setFont(G.fontTerm)

  -- pass 1: backgrounds (merged runs of equal bg)
  for row = 0, rows - 1 do
    local base = row * cols
    local runStart, runBg = 0, nil
    for col = 0, cols do
      local bg
      if col < cols then
        local cell = cells[base + col]
        bg = cell.bg -- Rust has already applied inverse and bold colours
      end
      if bg ~= runBg then
        if runBg and runBg ~= TERM_BG then
          local r, g, b = G.hex(runBg)
          love.graphics.setColor(r, g, b, 1)
          love.graphics.rectangle("fill", runStart * CW, row * CH, (col - runStart) * CW, CH)
        end
        runStart, runBg = col, bg
      end
    end
  end

  -- pass 1b: images under the text (kitty z < 0)
  if #self.placements > 0 then
    self:drawImages(-math.huge, -1)
  end

  -- pass 2: glyphs, printed in runs of equal style; wide glyphs alone
  local buf = self.buf
  for row = 0, rows - 1 do
    local base = row * cols
    local y = row * CH
    local n = 0
    local runX, rr, rg, rb, ra, rul = 0, 0, 0, 0, 1, false
    local col = 0
    while col < cols do
      local cell = cells[base + col]
      local w = cell.width
      local cp = cell.cp
      if w == 0 then
        n = flushRun(buf, n, runX, y, rr, rg, rb, ra, rul)
        col = col + 1
      elseif cp == 0 or cp == 32 then
        -- blank: extend run with a space only if a run is open (keeps runs
        -- short and avoids printing whole rows of spaces)
        if n > 0 then
          n = n + 1
          buf[n] = " "
        end
        col = col + 1
      else
        local r, g, b, a = resolve(cell)
        local ul = bit.band(cell.attr, ATTR_UNDERLINE) ~= 0
        if w == 2 then
          n = flushRun(buf, n, runX, y, rr, rg, rb, ra, rul)
          love.graphics.setColor(r, g, b, a)
          love.graphics.print(safeChar(cp), col * CW, y)
          if ul then
            love.graphics.rectangle("fill", col * CW, y + CH - 2, 2 * CW, 1)
          end
          col = col + 2
        else
          if n > 0 and (r ~= rr or g ~= rg or b ~= rb or a ~= ra or ul ~= rul) then
            n = flushRun(buf, n, runX, y, rr, rg, rb, ra, rul)
          end
          if n == 0 then
            runX, rr, rg, rb, ra, rul = col, r, g, b, a, ul
          end
          n = n + 1
          buf[n] = safeChar(cp)
          col = col + 1
        end
      end
    end
    -- trim trailing spaces from the run
    while n > 0 and buf[n] == " " do
      n = n - 1
    end
    flushRun(buf, n, runX, y, rr, rg, rb, ra, rul)
  end

  -- pass 3: images over the text (kitty z >= 0, the default)
  if #self.placements > 0 then
    self:drawImages(0, math.huge)
  end
  love.graphics.pop()
  self.renders = self.renders + 1
  self.dirty = false
end

-- Poll the core; re-render when the screen generation changed.
function TV:update(dt)
  self.breath = self.breath + dt
  local core = self.core
  if not core or self.id == nil then
    return
  end
  if not self.cellPxSent and core.setCellPx then
    core.setCellPx(self.id, CW, CH)
    self.cellPxSent = true
  end
  local gen = core.generation(self.id)
  local info
  if gen ~= self.gen or self.dirty then
    info = core.info(self.id)
    if info and info.cols > 0 and info.rows > 0 then
      local cells, cols, rows, n = core.snapshot(self.id, info.cols, info.rows)
      if cells and n > 0 then
        if core.placements then
          core.placements(self.id, self.placements)
          self:syncImages(love.timer.getTime())
        end
        self:renderCells(cells, cols, rows)
        self.gen = gen
      end
    end
  end
  self.cx, self.cy, self.cvis = core.cursor(self.id)
end

function TV:pollBell()
  if not self.core or self.id == nil then
    return 0
  end
  return self.core.takeBell(self.id)
end

-- Cell text (for selection copy).
function TV:rowText(row, c0, c1)
  if not self.cells then
    return ""
  end
  local out = {}
  for col = c0, c1 do
    local cell = self.cells[row * self.cols + col]
    if cell.width ~= 0 then
      out[#out + 1] = cell.cp == 0 and " " or safeChar(cell.cp)
    end
  end
  return (table.concat(out):gsub("%s+$", ""))
end

function TV:selectedText()
  local s = self.sel
  if not s or not self.cells then
    return nil
  end
  local y0, y1 = math.min(s.y0, s.y1), math.max(s.y0, s.y1)
  local lines = {}
  for row = y0, y1 do
    local c0, c1 = 0, self.cols - 1
    if row == y0 then
      c0 = (s.y0 <= s.y1) and s.x0 or s.x1
    end
    if row == y1 then
      c1 = (s.y0 <= s.y1) and s.x1 or s.x0
    end
    if y0 == y1 then
      c0, c1 = math.min(s.x0, s.x1), math.max(s.x0, s.x1)
    end
    lines[#lines + 1] = self:rowText(row, math.max(0, c0), math.min(self.cols - 1, c1))
  end
  return table.concat(lines, "\n")
end

-- Draw at (x, y) in the current coordinate system (screen px) with integer
-- scale = terminal zoom. opts: crt, barrel, scanline, vignette, alpha,
-- showCursor. The scrollback badge is UI chrome and is drawn by the scene.
function TV:draw(x, y, scale, opts)
  opts = opts or NO_OPTS
  if not self.canvas then
    return
  end
  fx.drawCRT(self.canvas, x, y, scale, opts)

  love.graphics.push()
  love.graphics.translate(x, y)
  love.graphics.scale(scale, scale)

  -- selection highlight
  if self.sel then
    local s = self.sel
    local y0, y1 = math.min(s.y0, s.y1), math.max(s.y0, s.y1)
    love.graphics.setColor(0.4, 0.86, 0.94, 0.28)
    for row = y0, y1 do
      local c0, c1 = 0, self.cols - 1
      if y0 == y1 then
        c0, c1 = math.min(s.x0, s.x1), math.max(s.x0, s.x1)
      elseif row == y0 then
        c0 = (s.y0 <= s.y1) and s.x0 or s.x1
      elseif row == y1 then
        c1 = (s.y0 <= s.y1) and s.x1 or s.x0
      end
      love.graphics.rectangle("fill", c0 * CW, row * CH, (c1 - c0 + 1) * CW, CH)
    end
  end

  -- breathing rust cursor
  if opts.showCursor ~= false and self.cvis and self.cx < self.cols and self.cy < self.rows then
    local a = 0.55 + 0.35 * math.sin(self.breath * 3.2)
    local r, g, b = G.rgb("rust")
    local cell = self.cells and self.cells[self.cy * self.cols + self.cx]
    local w = (cell and cell.width == 2) and 2 or 1
    love.graphics.setColor(r, g, b, a)
    love.graphics.rectangle("fill", self.cx * CW, self.cy * CH, w * CW, CH)
    if cell and cell.cp ~= 0 and cell.cp ~= 32 then
      love.graphics.setFont(G.fontTerm)
      love.graphics.setColor(0.05, 0.05, 0.08, a + 0.2)
      love.graphics.print(safeChar(cell.cp), self.cx * CW, self.cy * CH)
    end
  end
  love.graphics.pop()
end

-- Screen px (relative to the draw origin) -> cell coords (clamped).
function TV:cellAt(px, py, scale)
  local cx = math.floor(px / (CW * scale))
  local cy = math.floor(py / (CH * scale))
  return fx.clamp(cx, 0, math.max(0, self.cols - 1)), fx.clamp(cy, 0, math.max(0, self.rows - 1))
end

TV.CW, TV.CH = CW, CH
return TV
