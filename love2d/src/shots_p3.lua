-- Phase 3 scripted QA (`love love2d --shots=<phase>`), dispatched from
-- src/shots.lua. Same conventions: every step is an fx timer, input goes
-- through the real routing, `[qa] PASS|FAIL|INFO` lines, qa_<phase>.log and
-- qa_*.png in the save dir, exit 1 on any failure.
--
--   hero6      6 consecutive + 6 spaced lobby frames: feet/chair/torso pixels
--              identical, only hands differ, exactly 2 frames in the cycle
--   nav        terminal -> lobby by button / F2 / Ctrl+Esc / Esc Esc / menu,
--              single Esc reaches the shell as 0x1b, AI-panel Esc, toast,
--              status bar "F2 lobby" at 1080 / 800 / 640 px
--   nav2       (second launch) the toast never comes back
--   map3       world map matrix: walk geometry + timing, dust, camera,
--              arrival, fresh connect, live focus, black hole, unresolvable,
--              Enter / R / Del, keepalive glow, hover thumbnail, paging,
--              Esc mid-walk cancels the connect, fps with 3 sessions
--   map3verify (second launch) platform indices unchanged after a restart
--   display3   F11 + Settings > display both ways, Ctrl+O cycle persisted,
--              portrait 1080x1920 (cards, AI below, map, overlays), forced
--              portrait on a short window pans the map, resize storm

local M = {}

-- Shell-side scratch, scoped by phase group like CBO_HOME and the settings
-- file (love2d/main.lua): the `qa` phase wipes this directory on startup, and
-- `map3verify` reads what `map3` left in it, so two phases may only share it
-- when they are a restart pair.
local QA_DIR = "/tmp/cbo_qa-" .. (os.getenv("CBO_QA_GROUP") or "local")

