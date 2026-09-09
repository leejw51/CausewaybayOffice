-- Window + integer pixel scale. The whole UI is drawn in "pixel units" of the
-- 8x16 terminal cell: D.s is the integer screen scale (2 on a 1280x800
-- window), so an 8px font drawn at scale D.s stays perfectly crisp.

local D = {}

D.CELL_W, D.CELL_H = 8, 16
D.s = 2 -- integer pixel scale
D.userScale = 1 -- config.fontScale multiplier (1 = auto)
D.w, D.h = 1280, 800 -- window size in pixels
D.vw, D.vh = 640, 400 -- window size in virtual (unscaled) pixels
D.fullscreen = false
D.dirty = true
D.fw, D.fh = 640, 400 -- full window in virtual px
D.ox, D.oy = 0, 0 -- content offset (bezel plastic) in virtual px
D.toolbarH = 24 -- persistent display controls, outside scene/overlay content
D.inset = nil -- {l,t,r,b} when the bezel is on
D.termZoom = 1 -- terminal glyph scale in screen px (1 = native 8x16 Unifont, 2 = doubled)
D.orientationMode = "auto" -- auto | landscape | portrait (Settings / Ctrl+O)
D.overrideFor = nil -- natural shape ("landscape"/"portrait") a forced mode was chosen for
D.portrait = false -- effective orientation for the current window

-- The shape the window has on its own, before any override.
function D.natural(vw, vh)
  return (vh or D.vh) > (vw or D.vw) and "portrait" or "landscape"
end

-- Nearest integer scale that keeps the virtual canvas around 640x400 (long
-- side x short side, whichever way the window stands), but never smaller
-- than 480x300 (the UI needs that much room). A tall window therefore gets
-- the same chunky pixels as a wide one instead of dropping to 1x.
local function computeScale(w, h)
  local long, short = math.max(w, h), math.min(w, h)
  local base = math.max(1, math.floor(math.min(long / 640, short / 400) + 0.5))
  local s = math.max(1, math.floor(base * D.userScale + 0.5))
  while s > 1 and (long / s < 480 or short / s < 300) do
    s = s - 1
  end
  return math.min(s, 6)
end

function D.init(cfg)
  love.graphics.setDefaultFilter("nearest", "nearest")
  love.graphics.setLineStyle("rough")
  D.userScale = (cfg and cfg.fontScale) or 1
  D.termZoom = D.clampZoom(cfg and cfg.termZoom)
  D.orientationMode = (cfg and cfg.orientation) or "auto"
  D.overrideFor = cfg and cfg.orientationFor or nil
  if D.overrideFor ~= "portrait" and D.overrideFor ~= "landscape" then
    -- a forced mode without the shape it was made for cannot be trusted
    D.overrideFor = nil
    D.orientationMode = "auto"
  end
  D.fullscreen = love.window.getFullscreen()
  D.resize(love.graphics.getDimensions())
end

function D.setUserScale(m)
  D.userScale = math.max(0.5, math.min(3, m or 1))
  D.resize(love.graphics.getDimensions())
end

function D.resize(w, h)
  w, h = math.max(1, math.floor(w or 1)), math.max(1, math.floor(h or 1))
  D.w, D.h = w, h
  D.s = computeScale(w, h)
  D.fw, D.fh = math.floor(w / D.s), math.floor(h / D.s)
  local I = D.inset or { l = 0, t = 0, r = 0, b = 0 }
  D.ox, D.oy = I.l, I.t + D.toolbarH
  D.vw, D.vh = D.fw - I.l - I.r, D.fh - I.t - I.b - D.toolbarH
  if D.orientationMode ~= "auto" and D.overrideFor ~= D.natural(D.vw, D.vh) then
    -- the window changed shape: the override was for the old one
    D.orientationMode, D.overrideFor = "auto", nil
  end
  D.portrait = D.isPortrait(D.vw, D.vh, D.orientationMode)
  D.dirty = true
end

-- Effective orientation: "auto" follows the content aspect.
function D.isPortrait(vw, vh, mode)
  mode = mode or D.orientationMode
  if mode == "portrait" then
    return true
  elseif mode == "landscape" then
    return false
  end
  return vh > vw
end

D.ORIENTATIONS = { "auto", "landscape", "portrait" }
function D.setOrientation(mode)
  D.orientationMode = mode or "auto"
  D.overrideFor = D.orientationMode ~= "auto" and D.natural(D.vw, D.vh) or nil
  D.resize(love.graphics.getDimensions())
  return D.orientationMode
end

function D.nextOrientation()
  for i, m in ipairs(D.ORIENTATIONS) do
    if m == D.orientationMode then
      return D.ORIENTATIONS[(i % #D.ORIENTATIONS) + 1]
    end
  end
  return "auto"
end

-- Window / fullscreen (desktop). Returns the resulting state.
function D.setFullscreen(on)
  D.fullscreen = on and true or false
  love.window.setFullscreen(D.fullscreen, "desktop")
  D.fullscreen = love.window.getFullscreen()
  D.resize(love.graphics.getDimensions())
  return D.fullscreen
end

-- Returns true when the window size changed (callers must re-layout).
function D.sync()
  local w, h = love.graphics.getDimensions()
  if w ~= D.w or h ~= D.h then
    D.resize(w, h)
    return true
  end
  return false
end

function D.clampZoom(z)
  z = tonumber(z) or 1
  if z >= 2 then
    return 2
  end
  return 1
end

-- Terminal zoom (1x / 2x). The grid changes, so callers re-layout.
function D.setTermZoom(z)
  D.termZoom = D.clampZoom(z)
  D.dirty = true
  return D.termZoom
end

-- Terminal cells that fit into a virtual-px rectangle: the terminal is drawn
-- in screen pixels at D.termZoom (not at the UI scale D.s), so the UI chrome
-- keeps its chunky pixels while the grid stays at office density.
function D.termGrid(vwpx, vhpx, zoom)
  zoom = zoom or D.termZoom
  local cols = math.max(2, math.floor(vwpx * D.s / (D.CELL_W * zoom)))
  local rows = math.max(1, math.floor(vhpx * D.s / (D.CELL_H * zoom)))
  return cols, rows
end

-- Bezel on/off changes the content rectangle (scenes read D.vw/D.vh).
function D.setInset(inset)
  D.inset = inset
  D.resize(love.graphics.getDimensions())
end

function D.toggleFullscreen()
  return D.setFullscreen(not D.fullscreen)
end

-- How many terminal cells fit into a pixel rectangle (w x h in screen px).
function D.gridFor(wpx, hpx, scale)
  scale = scale or D.s
  local cols = math.max(2, math.floor(wpx / (D.CELL_W * scale)))
  local rows = math.max(1, math.floor(hpx / (D.CELL_H * scale)))
  return cols, rows
end

-- Screen px -> content virtual px.
function D.toVirtual(x, y)
  return x / D.s - D.ox, y / D.s - D.oy
end

return D
