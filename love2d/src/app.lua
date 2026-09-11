-- Scene stack + global services. One base scene (boot / lobby / terminal)
-- and a stack of overlays (connect / search / rename / settings / help).
-- Every scene switch goes through fx.transition (exponential fade).

local D = require("src.display")
local G = require("src.gfx")
local fx = require("src.fx")
local Core = require("src.core")
local Config = require("src.config")
local Sessions = require("src.sessions")
local Audio = require("src.audio")
local TermView = require("src.term_view")

local App = {}

App.D, App.G, App.fx = D, G, fx
App.core = Core
App.cfg = Config
App.sessions = Sessions
App.audio = Audio
App.scene = nil
App.sceneName = nil
App.overlays = {}
App.views = {}
App.time = 0
App.fps = 0
App.showFps = false

function App.init(opts)
  opts = opts or {}
  Core.load({ forceMock = opts.forceMock })
  Config.load()
  D.init(Config.get())
  G.init()
  App.setBezel(Config.get().bezel ~= false, true)
  fx.initCRT()
  Audio.init()
  Audio.enabled = Config.get().sound ~= false
  Audio.clicks = Config.get().keyClicks == true
  Sessions.init(
    Core,
    { allowFixtures = opts.allowFixtures, restoreSessions = opts.restoreSessions }
  )
  love.keyboard.setKeyRepeat(true)
  love.keyboard.setTextInput(true)
  if Config.get().display == "fullscreen" and not opts.forceMock then
    D.setFullscreen(true)
    App.resize(D.w, D.h)
  end
  if opts.restoreSessions then
    Sessions.restore(App.termGrid())
  end
  App.mcpPending = {}
  App.mcpAutoStart()
end

-- AUTO START (AGI > MCP): bring the server up with the app when the user
-- asked for it. Never under the mock core, which has no socket. Returns
-- true when a server was actually started.
function App.mcpAutoStart()
  if not Config.get().mcpAuto or Core.mock then
    return false
  end
  local ok, err = Core.mcpStart(Config.get().mcpPort or 0)
  if not ok then
    print("[mcp] could not start: " .. tostring(err))
  end
  return ok == true
end

-- MCP server on / off (AGI > MCP page). Returns ok, err.
function App.setMcp(on)
  if on then
    local ok, err = Core.mcpStart(Config.get().mcpPort or 0)
    if ok then
      Core.mcpSetSession(App.sceneName == "terminal" and App.scene.id or -1)
    end
    return ok, err
  end
  Core.mcpStop()
  return true
end