function M.run(App, phase, H)
  local fx, D = App.fx, App.D
  local at, check, info, shot, key, typeText, line, term, finish, setMode =
    H.at, H.check, H.info, H.shot, H.key, H.typeText, H.line, H.term, H.finish, H.setMode
  local none, ctrl = H.none, H.ctrl
  local user = os.getenv("USER") or "dev"
  local MG = require("src.mapgraph")
  local G = App.G

  local function openLocalhost(keepalive, noRemember)
    local cols, rows = App.termGrid()
    return App.sessions.open({
      host = "localhost",
      port = 22,
      user = user,
      cols = cols,
      rows = rows,
      keepalive = keepalive or 15,
      noRemember = noRemember,
    })
  end
  -- Favorites live in SQLite under the real core and in the LOVE save directory
  -- only under the mock one (sessions.lua saveHosts), so a persistence check
  -- has to ask the store. Reading the file directly returns "" against the real
  -- core, which makes a "does not contain" assertion pass for the wrong reason.
  local function storedHosts()
    local raw = App.core.kvGet("ui.hosts")
    if raw == "" then
      raw = love.filesystem.read(App.sessions.FILE) or ""
    end
    return raw
  end

  local function fileRead(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local s = f:read("*a")
    f:close()
    return s
  end
  local function fileWrite(path, s)
    local f = io.open(path, "wb")
    if f then
      f:write(s)
      f:close()
    end
  end
  -- content (virtual) px -> window px for App.mouse* calls
  local function toWindow(vx, vy)
    return (vx + D.ox) * D.s, (vy + D.oy) * D.s
  end
  local function clickButton(bt, b)
    local x, y = toWindow(bt.x + bt.w / 2, bt.y + bt.h / 2)
    App.mousepressed(x, y, b or 1)
    App.mousereleased(x, y, b or 1)
  end

  -- The `hero` and `hero6` phases photographed the seated hero on
  -- scenes/lobby.lua. That scene stopped being reachable when the lobby became
  -- Map 1 / Map 2 / Map 3 (App.lobbyView never returns "lobby"), so they were
  -- testing pixels nothing draws. Retired 2026-09-18; test.lua still checks
  -- that Lobby.heroStrip loads as a 2-frame strip.
  if phase == "nav" then
    local rec
    at(3.4, function()
      App.cfg.get().seenTermHint = false -- first-entry toast must show once
      App.cfg.save()
      os.execute("mkdir -p " .. QA_DIR .. " && rm -f " .. QA_DIR .. "/esc.txt")
      rec = openLocalhost(15, true)
      check("localhost session opened", rec ~= nil)
    end)
    at(2.5, function()
      check("connected", rec.state == App.core.ST.CONNECTED)
      App.switch("terminal", { id = rec.id })
    end)
    -- 1.3 s, not 1.0: lobby <-> terminal runs the 0.55 + 0.65 s camera
    -- transition, and App.textinput drops everything while one is running, so
    -- typing any earlier is silently swallowed.
    at(1.3, function()
      local sc = term()
      check("terminal reached", sc ~= nil)
      check("no transition is swallowing input", fx.transitioning ~= true)
      check("first entry: toast shown", sc.toast ~= nil and sc.toast.a > 0.5)
      check("seenTermHint persisted", App.cfg.get().seenTermHint == true)
      shot("qa_nav_toast")
      -- single Esc goes to the shell as 0x1b and does not leave the terminal
      line("cat -v > " .. QA_DIR .. "/esc.txt")
    end)
    at(0.5, function()
      key("escape")
    end)
    at(0.5, function()
      check("single Esc stays in the terminal", App.sceneName == "terminal")
      typeText("x")
      key("return")
      term():write("\x04")
    end)
    at(0.6, function()
      local got = fileRead(QA_DIR .. "/esc.txt") or "(missing)"
      check("single Esc reached the shell as 0x1b (cat -v: ^[x)", got == "^[x\n", got)
      -- AI panel: Esc closes the panel only
      term():toggleAI()
    end)
    at(0.6, function()
      check("AI panel open", term().aiOpen == true)
      key("escape")
    end)
    at(0.5, function()
      check("Esc with the AI panel open closes the panel only", term().aiOpen == false)
      check("... and stays in the terminal", App.sceneName == "terminal")
      local got = fileRead(QA_DIR .. "/esc.txt") or ""
      check("... and sends nothing to the shell", got == "^[x\n", got)
    end)
    -- five ways back, each with a fade
    local ways = {
      {
        "click < LOBBY",
        function()
          local sc = term()
          local bt
          for _, b in ipairs(sc.buttons) do
            if b.id == "lobby" then
              bt = b
            end
          end
          check("< LOBBY button present", bt ~= nil)
          if bt then
            clickButton(bt, 1)
          end
        end,
      },
      {
        "F2",
        function()
          key("f2")
        end,
      },
      {
        "Ctrl+Esc",
        function()
          key("escape", ctrl)
        end,
      },
      {
        "Esc Esc (< 300 ms)",
        function()
          key("escape")
          key("escape")
        end,
      },
      {
        "right-click menu > Back",
        function()
          local sc = term()
          local x, y = toWindow(sc.ox + 40, sc.oy + 40)
          App.mousepressed(x, y, 2)
          check("context menu opened", App.hasOverlay("menu"))
          -- By label, not by index: the session menu has grown items above it.
          local ov = App.overlays[#App.overlays]
          local back
          for i, item in ipairs(ov.items or {}) do
            if item[1]:find("Back to lobby", 1, true) then
              back = i
            end
          end
          check("context menu offers Back to lobby", back ~= nil)
          ov.sel = back or 1
          key("return")
        end,
      },
    }
    local fadeAt
    for _, w in ipairs(ways) do
      at(0.4, function()
        check(w[1] .. ": starting in the terminal", App.sceneName == "terminal")
        w[2]()
        check(w[1] .. ": fade started (transition)", fx.transitioning == true)
      end)
      -- Nothing cuts: the fade is already on its way out at the first sample and
      -- deeper at the second. Sampled as a progression rather than against a
      -- number, because terminal <-> lobby uses its own 0.55 / 0.65 s camera
      -- durations (App.switch) instead of the 0.22 s default.
      at(0.2, function()
        fadeAt = fx.fade.a
        check(
          w[1] .. ": fading, not cutting",
          fx.fade.a > 0 and fx.transitioning == true,
          string.format("%.3f", fx.fade.a)
        )
      end)
      at(0.3, function()
        check(
          w[1] .. ": fade deepens toward the swap",
          fx.fade.a > fadeAt,
          string.format("%.3f -> %.3f", fadeAt, fx.fade.a)
        )
      end)
      at(0.52, function()
        check(w[1] .. ": lobby reached", App.isLobby(App.sceneName))
        if w[1] == "Esc Esc (< 300 ms)" then
          -- the first Esc reached zsh as a meta prefix: clear it
          App.core.write(rec.id, " \x15")
        end
      end)
      at(0.6, function()
        -- App.switch refuses while a transition runs, and the lobby appears at
        -- the darkest point, half way through one.
        check(w[1] .. ": transition finished", fx.transitioning ~= true)
        key("return") -- back into the terminal (card selected)
      end)
      at(0.9, function()
        check(w[1] .. ": second entry shows no toast", term() and term().toast == nil)
      end)
    end
    -- status bar keeps "F2 lobby" down to 640 px
    for _, w in ipairs({ { 1080, 800 }, { 800, 500 }, { 640, 400 } }) do
      at(0.3, function()
        setMode(w[1], w[2])
      end)
      at(0.6, function()
        local sc = term()
        check(
          string.format("status bar shows F2 lobby at %dx%d", D.w, D.h),
          sc.statusRight:find("F2 lobby", 1, true) ~= nil,
          sc.statusRight
        )
        check(
          string.format("status bar right block clear of the left text at %dx%d", D.w, D.h),
          sc.statusRightX > sc.statusLeftEnd,
          sc.statusRightX .. " vs " .. sc.statusLeftEnd
        )
        shot("qa_nav_status_" .. w[1])
      end)
    end
    at(0.3, function()
      setMode(1080, 800)
    end)
    finish(0.6)
    return true
  end

  if phase == "nav2" then
    local rec
    at(3.4, function()
      check("seenTermHint still set after restart", App.cfg.get().seenTermHint == true)
      rec = openLocalhost(15, true)
    end)
    at(2.5, function()
      App.switch("terminal", { id = rec.id })
    end)
    at(0.8, function()
      check("no toast after a restart", term() and term().toast == nil)
    end)
    finish(0.3)
    return true
  end

  -- map3 ---------------------------------------------------------------------
  if phase == "map3" then
    local S = App.sessions
    local sc -- map scene
    local keys = {} -- host -> key
    local slotOf = {} -- host -> platform slot (1-based)
    local function map()
      return App.sceneName == "map" and App.scene or nil
    end
    local function nodeWindowPos(m, slot)
      local x, y = m:toScreen(m:nodeMapPos(slot))
      return toWindow(x, y - 6)
    end
    local audioLog = {}
    local origPlay = App.audio.play
    App.audio.play = function(name)
      audioLog[#audioLog + 1] = name
      return origPlay(name)
    end
    local function played(name, since)
      for i = since or 1, #audioLog do
        if audioLog[i] == name then
          return true
        end
      end
      return false
    end
    local dustCount = 0
    local origDust = fx.dustPuff
    fx.dustPuff = function(...)
      dustCount = dustCount + 1
      return origDust(...)
    end

    at(3.4, function()
      check("lobby reached", App.isLobby(App.sceneName))
      S.hosts = {}
      S.rememberHost({ host = "localhost", port = 22, user = user })
      S.rememberHost({ host = "10.255.255.1", port = 22, user = user })
      S.rememberHost({ host = "nosuch.invalid", port = 22, user = user })
      for _, h in ipairs(S.hosts) do
        h.platform = nil
        h.firstSeen = ({ localhost = 100, ["10.255.255.1"] = 200, ["nosuch.invalid"] = 300 })[h.host]
        keys[h.host] = S.hostKey(h)
      end
      S.saveHosts()
      -- Open Map 1 from the lobby's own MAP 1 button. lobby_views.draw gives
      -- every layout button an id, which is stable across the three lobbies;
      -- the old width probe matched the retired lobby scene's "MAP" button.
      App.scene:draw()
      local mapBtn
      for _, b in ipairs(App.scene.buttons) do
        if b.id == "map" then
          mapBtn = b
        end
      end
      check("lobby MAP 1 button present", mapBtn ~= nil)
      if mapBtn then
        clickButton(mapBtn, 1)
      end
      check("MAP button starts a fade", fx.transitioning == true)
    end)
    at(1.0, function()
      sc = map()
      check("map opened from the lobby button", sc ~= nil)
      check("3 stages", sc and #sc.hosts == 3, sc and #sc.hosts)
      for _, h in ipairs(sc.hosts) do
        slotOf[h.host] = MG.slot(h.platform) + 1
      end
      check(
        "platforms assigned in first-seen order (0,1,2)",
        slotOf.localhost == 1 and slotOf["10.255.255.1"] == 2 and slotOf["nosuch.invalid"] == 3,
        string.format(
          "%s %s %s",
          slotOf.localhost,
          slotOf["10.255.255.1"],
          slotOf["nosuch.invalid"]
        )
      )
      -- favorites already carry the indices (saved by mapHosts)
      local raw = storedHosts()
      check("favorites hold platform indices", raw:find('"platform"', 1, true) ~= nil)
      local reloaded = S.loadHosts()
      local same = true
      for _, h in ipairs(reloaded) do
        if slotOf[h.host] ~= MG.slot(h.platform) + 1 then
          same = false
        end
      end
      check("platform indices identical after loadHosts()", same)
      local out = {}
      for host, k in pairs(keys) do
        out[#out + 1] = k .. "=" .. tostring(S.findHost(k).platform)
        info("platform", host .. " -> " .. tostring(S.findHost(k).platform))
      end
      fileWrite(QA_DIR .. "/platforms.txt", table.concat(out, "\n") .. "\n")
      -- BFS is shortest on the JSON adjacency (all pairs vs Floyd-Warshall)
      local nodes = sc.nodes
      local n = #nodes.platforms
      local dist = {}
      for i = 1, n do
        dist[i] = {}
        for j = 1, n do
          dist[i][j] = (i == j) and 0 or math.huge
        end
      end
      for a, nbs in pairs(nodes.adj) do
        for _, b in ipairs(nbs) do
          dist[a][b] = 1
        end
      end
      for k = 1, n do
        for i = 1, n do
          for j = 1, n do
            if dist[i][k] + dist[k][j] < dist[i][j] then
              dist[i][j] = dist[i][k] + dist[k][j]
            end
          end
        end
      end
      local bad = 0
      for i = 1, n do
        for j = 1, n do
          local p = MG.bfs(nodes, i, j)
          if not p or #p - 1 ~= dist[i][j] then
            bad = bad + 1
          end
        end
      end
      check(
        "BFS = shortest path for all " .. n * n .. " pairs",
        bad == 0 and not nodes.fallback,
        bad
      )
      check("designer graph: 10 platforms, 12 edges", n == 10 and #nodes.paths == 12, #nodes.paths)
      key("escape")
    end)
    at(0.9, function()
      -- Map 1 is the chosen lobby here, so Escape has nowhere to fall back to:
      -- App.switch("lobby") resolves to App.lobbyView(), which is this scene.
      -- There is no separate lobby scene behind it any more.
      check("Esc on the map stays in the lobby", App.isLobby(App.sceneName))
      check("... on Map 1 itself", App.sceneName == "map", App.sceneName)
      check("... without a transition", fx.transitioning ~= true)
    end)
    -- walk: park the hero on the typhoon-shelter node (slot 3), walk to
    -- localhost (slot 1) over the flat harbourfront segment 2 -> 1
    local samples = {}
    local drawnFeet = {}
    local walkT0, walkDur, path
    at(1.0, function()
      sc = map()
      check("still on Map 1 for the walk", sc ~= nil)
      sc.hero.slot = 3
      sc:placeHero(true)
      sc.sel = 1
      local origAnchored = G.drawAnchored
      G.drawAnchored = function(strip, i, x, y, sx, a)
        if sc.hero.state == "walk" and strip == sc:strips().walk then
          drawnFeet[#drawnFeet + 1] = { x = x, y = y, camY = sc.cam.y, seg = sc.hero.seg }
        end
        return origAnchored(strip, i, x, y, sx, a)
      end
      sc.restoreAnchored = function()
        G.drawAnchored = origAnchored
      end
      local origUpdate = sc.update
      sc.update = function(self, dt)
        origUpdate(self, dt)
        if self.hero.state == "walk" and self.hero.path then
          local h = self.hero
          samples[#samples + 1] = {
            t = fx.time,
            x = h.x,
            y = h.y,
            by = h.by,
            seg = h.seg,
            segT = h.segT,
            facing = h.facing,
            camX = self.cam.x,
            camY = self.cam.y,
          }
        end
      end
      dustCount = 0
      walkT0 = fx.time
      check("walk started", sc:startWalk(1))
      path = sc.hero.path
      walkDur = MG.walkDuration(path or {})
      check("path 3 -> 2 -> 1 (BFS)", path and #path == 3 and path[2].slot == 2, path and #path)
      info("walk duration", string.format("%.2fs", walkDur))
      -- arrival + connecting checks scheduled from the measured duration
      fx.after(walkDur + 0.05, function()
        shot("qa_map3_arrived")
        check("arrived: hop state", sc.hero.state == "hop" and sc.hero.slot == 1, sc.hero.state)
        check(
          "arrived: 24 confetti",
          fx.particleCount("confetti") == 24,
          fx.particleCount("confetti")
        )
        check("arrived: label pops (scale < 1)", sc.labelPop.s < 1, sc.labelPop.s)
        check("no live session before the connect", S.count() == 0, S.count())
        sc.restoreAnchored()
      end)
      fx.after(walkDur + 0.24 + 0.08, function()
        local st = sc:stageState(S.findHost(keys.localhost))
        check("localhost connecting (amber) after the hop", st == "connecting", st)
        check("hero idle after the hop", sc.hero.state == "idle", sc.hero.state)
        check("connect opened one session", S.count() == 1 and sc.pending ~= nil, S.count())
        shot("qa_map3_connecting")
      end)
    end)
    at(0.35, function()
      shot("qa_map3_walk")
    end)
    at(2.0, function()
      -- geometry over the whole walk
      local offLine, nonMono, badFacing, offScreen, badFeet, badFlat = 0, 0, 0, 0, 0, 0
      local prevSeg, prevE = 0, -1
      local L = sc.L
      for _, s in ipairs(samples) do
        local a, b = path[s.seg], path[s.seg + 1]
        if a and b then
          local dx, dy = b.x - a.x, b.y - a.y
          local len = math.sqrt(dx * dx + dy * dy)
          local cross = math.abs((s.x - a.x) * dy - (s.by - a.y) * dx) / math.max(1, len)
          if cross > 0.5 then
            offLine = offLine + 1
          end
          local e = ((s.x - a.x) * dx + (s.by - a.y) * dy) / math.max(1, len * len)
          if s.seg == prevSeg and e < prevE - 1e-9 then
            nonMono = nonMono + 1
          end
          prevSeg, prevE = s.seg, e
          if s.facing ~= MG.facing(dx) then
            badFacing = badFacing + 1
          end
          -- flat segment: feet line constant, y = feet + bob only
          if math.abs(dy) < 1e-6 then
            if math.abs(s.by - a.y) > 1e-6 then
              badFlat = badFlat + 1
            end
            local u = math.min(1, s.segT / MG.segmentDuration(len))
            if math.abs((s.y - s.by) - MG.bob(u, MG.steps(len))) > 1e-6 then
              badFlat = badFlat + 1
            end
          end
        end
        local sx, sy = s.x - s.camX, s.by - s.camY
        if sx < 0 or sx > L.viewW or sy < 0 or sy > L.viewH then
          offScreen = offScreen + 1
        end
      end
      for _, f in ipairs(drawnFeet) do
        local a = path[f.seg]
        if a and math.abs(path[f.seg + 1].y - a.y) < 1e-6 then
          local rel = f.y + f.camY - sc.L.viewY + 8 - a.y -- = bob (drawn), +-1 px rounding
          if math.abs(rel) > 3 then
            badFeet = badFeet + 1
          end
        end
      end
      info("walk samples", #samples .. " updates, " .. #drawnFeet .. " draws")
      check("hero stays on the polyline (< 0.5 px)", offLine == 0 and #samples > 10, offLine)
      check("expoInOut progress monotonic within every segment", nonMono == 0, nonMono)
      check("facing follows dx on every sample", badFacing == 0, badFacing)
      check("flat segment: feet line constant, y = feet + cosine bob", badFlat == 0, badFlat)
      check("flat segment: drawn feet within the bob of the platform line", badFeet == 0, badFeet)
      check("hero never off-screen while the camera pans", offScreen == 0, offScreen)
      -- segment timing: first sample of each segment
      local first = {}
      for _, s in ipairs(samples) do
        first[s.seg] = first[s.seg] or s.t
      end
      local okT = true
      for i = 1, #path - 2 do
        local a, b = path[i], path[i + 1]
        local len = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        local want = MG.segmentDuration(len)
        local got = (first[i + 1] or 0) - (first[i] or 0)
        info(
          string.format("segment %d timing", i),
          string.format("%.3fs want %.3fs (len %.0f)", got, want, len)
        )
        if math.abs(got - want) > 0.04 then
          okT = false
        end
      end
      check("segment timing = max(220, 380*len/100) ms", okT)
      local wantDust = walkDur / 0.12
      check(
        "dust puffs every ~120 ms",
        math.abs(dustCount - wantDust) <= 2,
        string.format("%d puffs, expected ~%.1f", dustCount, wantDust)
      )
      local panned = false
      for _, s in ipairs(samples) do
        if math.abs(s.camX - samples[1].camX) > 0.5 or math.abs(s.camY - samples[1].camY) > 0.5 then
          panned = true
        end
      end
      info(
        "camera panned during the walk",
        tostring(panned)
          .. string.format(" (map %dx%d view %dx%d)", L.mapW, L.mapH, L.viewW, L.viewH)
      )
    end)
    -- fresh connect to localhost (no live session): amber -> green + jingle + sparks -> terminal
    local t0 = 1
    at(2.2, function()
      local sc2 = map()
      if sc2 then
        info("still on the map", sc2.pending and "pending" or "-")
      end
      check("connect jingle played", played("connect", t0))
      check("flag planted on localhost", sc.flags[keys.localhost] ~= nil)
      check("terminal scene after the connect settle", App.sceneName == "terminal")
      check("one session opened", S.count() == 1, S.count())
      shot("qa_map3_terminal")
      key("f2")
    end)
    -- live focus: clicking the online node focuses the session, no second one
    at(1.4, function()
      -- terminal -> lobby is the 0.55 + 0.65 s camera transition; the lobby is
      -- Map 1, so there is nothing further to open
      check("lobby", App.isLobby(App.sceneName))
      check("lobby transition finished", fx.transitioning ~= true)
    end)
    at(0.5, function()
      sc = map()
      check("map again", sc ~= nil)
      check("hero starts on the last used host", sc.hero.slot == 1, sc.hero.slot)
      local st = sc:stageState(S.findHost(keys.localhost))
      check("localhost online (green)", st == "online", st)
      -- keepalive glow: reconnect keepalive at 2 s so a ping lands soon
      App.core.setKeepalive(S.list[1].id, 2)
      -- hover thumbnail
      local x, y = nodeWindowPos(sc, 1)
      App.mousemoved(x, y, 0, 0)
      check("hover over the online node", sc.hover == 1, sc.hover)
      check("thumbnail source available", App.view(S.list[1].id).canvas ~= nil)
    end)
    local pulseMax, pulseDecays = 0, false
    at(0.3, function()
      shot("qa_map3_hover")
      local last = -1
      local origUpdate = sc.update
      sc.update = function(self, dt)
        origUpdate(self, dt)
        local rec = S.list[1]
        if rec then
          if rec.pulse > pulseMax then
            pulseMax = rec.pulse
          end
          if last > 0 and rec.pulse > 0 and rec.pulse < last then
            pulseDecays = true
          end
          if rec.pulse > 0.9 and not self.shotGlow then
            self.shotGlow = true
            shot("qa_map3_glow")
          end
          last = rec.pulse
        end
      end
    end)
    at(3.2, function()
      check("keepalive pulse seen on the map", pulseMax > 0.9, string.format("%.2f", pulseMax))
      check("pulse decays on the map (glow pulses)", pulseDecays)
      App.mousemoved(10, 10, 0, 0)
      local n0 = S.count()
      local x, y = nodeWindowPos(sc, 1)
      App.mousepressed(x, y, 1)
      App.mousereleased(x, y, 1)
      sc.n0 = n0
    end)
    at(1.4, function()
      check("click on the live node -> terminal", App.sceneName == "terminal")
      check("session count unchanged (focus, not a second session)", S.count() == sc.n0, S.count())
      check("focused the live session", term() and term().id == S.list[1].id)
      key("f2")
    end)
    -- Enter / R / Del in the info panel
    at(1.4, function()
      check("F2 returned to Map 1", App.sceneName == "map", App.sceneName)
      check("F2 transition finished", fx.transitioning ~= true)
    end)
    at(0.5, function()
      sc = map()
      sc.sel = 3
      key("r")
      check("R opens the rename overlay", App.hasOverlay("rename"))
      key("escape")
    end)
    at(0.4, function()
      key("delete")
      check("Del asks for confirmation", App.hasOverlay("menu"))
      key("escape")
    end)
    at(0.4, function()
      check("Esc keeps the host", S.findHost(keys["nosuch.invalid"]) ~= nil)
      -- unresolvable: walk there via Enter, expect a quick red error
      sc.sel = 3
      key("return")
      check("Enter walks to the selected stage", sc.hero.state == "walk")
    end)
    at(3.5, function()
      local st = sc:stageState(S.findHost(keys["nosuch.invalid"]))
      check("unresolvable host: error within ~3 s", st == "error", st)
      check(
        "... error text recorded",
        sc.errors[keys["nosuch.invalid"]] ~= nil,
        sc.errors[keys["nosuch.invalid"]]
      )
      check("... hero stays on the map", App.sceneName == "map" and sc.hero.slot == 3, sc.hero.slot)
      check("... failed session closed (count back to 1)", S.count() == 1, S.count())
      shot("qa_map3_unresolvable")
      -- black hole: amber for the 10 s timeout, then red flicker
      sc.sel = 2
      key("return")
    end)
    at(5.0, function()
      local st = sc:stageState(S.findHost(keys["10.255.255.1"]))
      check("black hole: still connecting (amber) at 5 s", st == "connecting", st)
      check("... hero waiting on the node", sc.hero.slot == 2 and sc.hero.state == "idle")
      shot("qa_map3_blackhole_amber")
    end)
    at(7.5, function()
      -- the 10 s connect timeout starts after the walk + hop (~1 s)
      local st = sc:stageState(S.findHost(keys["10.255.255.1"]))
      check("black hole: error after the 10 s timeout", st == "error", st)
      check("... red flicker running", sc.flicker ~= nil and sc.flicker.key == keys["10.255.255.1"])
      check(
        "... error text",
        sc.errors[keys["10.255.255.1"]] ~= nil,
        sc.errors[keys["10.255.255.1"]]
      )
      check("... hero stays, still on the map", App.sceneName == "map" and sc.hero.slot == 2)
      shot("qa_map3_blackhole_error")
    end)
    -- Del + confirm forgets nosuch.invalid
    at(0.5, function()
      sc.sel = 3
      key("delete")
      key("return")
    end)
    at(0.4, function()
      check("Del + Enter forgets the host", S.findHost(keys["nosuch.invalid"]) == nil)
      local raw = storedHosts()
      check(
        "... and the favorites store no longer lists it",
        raw ~= "" and raw:find("nosuch.invalid", 1, true) == nil,
        #raw .. " bytes"
      )
      check("... its platform disappears from the map", sc:hostAt(3) == nil)
      -- paging: 9 more hosts -> 2 pages
      for i = 1, 9 do
        S.rememberHost({ host = string.format("mock-%02d.lan", i), port = 22, user = user })
      end
      App.switch("map")
    end)
    at(0.9, function()
      sc = map()
      check("11 hosts -> 2 pages", sc.pages == 2, sc.pages)
      local last = S.lastUsedHost()
      check(
        "map opens on the last used host's page (page 2: mock-09)",
        sc.page == MG.page(last.platform) and sc.page == 1 and sc.hero.page == 1,
        sc.page
      )
      check("page 2 has stages", sc:hostAt(1, 1) ~= nil)
      shot("qa_map3_page2")
      key("[")
      check("[ -> page 1", sc.page == 0, sc.page)
      check("hero stays on page 2 (not drawn here)", sc.hero.page == 1)
      -- the hero is on page 2: a walk here fades him in on this page's first stage
      local n0 = S.count()
      sc.n0 = n0
      sc.sel = 2
      check("walk on page 1 starts", sc:startWalk(2))
      check("hero moved to page 1 and fades in", sc.hero.page == 0 and sc.hero.alpha < 1)
      key("]")
      check("] -> page 2", sc.page == 1, sc.page)
      key("[")
      -- Esc mid-walk: the scene dies, the hop -> connect timer must not fire
      key("escape")
    end)
    at(2.0, function()
      check("Esc mid-walk -> lobby", App.isLobby(App.sceneName))
      check("no session opened by the dead map scene", S.count() == sc.n0, S.count())
      -- fps with 3 sessions on the map
      openLocalhost(15, true)
      openLocalhost(15, true)
    end)
    at(2.5, function()
      check("3 sessions live", S.count() == 3, S.count())
      App.switch("map")
    end)
    local fpsS = {}
    at(0.8, function()
      check("map with 3 sessions", map() ~= nil)
    end)
    for i = 1, 5 do
      at(0.2, function()
        fpsS[#fpsS + 1] = love.timer.getFPS()
        if i == 3 then
          shot("qa_map3_three")
        end
      end)
    end
    at(0.2, function()
      info("map fps with 3 sessions", table.concat(fpsS, " "))
      check("map fps >= 55 with 3 sessions", math.min(unpack(fpsS)) >= 55)
      App.audio.play = origPlay
      fx.dustPuff = origDust
      -- final platform table for map3verify (after the forget + 9 new hosts)
      local out = {}
      for _, h in ipairs(S.hosts) do
        out[#out + 1] = S.hostKey(h) .. "=" .. tostring(h.platform)
      end
      fileWrite(QA_DIR .. "/platforms.txt", table.concat(out, "\n") .. "\n")
      info("platforms saved for map3verify", #out .. " hosts")
    end)
    finish(0.5)
    return true
  end

  if phase == "map3verify" then
    at(0.5, function()
      local S = App.sessions
      local txt = fileRead(QA_DIR .. "/platforms.txt") or ""
      local n, bad = 0, 0
      for k, p in txt:gmatch("([^\n=]+)=(%d+)\n") do
        n = n + 1
        local h = S.findHost(k)
        if not h or tostring(h.platform) ~= p then
          bad = bad + 1
          info("platform moved", k .. " " .. p .. " -> " .. tostring(h and h.platform))
        end
      end
      check(
        "platform indices stable across a restart",
        n >= 2 and bad == 0,
        n .. " hosts, " .. bad .. " moved"
      )
      local sc = require("src.scenes.map").new(App, {})
      local ok = true
      for _, h in ipairs(sc.hosts) do
        local want = txt:match(S.hostKey(h):gsub("%p", "%%%0") .. "=(%d+)")
        if want and tonumber(want) ~= h.platform then
          ok = false
        end
      end
      check("map scene places hosts on the same platforms", ok)
    end)
    finish(0.3)
    return true
  end

  -- display3 -----------------------------------------------------------------
  if phase == "display3" then
    local Term = require("src.scenes.terminal")
    local rec
    local g0
    at(3.4, function()
      rec = openLocalhost(15, true)
    end)
    at(2.5, function()
      App.switch("terminal", { id = rec.id })
    end)
    at(1.0, function()
      g0 = { App.scene.cols, App.scene.rows }
      App.keypressed("f11")
      love.window.setVSync(0)
      check("F11 starts a fade", fx.transitioning == true)
    end)
    at(1.4, function()
      local sc = term()
      local i = App.core.info(sc.id)
      check(
        "F11: fullscreen on",
        D.fullscreen and love.window.getFullscreen(),
        tostring(love.window.getFullscreen())
      )
      check(
        "F11: grid == core",
        i and i.cols == sc.cols and i.rows == sc.rows,
        sc.cols .. "x" .. sc.rows
      )
      check("F11: config display=fullscreen", App.cfg.get().display == "fullscreen")
      shot("qa_display3_f11")
      App.keypressed("f11")
      love.window.setVSync(0)
    end)
    at(1.4, function()
      local sc = term()
      local i = App.core.info(sc.id)
      check("F11 again: window", not D.fullscreen and not love.window.getFullscreen())
      check(
        "F11 again: grid restored == core",
        sc.cols == g0[1] and sc.rows == g0[2] and i.cols == sc.cols
      )
      check("config display=window", App.cfg.get().display == "window")
      App.push("settings")
    end)
    local function settingsRow(kind)
      local ov = App.overlays[#App.overlays]
      for i, r in ipairs(ov.rows) do
        if r.kind == kind then
          ov.sel = i
          return ov, r
        end
      end
    end
    at(0.6, function()
      local ov, row = settingsRow("display")
      check("settings has a display row", row ~= nil)
      ov:adjust(row, 1)
      love.window.setVSync(0)
    end)
    at(1.4, function()
      local sc = term()
      local i = App.core.info(sc.id)
      check("Settings > display: fullscreen", D.fullscreen and love.window.getFullscreen())
      check("Settings > display: grid == core", i and i.cols == sc.cols and i.rows == sc.rows)
      shot("qa_display3_settings_fs")
      local ov, row = settingsRow("display")
      check(
        "settings row says fullscreen",
        ov:valueText(row):find("fullscreen", 1, true) ~= nil,
        ov:valueText(row)
      )
      ov:adjust(row, 1)
      love.window.setVSync(0)
    end)
    at(1.4, function()
      local sc = term()
      local i = App.core.info(sc.id)
      check(
        "Settings > display: back to window",
        not D.fullscreen and not love.window.getFullscreen()
      )
      check("Settings > display: grid restored == core", sc.cols == g0[1] and i.cols == sc.cols)
      -- Ctrl+O cycles auto -> landscape -> portrait -> auto, persisted
      check("Ctrl+O chord", require("src.keys").appChord("o", ctrl) == "orientation")
      key("escape")
    end)
    -- Where settings actually live: SQLite (ui.config) under the real core;
    -- the JSON file is only the legacy import that config.lua reads once.
    local function cfgStore()
      local raw = App.core.kvGet("ui.config")
      if raw == "" then
        raw = love.filesystem.read(App.cfg.FILE) or "{}"
      end
      local t = require("src.json").decode(raw)
      return t and t.orientation
    end
    for _, step in ipairs({
      { "landscape", false },
      { "portrait", true },
      { "auto", false },
    }) do
      at(0.4, function()
        App.cycleOrientation()
        check("Ctrl+O -> " .. step[1], D.orientationMode == step[1], D.orientationMode)
        check("... persisted in settings", cfgStore() == step[1], tostring(cfgStore()))
        check(
          "... effective portrait=" .. tostring(step[2]) .. " at 1080x800",
          D.portrait == step[2]
        )
        local sc = term()
        local i = App.core.info(sc.id)
        check(
          "... terminal grid == core",
          i and i.cols == sc.cols and i.rows == sc.rows,
          sc.cols .. "x" .. sc.rows
        )
        if step[1] == "portrait" then
          check("... AI docks below when forced portrait", Term.aiDock(D) == "bottom")
          shot("qa_display3_forced_portrait")
        end
      end)
    end
    -- forced portrait on a short window: the map is taller than the view and pans
    at(0.3, function()
      App.setOrientation("portrait")
      App.switch("map")
    end)
    local camYs = {}
    at(1.0, function()
      local sc = App.scene
      check(
        "forced portrait map fits the width",
        sc.L.mapW == D.vw and sc.L.portrait,
        sc.L.mapW .. " vs " .. D.vw
      )
      check(
        "... map taller than the view (pans vertically)",
        sc.L.mapH > sc.L.viewH,
        sc.L.mapH .. " vs " .. sc.L.viewH
      )
      sc.hero.slot = 1
      sc:placeHero(true)
      camYs[1] = sc.cam.y
      sc:startWalk(7) -- south-west, bottom of the map
      local origUpdate = sc.update
      sc.update = function(self, dt)
        origUpdate(self, dt)
        camYs[#camYs + 1] = self.cam.y
        local sy = self.hero.by - self.cam.y
        if sy < 0 or sy > self.L.viewH then
          self.offScreen = (self.offScreen or 0) + 1
        end
      end
    end)
    at(1.2, function()
      shot("qa_display3_portrait_pan")
    end)
    at(1.5, function()
      local sc = App.scene
      local moved = math.abs(camYs[#camYs] - camYs[1]) > 4
      check(
        "camera panned vertically following the hero",
        moved,
        string.format("%.0f -> %.0f", camYs[1], camYs[#camYs])
      )
      check("hero never off-screen during the vertical pan", (sc.offScreen or 0) == 0, sc.offScreen)
      local mono = true
      for i = 2, #camYs do
        if camYs[i] < camYs[i - 1] - 0.01 then
          mono = false
        end
      end
      check("camera pan is monotonic (expo approach, no overshoot)", mono)
      App.setOrientation("auto")
      App.switch("lobby")
    end)
    -- portrait 1080x1920
    at(0.8, function()
      setMode(1080, 1920)
      -- the column check below is a Map 2 property, and the pan test above
      -- left Map 1 as the remembered lobby
      App.switch("map2")
    end)
    at(0.8, function()
      info(
        "1080x1920 requested, actual",
        D.w .. "x" .. D.h .. " scale " .. D.s .. " vw " .. D.vw .. "x" .. D.vh
      )
      check("auto portrait at 1080x1920", D.portrait == true)
      local cols = App.scene.cols
      check("lobby cards in 1-2 columns", cols >= 1 and cols <= 2, cols)
      shot("qa_display3_p1080_lobby")
      App.switch("terminal", { id = rec.id })
    end)
    at(0.9, function()
      term():toggleAI()
    end)
    at(0.8, function()
      local sc = term()
      local i = App.core.info(sc.id)
      check("1080x1920: AI panel docks below", Term.aiDock(D) == "bottom")
      check("1080x1920: terminal keeps >= 24 rows with the AI panel", sc.rows >= 24, sc.rows)
      check(
        "1080x1920: core grid agrees",
        i and i.cols == sc.cols and i.rows == sc.rows,
        sc.cols .. "x" .. sc.rows
      )
      -- The hint shrinks by design as the window narrows: grid + "F2 lobby
      -- F1 help", then "F2 lobby F1 help", then "F1 help" (Term.drawStatus).
      -- At 1080x1920 the content width is far below the 640 px the `nav` phase
      -- checks the full hint at, so what is guaranteed here is that a hint
      -- survives at all.
      check(
        "1080x1920: status bar keeps a hint",
        sc.statusRight:find("F1 help", 1, true) ~= nil,
        sc.statusRight
      )
      shot("qa_display3_p1080_ai")
      key("escape")
    end)
    -- every overlay fits the width
    for _, name in ipairs({ "connect", "search", "rename", "settings", "help" }) do
      at(0.5, function()
        App.push(name, { id = rec.id, fromTerminal = true })
      end)
      at(0.5, function()
        local ov = App.overlays[#App.overlays]
        check("overlay " .. name .. " open in portrait", ov and ov.name == name)
        shot("qa_display3_p1080_" .. name)
        key("escape")
      end)
    end
    at(0.5, function()
      App.switch("map")
    end)
    at(1.0, function()
      local sc = App.scene
      -- Portrait covers the tall view and pans sideways (e140b9f); it no
      -- longer fits the map to the width and letterboxes it.
      check(
        "1080x1920 map covers the tall view",
        sc.L.mapH == sc.L.viewH and sc.L.mapW > D.vw,
        sc.L.mapW .. "x" .. sc.L.mapH .. " view " .. D.vw .. "x" .. sc.L.viewH
      )
      check("1080x1920 map fully visible (no pan needed)", sc.L.mapH <= sc.L.viewH)
      shot("qa_display3_p1080_map")
      App.switch("terminal", { id = rec.id })
    end)
    -- resize storm alternating orientation
    at(0.9, function()
      for i = 1, 10 do
        if i % 2 == 1 then
          setMode(700 + i * 10, 1000 + i * 10)
        else
          setMode(1000 + i * 10, 700 + i * 10)
        end
        App.resize(love.graphics.getDimensions())
      end
      setMode(1080, 800)
    end)
    at(0.9, function()
      local sc = term()
      local i = App.core.info(sc.id)
      check(
        "resize storm: grid == core size",
        i and i.cols == sc.cols and i.rows == sc.rows,
        sc.cols .. "x" .. sc.rows
      )
      check("resize storm: landscape again at 1080x800", D.portrait == false)
      -- Against the grid this phase started with, not a constant captured on
      -- one machine: the window a request of 1280x800 actually produces, and
      -- so the grid it yields, differs per display.
      check(
        "1080x800 grid unchanged from the start of the phase",
        sc.cols == g0[1] and sc.rows == g0[2],
        sc.cols .. "x" .. sc.rows .. " vs " .. g0[1] .. "x" .. g0[2]
      )
      shot("qa_display3_final")
    end)
    finish(0.5)
    return true
  end

  return false
end

return M
