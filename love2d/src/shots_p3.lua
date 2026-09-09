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

local QA_DIR = "/tmp/cbo_qa"

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

  -- hero6 --------------------------------------------------------------------
  if phase == "hero6" then
    local Lobby = require("src.scenes.lobby")
    local frames = {} -- ImageData
    local rect
    local function heroRect()
      local hero = Lobby.heroStrip(G)
      local sy = App.scene:shelfY()
      local rx, ry = D.ox + 16, D.oy + sy + 3 - hero.fh
      return { x = rx * D.s, y = ry * D.s, w = hero.fw * D.s, h = hero.fh * D.s, fh = hero.fh }
    end
    local hero
    -- pixels the sprite paints in *both* frames: the parallax scrolls behind
    -- the parts only one frame covers, so those cannot be compared
    local function painted(sx, sy)
      for f = 1, hero.n do
        local _, _, _, a = hero.data:getPixel((f - 1) * hero.fw + sx, sy)
        if a <= 0.5 then
          return false
        end
      end
      return true
    end
    -- rows (frame px) where the two strip frames differ: the hands band
    local function handsBand()
      local r0, r1 = nil, nil
      for y = 0, hero.fh - 1 do
        if G.frameDiff(hero, 1, 2, 0, y, hero.fw, 1) > 0 then
          r0 = r0 or y
          r1 = y
        end
      end
      return r0 or 0, r1 or -1
    end
    -- fraction of sprite-painted pixels that differ between two captures in a
    -- band of the hero rect (y0..y1 as fractions of the height)
    local function diff(a, b, f0, f1)
      local d, tot = 0, 0
      for y = rect.y + math.floor(rect.h * f0), rect.y + math.floor(rect.h * f1) - 1 do
        for x = rect.x, rect.x + rect.w - 1 do
          local sx = math.floor((x - rect.x) / D.s)
          local sy = math.floor((y - rect.y) / D.s)
          if painted(sx, sy) then
            local r1, g1, b1 = a:getPixel(x, y)
            local r2, g2, b2 = b:getPixel(x, y)
            tot = tot + 1
            if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.25 then
              d = d + 1
            end
          end
        end
      end
      return d / math.max(1, tot)
    end
    local drawn = {} -- (x, y) handed to drawAnchored for the lobby hero
    local origAnchored = G.drawAnchored
    local consecutive = 0
    local origDraw = App.draw
    at(3.4, function()
      check("lobby reached", App.sceneName == "lobby")
      hero = Lobby.heroStrip(G)
      rect = heroRect()
      check("hero strip is a 2-frame cycle", hero.n == 2, hero.n)
      G.drawAnchored = function(strip, i, x, y, sx, a)
        if strip == hero then
          drawn[#drawn + 1] = { x = x, y = y }
        end
        return origAnchored(strip, i, x, y, sx, a)
      end
      -- 6 consecutive frames straight from love.draw
      App.draw = function()
        origDraw()
        if consecutive < 6 then
          consecutive = consecutive + 1
          local k = consecutive
          love.graphics.captureScreenshot(function(img)
            frames[k] = img
            if k == 1 or k == 6 then
              img:encode("png", "qa_hero6_c" .. k .. ".png")
            end
          end)
        end
      end
    end)
    at(0.3, function()
      App.draw = origDraw
      check("6 consecutive frames captured", #frames == 6, #frames)
      local worst = 0
      for k = 2, 6 do
        worst = math.max(worst, diff(frames[1], frames[k], 0, 1))
      end
      check(
        "6 consecutive frames (same animation frame): whole hero identical",
        worst < 0.001,
        string.format("%.4f", worst)
      )
    end)
    -- 6 spaced frames over ~1 s (3 fps cycle -> both frames appear)
    local spaced = {}
    for k = 1, 6 do
      at(0.17, function()
        love.graphics.captureScreenshot(function(img)
          spaced[k] = img
          img:encode("png", "qa_hero6_s" .. k .. ".png")
        end)
      end)
    end
    at(0.3, function()
      check("6 spaced frames captured", #spaced == 6, #spaced)
      local r0, r1 = handsBand()
      local h0, h1 = r0 / hero.fh, (r1 + 1) / hero.fh
      local bands = {}
      for b = 0, 9 do
        local y0 = math.floor(hero.fh * b / 10)
        local y1 = math.floor(hero.fh * (b + 1) / 10)
        bands[#bands + 1] =
          string.format("%d%%:%.3f", b * 10, G.frameDiff(hero, 1, 2, 0, y0, hero.fw, y1 - y0))
      end
      info("strip frame 1 vs 2 diff per 10% band", table.concat(bands, " "))
      info(
        "hands band (rows that differ between the strip frames)",
        string.format("%d..%d of %d px (%.0f%%..%.0f%%)", r0, r1, hero.fh, h0 * 100, h1 * 100)
      )
      local aboveWorst, belowWorst, feetWorst, handsMax = 0, 0, 0, 0
      local distinct = {} -- clusters over the hands band
      for k = 1, 6 do
        if k > 1 then
          aboveWorst = math.max(aboveWorst, diff(spaced[1], spaced[k], 0, h0))
          belowWorst = math.max(belowWorst, diff(spaced[1], spaced[k], h1, 1))
          feetWorst = math.max(feetWorst, diff(spaced[1], spaced[k], 0.66, 1))
          handsMax = math.max(handsMax, diff(spaced[1], spaced[k], h0, h1))
        end
        local found = false
        for _, c in ipairs(distinct) do
          if diff(spaced[c], spaced[k], h0, h1) < 0.002 then
            found = true
          end
        end
        if not found then
          distinct[#distinct + 1] = k
        end
      end
      check("hands band sits above the locked lower body (< 66%)", r1 >= 0 and h1 <= 0.66 + 1e-9)
      check(
        "head/torso above the hands identical across all 6 frames",
        aboveWorst < 0.001,
        string.format("%.4f", aboveWorst)
      )
      check(
        "legs/chair/desk below the hands identical across all 6 frames",
        belowWorst < 0.001,
        string.format("%.4f", belowWorst)
      )
      check(
        "feet/chair region (bottom 34%) identical across all 6 frames",
        feetWorst < 0.001,
        string.format("%.4f", feetWorst)
      )
      check("hands/keyboard band animates", handsMax > 0.005, string.format("%.4f", handsMax))
      check("exactly 2 distinct frames in the cycle", #distinct == 2, #distinct)
      local intOK, n = true, 0
      for _, p in ipairs(drawn) do
        n = n + 1
        if p.x ~= math.floor(p.x) or p.y ~= math.floor(p.y) then
          intOK = false
        end
      end
      check("lobby hero drawn at integer px every frame", intOK and n > 0, n)
      G.drawAnchored = origAnchored
    end)
    finish(0.4)
    return true
  end

  -- nav ----------------------------------------------------------------------
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
    at(1.0, function()
      local sc = term()
      check("terminal reached", sc ~= nil)
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
          key("return") -- first item: Back to lobby
        end,
      },
    }
    for _, w in ipairs(ways) do
      at(0.4, function()
        check(w[1] .. ": starting in the terminal", App.sceneName == "terminal")
        w[2]()
        check(w[1] .. ": fade started (transition)", fx.transitioning == true)
      end)
      at(0.2, function()
        -- 0.22 s expo-in fade: a = 2^(10(u-1)) -> ~0.5 at 0.2 s (0.04 at 0.12 s)
        check(
          w[1] .. ": fading (fade.a > 0.4 at 0.2 s)",
          fx.fade.a > 0.4,
          string.format("%.2f", fx.fade.a)
        )
      end)
      at(0.82, function()
        check(w[1] .. ": lobby reached", App.sceneName == "lobby")
        if w[1] == "Esc Esc (< 300 ms)" then
          -- the first Esc reached zsh as a meta prefix: clear it
          App.core.write(rec.id, " \x15")
        end
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
      check("lobby reached", App.sceneName == "lobby")
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
      -- open from the lobby MAP button
      local mapBtn
      for _, b in ipairs(App.scene.buttons) do
        if b.w == G.uiWidth("MAP") + 12 then
          mapBtn = b
        end
      end
      check("lobby MAP button present", mapBtn ~= nil)
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
      -- hosts.json already carries the indices (saved by mapHosts)
      local raw = love.filesystem.read("hosts.json") or ""
      check("hosts.json holds platform indices", raw:find('"platform"', 1, true) ~= nil)
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
      check("Esc on the map -> lobby", App.sceneName == "lobby")
      key("m")
      check("key M starts a fade", fx.transitioning == true)
    end)
    -- walk: park the hero on the typhoon-shelter node (slot 3), walk to
    -- localhost (slot 1) over the flat harbourfront segment 2 -> 1
    local samples = {}
    local drawnFeet = {}
    local walkT0, walkDur, path
    at(1.0, function()
      sc = map()
      check("map opened with key M", sc ~= nil)
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
    at(1.0, function()
      check("lobby", App.sceneName == "lobby")
      key("m")
    end)
    at(0.9, function()
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
    at(1.0, function()
      key("m")
    end)
    at(0.9, function()
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
      local raw = love.filesystem.read("hosts.json") or ""
      check("... and hosts.json no longer lists it", raw:find("nosuch.invalid", 1, true) == nil)
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
      check("Esc mid-walk -> lobby", App.sceneName == "lobby")
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
    local Lobby = require("src.scenes.lobby")
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
    local function cfgFile()
      local t = require("src.json").decode(love.filesystem.read("config.json") or "{}")
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
        check("... persisted in config.json", cfgFile() == step[1], tostring(cfgFile()))
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
    end)
    at(0.8, function()
      info(
        "1080x1920 requested, actual",
        D.w .. "x" .. D.h .. " scale " .. D.s .. " vw " .. D.vw .. "x" .. D.vh
      )
      check("auto portrait at 1080x1920", D.portrait == true)
      local cols = App.scene:columns()
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
      check(
        "1080x1920: status bar shows F2 lobby",
        sc.statusRight:find("F2 lobby", 1, true) ~= nil,
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
      check("1080x1920 map fits the width", sc.L.mapW == D.vw, sc.L.mapW .. " vs " .. D.vw)
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
      check(
        "1080x800 grid unchanged from phase 2 (125x40)",
        sc.cols == 125 and sc.rows == 40,
        sc.cols .. "x" .. sc.rows
      )
      shot("qa_display3_final")
    end)
    finish(0.5)
    return true
  end

  return false
end

return M