-- An inbox item from an MCP client goes to the terminal on screen; other
-- scenes keep it until a terminal opens.
function App.deliverMcp(item)
  if App.sceneName == "terminal" and App.scene and App.scene.deliverMcp then
    App.scene:deliverMcp(item)
    return true
  end
  App.mcpPending[#App.mcpPending + 1] = item
  App.toast("MCP: " .. (item.kind or "message") .. " waiting for a terminal")
  return false
end

-- Fullscreen / window with an expo fade; every scene reflows through
-- App.resize and the bezel follows the new size. Persisted in config.json.
function App.setFullscreen(on, instant)
  local function apply()
    D.setFullscreen(on)
    Config.get().display = D.fullscreen and "fullscreen" or "window"
    Config.save()
    App.saveDisplay()
    App.resize(D.w, D.h)
  end
  if instant or App.scene == nil or fx.transitioning or App.iris then
    apply()
    return
  end
  fx.transition(apply, 0.22, 0.5)
end

function App.saveDisplay()
  if
    not Core.mock and not Core.saveDisplay(D.fullscreen, D.portrait and "portrait" or "landscape")
  then
    App.toast("Could not save display.jsonl: " .. Core.lastError())
  end
end

function App.toggleFullscreen()
  App.setFullscreen(not D.fullscreen)
end

-- Orientation: auto / landscape / portrait (Settings or Ctrl+O).
function App.setOrientation(mode)
  D.setOrientation(mode)
  App.syncOrientation()
  App.saveDisplay()
  App.resize(D.w, D.h)
  local eff = D.portrait and "portrait" or "landscape"
  App.toast(
    "orientation: "
      .. D.orientationMode
      .. (D.orientationMode == "auto" and (" (" .. eff .. ")") or "")
  )
end

function App.cycleOrientation()
  App.setOrientation(D.nextOrientation())
end

-- Persist what the display decided (a forced mode is dropped when the window
-- changes shape, so config follows D rather than the other way round).
function App.syncOrientation()
  local cfg = Config.get()
  if cfg.orientation ~= D.orientationMode or cfg.orientationFor ~= (D.overrideFor or "") then
    cfg.orientation, cfg.orientationFor = D.orientationMode, D.overrideFor or ""
    Config.save()
  end
end

-- The toolbar button flips the effective orientation. When the flip lands
-- on the window's own shape, that is "auto" (no stale override to carry).
function App.flipOrientation()
  local want = D.portrait and "landscape" or "portrait"
  App.setOrientation(want == D.natural() and "auto" or want)
end

-- Small transient message drawn over everything.
App.toastV = { a = 0, text = "" }
function App.toast(text, dur)
  App.toastV.text = text
  App.toastV.a = 1
  fx.tween(App.toastV, { a = 0 }, dur or 2.2, "expoIn")
end

-- Bezel on/off: the content rectangle shrinks to the screen hole.
function App.setBezel(on, silent)
  App.bezel = on
  D.setInset(on and G.BEZEL or nil)
  if not silent and App.scene and App.scene.resize then
    App.scene:resize()
  end
end

-- Grid a new session should open with (what the terminal scene will use).
function App.termGrid()
  return require("src.scenes.terminal").grid(D, false)
end

-- Terminal view per session id (created lazily, dropped with the session).
function App.view(id)
  local v = App.views[id]
  if not v then
    v = TermView.new(Core, id)
    App.views[id] = v
  end
  return v
end

function App.dropView(id)
  App.views[id] = nil
end

local function loadScene(name, params)
  local mod = require("src.scenes." .. name)
  local inst = mod.new(App, params or {})
  inst.name = name
  return inst
end

function App.lobbyView()
  local view = Config.get().lobbyView
  return (view == "map" or view == "map3") and view or "map2"
end

local function rememberLobby(name)
  if (name == "map" or name == "map2" or name == "map3") and Config.get().lobbyView ~= name then
    Config.get().lobbyView = name
    Config.save()
  end
end

-- Switch base scene with a fade. Returns false if a transition is running.
function App.switch(name, params)
  if App.iris or fx.transitioning then
    return false
  end
  if name == "lobby" then
    name = App.lobbyView()
  end
  if name == App.sceneName and (name == "map" or name == "map2" or name == "map3") then
    return true
  end
  require("src.ui").flush()
  if App.scene == nil then
    App.scene = loadScene(name, params)
    App.sceneName = name
    rememberLobby(name)
    if App.scene.enter then
      App.scene:enter()
    end
    fx.fade.a = 1
    fx.fadeIn(0.6)
    return true
  end
  local outgoing = (App.sceneName == "map" or App.sceneName == "map2" or App.sceneName == "map3")
    and name == "terminal"
  local incoming = App.sceneName == "terminal"
    and (name == "map" or name == "map2" or name == "map3")
  if incoming then
    params = params or {}
    params.select = App.scene.id
  end
  local focus = outgoing and App.scene.selectionFocus and App.scene:selectionFocus()
  local accepted = fx.transition(function()
    fx.cancel(App.cameraTween)
    App.camera = nil
    if App.scene and App.scene.leave then
      App.scene:leave()
    end
    App.overlays = {}
    App.scene = loadScene(name, params)
    App.sceneName = name
    rememberLobby(name)
    if App.scene.enter then
      App.scene:enter()
    end
    if outgoing or incoming then
      local p = incoming and App.scene.selectionFocus and App.scene:selectionFocus()
      App.camera =
        { zoom = incoming and 1.8 or 1.12, pull = 1, x = p and p.x or 0.5, y = p and p.y or 0.5 }
      App.cameraTween = fx.tween(App.camera, { zoom = 1, pull = 0 }, 0.65, "expoOut")
    end
  end, (outgoing or incoming) and 0.55 or nil, (outgoing or incoming) and 0.65 or nil)
  if accepted and outgoing then
    App.camera = { zoom = 1, pull = 0, x = focus and focus.x or 0.5, y = focus and focus.y or 0.5 }
    App.cameraTween = fx.tween(App.camera, { zoom = 2.8, pull = 1 }, 0.55, "expoInOut")
  end
  return accepted
end

-- Explicit user disconnect: close through a pixel-stepped arcade iris, then
-- reveal the remaining sessions. Capture record identity, never a reusable ID.
function App.disconnectSession(rec, focus)
  if not rec or Sessions.get(rec.id) ~= rec or App.iris or fx.transitioning then
    return false
  end
  App.iris = { t = 0, rec = rec, x = focus and focus.x or 0.5, y = focus and focus.y or 0.5 }
  rec.closing = true
  Sessions.saveRestore() -- persist intent even if the app quits during the iris
  Audio.play("close")
  return true
end

function App.updateIris(dt)
  local iris = App.iris
  if not iris then
    return
  end
  iris.t = iris.t + dt
  if iris.t >= 0.42 and not iris.closed then
    iris.closed = true
    if Sessions.get(iris.rec.id) == iris.rec then
      Sessions.close(iris.rec.id)
    end
    if App.sceneName == "terminal" then
      if App.scene.leave then
        App.scene:leave()
      end
      App.overlays = {}
      local name = App.lobbyView()
      App.scene, App.sceneName = loadScene(name), name
      if App.scene.enter then
        App.scene:enter()
      end
    elseif App.scene.refresh then
      App.scene:refresh()
    end
  end
  if iris.t >= 1 then
    App.iris = nil
  end
end

function App.drawIris()
  local iris = App.iris
  if not iris then
    return
  end
  local cx, cy = iris.x * D.vw, iris.y * D.vh
  local farX, farY = math.max(cx, D.vw - cx), math.max(cy, D.vh - cy)
  local radius = math.sqrt(farX * farX + farY * farY) + 2
  -- Constant radial speed, quantized to whole virtual pixels like the classic
  -- aperture. Time, rather than frame count, keeps 60/120 Hz equally fast.
  local k = iris.t < 0.42 and (1 - iris.t / 0.42) or math.min(1, (iris.t - 0.42) / 0.58)
  local r = math.floor(radius * k)
  love.graphics.setColor(0, 0, 0, 1)
  for y = 0, D.vh, 1 do
    local dy = math.max(math.abs(y - cy), math.abs(y + 1 - cy))
    local half = dy < r and math.sqrt(r * r - dy * dy) or 0
    half = math.floor(half)
    love.graphics.rectangle("fill", 0, y, math.max(0, cx - half), 1)
    love.graphics.rectangle("fill", cx + half, y, math.max(0, D.vw - cx - half), 1)
  end
end

-- Overlays slide/fade in on top of the current scene.
function App.push(name, params)
  local ov = loadScene(name, params)
  ov.alpha = 0
  ov.slide = 24
  ov.closing = false
  fx.tween(ov, { alpha = 1, slide = 0 }, 0.28, "expoOut")
  App.overlays[#App.overlays + 1] = ov
  if ov.enter then
    ov:enter()
  end
  Audio.play("open")
  return ov
end

function App.pop(ov)
  ov = ov or App.overlays[#App.overlays]
  if not ov or ov.closing then
    return
  end
  require("src.ui").flush()
  ov.closing = true
  if ov.leave then
    ov:leave()
  end
  fx.tween(ov, { alpha = 0, slide = -12 }, 0.2, "expoIn", function()
    for i, o in ipairs(App.overlays) do
      if o == ov then
        table.remove(App.overlays, i)
        break
      end
    end
  end)
  Audio.play("close")
end

function App.hasOverlay(name)
  for _, o in ipairs(App.overlays) do
    if o.name == name and not o.closing then
      return true
    end
  end
  return false
end

-- Who gets input: top-most non-closing overlay, else the scene.
function App.top()
  for i = #App.overlays, 1, -1 do
    if not App.overlays[i].closing then
      return App.overlays[i]
    end
  end
  return App.scene
end

function App.update(dt)
  dt = math.min(dt, 0.1)
  App.time = App.time + dt
  App.fps = love.timer.getFPS()
  if D.sync() then
    -- love.window.setMode / OS-driven size changes do not always raise
    -- love.resize: re-layout so the session grid follows the window
    App.resize(D.w, D.h)
  end
  require("src.ui").update(dt)
  Core.update(dt)
  Sessions.update(dt)
  App.updateIris(dt)
  App.mcpPollAge = (App.mcpPollAge or 0) + dt
  if App.mcpPollAge >= 0.25 then
    App.mcpPollAge = 0
    for _, item in ipairs(Core.mcpTake()) do
      App.deliverMcp(item)
    end
  end
  App.filePollAge = (App.filePollAge or 0) + dt
  if App.filePollAge >= 0.2 then
    App.filePollAge = 0
    for _, rec in ipairs(Sessions.list) do
      if rec.quickTransfer and not App.hasOverlay("transfer") then
        local st = Core.filesStatus(rec.id)
        rec.quickTransfer.status = st
        if st.state == "done" or st.state == "error" or st.state == "cancelled" then
          App.toast(
            st.state == "done" and ("Transferred " .. (rec.quickTransfer.name or "file"))
              or (st.error or st.state)
          )
          rec.quickTransfer.finishedAt = App.time
          rec.quickTransfer.done = st.state == "done"
          rec.quickTransfer.error = st.state ~= "done" and (st.error or st.state) or nil
          rec.lastTransfer = rec.quickTransfer
          rec.quickTransfer = nil
        end
      end
    end
  end
  -- drop views of sessions that vanished
  for id in pairs(App.views) do
    if not Sessions.byId[id] then
      App.views[id] = nil
    end
  end
  if App.scene and App.scene.update then
    App.scene:update(dt)
  end
  for _, ov in ipairs(App.overlays) do
    if ov.update then
      ov:update(dt)
    end
  end
  fx.update(dt)
end

-- RETRO: the cool-retro-term stages and the cursor trail together. Persisted
-- with the rest of the config (cfg.retro), like PRIVACY (cfg.maskIds).
function App.toggleRetro()
  local cfg = Config.get()
  cfg.retro = cfg.retro == false
  Config.save()
  fx.flash(0.15, 1, 1, 1, 0.15)
end

function App.togglePrivacy()
  local cfg = Config.get()
  cfg.maskIds = not cfg.maskIds
  Config.save()
  fx.flash(0.15, 1, 1, 1, 0.15)
end

-- Shared chrome is outside the scene rectangle, including modal overlays.
function App.displayButtons()
  local buttons = {}
  local x = 6
  local specs = {
    {
      D.fullscreen and "FULLSCREEN" or "WINDOW",
      true,
      function()
        App.toggleFullscreen()
      end,
    },
    {
      D.portrait and "VERTICAL" or "HORIZONTAL",
      true,
      function()
        App.flipOrientation()
      end,
    },
    -- PRIVACY is application-wide: every scene masks user names, addresses
    -- and ports through Config.who / nodeName / hidePath while it is lit.
    {
      "PRIVACY",
      Config.get().maskIds == true,
      function()
        App.togglePrivacy()
      end,
    },
  }
  -- RETRO belongs to the terminal page only
  if App.sceneName == "terminal" then
    specs[#specs + 1] = {
      "RETRO",
      Config.get().retro ~= false,
      function()
        App.toggleRetro()
      end,
    }
  end
  for _, spec in ipairs(specs) do
    local w = G.uiWidth(spec[1]) + 14
    buttons[#buttons + 1] =
      { x = x, y = 3, w = w, h = 18, label = spec[1], active = spec[2], fn = spec[3] }
    x = x + w + 4
  end
  return buttons
end

function App.drawDisplayControls()
  G.panel(0, 0, D.fw, D.toolbarH, "ink", "dblue")
  for _, b in ipairs(App.displayButtons()) do
    G.panel(b.x, b.y, b.w, b.h, b.active and "dblue" or "ink", b.active and "cyan" or "gray")
    G.ui(b.label, b.x + 7, b.y + 5, b.active and "white" or "gray")
  end
end

function App.draw()
  local s = D.s
  love.graphics.push()
  love.graphics.scale(s, s)
  love.graphics.setColor(0.055, 0.063, 0.19, 1) -- night_navy behind everything
  love.graphics.rectangle("fill", 0, 0, D.fw, D.fh)
  -- content (inside the bezel hole), scissored so nothing leaks under the plastic
  love.graphics.setScissor(D.ox * s, D.oy * s, D.vw * s, D.vh * s)
  love.graphics.push()
  love.graphics.translate(D.ox + fx.shakeX, D.oy + fx.shakeY)
  if App.scene and App.scene.draw then
    love.graphics.push()
    if App.camera then
      local c = App.camera
      love.graphics.translate(fx.lerp(c.x, 0.5, c.pull) * D.vw, fx.lerp(c.y, 0.5, c.pull) * D.vh)
      love.graphics.scale(c.zoom, c.zoom)
      love.graphics.translate(-c.x * D.vw, -c.y * D.vh)
    end
    App.scene:draw()
    love.graphics.pop()
  end
  for _, ov in ipairs(App.overlays) do
    if ov.draw then
      App.drawOverlay(ov, s)
    end
  end
  fx.drawParticles()
  App.drawIris()
  love.graphics.pop()
  love.graphics.setScissor()
  if App.bezel then
    G.drawBezel(D.ox, D.oy, D.vw, D.vh)
  end
  fx.drawFlash(D.fw, D.fh)
  fx.drawFade(D.fw, D.fh)

  if App.showFps then
    G.ui(string.format("%d fps", App.fps), D.ox + 4, D.oy + D.vh - 10, "gray")
  end
  if App.toastV.a > 0.01 then
    local label = require("src.ui").fit(App.toastV.text, D.vw - 40)
    local w = G.uiWidth(label) + 24
    local tx = D.ox + math.floor((D.vw - w) / 2)
    local ty = D.oy + D.vh - 48
    G.frame(tx, ty, w, 22, App.toastV.a)
    G.ui(label, tx + 12, ty + 7, "yellow", App.toastV.a)
  end
  App.drawDisplayControls()
  if Core.mock then
    local label = "MOCK CORE"
    local w = G.uiWidth(label) + 8
    G.panel(D.fw - w - 4, 5, w, 12, "dred", "lred", 0.9)
    G.ui(label, D.fw - w, 7, "white")
  end
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1, 1)
end

-- An overlay sliding in/out is drawn into a window-sized canvas and blitted
-- with its alpha, so the whole thing fades as one piece instead of the
-- frame fading while its rows pop in ("nothing cuts").
local overlayCanvas = nil
function App.drawOverlay(ov, s)
  local a = ov.alpha or 1
  local dy = math.floor(ov.slide or 0)
  if a >= 0.995 then
    love.graphics.push()
    love.graphics.translate(0, dy)
    ov:draw()
    love.graphics.pop()
    return
  end
  local w, h = love.graphics.getDimensions()
  if not overlayCanvas or overlayCanvas:getWidth() ~= w or overlayCanvas:getHeight() ~= h then
    overlayCanvas = love.graphics.newCanvas(w, h)
    overlayCanvas:setFilter("nearest", "nearest")
  end
  love.graphics.push("all")
  love.graphics.setCanvas(overlayCanvas)
  love.graphics.clear(0, 0, 0, 0)
  -- same transform as the caller: scale, content offset (+shake), slide
  love.graphics.origin()
  love.graphics.scale(s, s)
  love.graphics.translate(D.ox + fx.shakeX, D.oy + fx.shakeY + dy)
  ov:draw()
  love.graphics.pop()
  love.graphics.push()
  love.graphics.origin()
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.setColor(a, a, a, a)
  love.graphics.draw(overlayCanvas, 0, 0)
  love.graphics.setBlendMode("alpha")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.pop()
end

-- Input routing --------------------------------------------------------------

local Keys = require("src.keys")

function App.keypressed(key, sc, isRepeat)
  local m = Keys.mods()
  if key == "f11" then
    App.toggleFullscreen()
    return
  end
  if key == "o" and m.ctrl then
    App.cycleOrientation()
    return
  end
  if key == "f3" and m.ctrl then
    App.showFps = not App.showFps
    return
  end
  if App.iris or fx.transitioning then
    return
  end
  local target = App.top()
  if key == "space" and m.ctrl and not m.shift and target then
    local field = target.field
      or (target.fields and target.fields[target.focus])
      or (target.editing and target.editing.field)
      or (target.aiOpen and target.ai and target.ai.input)
    if field and field.focused and field:acceptSuggestion() then
      return
    end
  end
  if target and target.keypressed then
    target:keypressed(key, m, isRepeat)
  end
end

function App.textinput(t)
  if App.iris or fx.transitioning then
    return
  end
  local m = Keys.mods()
  if m.ctrl or m.gui then
    return
  end
  local target = App.top()
  if target and target.textinput then
    target:textinput(t)
  end
end

function App.mousepressed(x, y, b)
  if y / D.s < D.toolbarH then
    if b == 1 then
      for _, button in ipairs(App.displayButtons()) do
        local px, py = x / D.s, y / D.s
        if
          px >= button.x
          and px < button.x + button.w
          and py >= button.y
          and py < button.y + button.h
        then
          button.fn()
          break
        end
      end
    end
    return
  end
  if App.iris or fx.transitioning then
    return
  end
  local target = App.top()
  if target and target.mousepressed then
    local vx, vy = D.toVirtual(x, y)
    target:mousepressed(vx, vy, b)
  end
end

function App.mousereleased(x, y, b)
  local target = App.top()
  if target and target.mousereleased then
    local vx, vy = D.toVirtual(x, y)
    target:mousereleased(vx, vy, b)
  end
end

function App.mousemoved(x, y, dx, dy)
  local target = App.top()
  if target and target.mousemoved then
    local vx, vy = D.toVirtual(x, y)
    target:mousemoved(vx, vy, dx / D.s, dy / D.s)
  end
end

-- Mouse x as -1..1 across the content (parallax nudge).
function App.mouseK()
  local mx = D.toVirtual(love.mouse.getPosition())
  return fx.clamp((mx / math.max(1, D.vw)) * 2 - 1, -1, 1)
end

function App.wheelmoved(dx, dy)
  if App.iris or fx.transitioning then
    return
  end
  local target = App.top()
  if target and target.wheelmoved then
    target:wheelmoved(dx, dy)
  end
end

function App.resize(w, h)
  D.resize(w, h)
  App.syncOrientation()
  if App.scene and App.scene.resize then
    App.scene:resize()
  end
  for _, ov in ipairs(App.overlays) do
    if ov.resize then
      ov:resize()
    end
  end
end

-- Shared helpers for scenes ---------------------------------------------------

-- Skyline parallax backdrop: uses assets/bg_far|bg_mid|bg_near.png when they
-- exist, otherwise a procedural Causeway Bay silhouette. `t` drives motion.
local skyline = nil
local function buildSkyline(vw, vh)
  local layers = {}
  local rng = love.math.newRandomGenerator(7)
  for li = 1, 3 do
    local buildings = {}
    local x = -20
    while x < vw + 200 do
      local w = rng:random(10, 26 + li * 6)
      local h = rng:random(20, 50 + li * 30)
      buildings[#buildings + 1] = { x = x, w = w, h = h, lit = rng:random() }
      x = x + w + rng:random(1, 4)
    end
    layers[li] = { buildings = buildings }
  end
  skyline = { layers = layers, vw = vw, vh = vh }
end

function App.drawSkyline(t, alpha, yBase)
  local vw, vh = D.vw, D.vh
  alpha = alpha or 1
  yBase = yBase or vh
  -- sky gradient bands (portrait shows them above the width-fitted strip)
  local skyH = yBase - G.parallaxHeight(vw, vh)
  if skyH > 0 then
    for i = 0, 5 do
      local k = i / 5
      love.graphics.setColor(0.06 + 0.10 * k, 0.09 + 0.06 * k, 0.19 + 0.12 * k, alpha)
      love.graphics.rectangle("fill", 0, math.floor(skyH * i / 6), vw, math.ceil(skyH / 6) + 1)
    end
  end
  if G.drawParallax(t, vw, vh, App.mouseK(), alpha, yBase) then
    return
  end
  if not skyline or skyline.vw ~= vw or skyline.vh ~= vh then
    buildSkyline(vw, vh)
  end
  for i = 0, 5 do
    local k = i / 5
    love.graphics.setColor(0.06 + 0.10 * k, 0.09 + 0.06 * k, 0.19 + 0.12 * k, alpha)
    love.graphics.rectangle("fill", 0, math.floor(vh * i / 6), vw, math.ceil(vh / 6) + 1)
  end
  local shades = { { 0.13, 0.15, 0.30 }, { 0.10, 0.11, 0.24 }, { 0.07, 0.08, 0.17 } }
  for li, layer in ipairs(skyline.layers) do
    local speed = 2 + li * 3
    local off = (t * speed) % (vw + 200)
    if layer.img then
      layer.img:setWrap("repeat", "repeat")
      local q = love.graphics.newQuad(off, 0, vw, vh, layer.img:getWidth(), layer.img:getHeight())
      love.graphics.setColor(1, 1, 1, alpha)
      love.graphics.draw(layer.img, q, 0, yBase - vh)
    else
      local c = shades[li]
      for _, b in ipairs(layer.buildings) do
        local bx = ((b.x - off) % (vw + 200)) - 100
        love.graphics.setColor(c[1], c[2], c[3], alpha)
        love.graphics.rectangle("fill", math.floor(bx), yBase - b.h, b.w, b.h)
        -- lit windows
        if li == 3 then
          for wy = yBase - b.h + 3, yBase - 4, 5 do
            for wx = 2, b.w - 3, 4 do
              local on = (math.floor(wx * 7 + wy * 13 + b.lit * 100 + t * 0.2) % 5) ~= 0
              if on then
                love.graphics.setColor(0.87, 0.82, 0.53, 0.5 * alpha)
                love.graphics.rectangle("fill", math.floor(bx + wx), wy, 2, 2)
              end
            end
          end
        end
      end
    end
  end
end

return App
