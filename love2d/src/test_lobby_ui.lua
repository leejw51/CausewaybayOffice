local M = {}

function M.run(App, check)
  local UI, G, fx = require("src.ui"), App.G, App.fx
  local none = { ctrl = false, shift = false, alt = false, gui = false }
  for _, value in ipairs({
    "long-host-name.example.com",
    "香港 안녕하세요 Příliš",
    "a\nb\tc",
  }) do
    for _, width in ipairs({ 0, 4, 8, 48, 120 }) do
      local fitted = UI.fit(value, width)
      check(
        "bounded UTF-8 label at " .. width,
        require("utf8").len(fitted) ~= nil and G.uiWidth(fitted) <= width
      )
    end
  end
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setScissor(10, 10, 100, 60)
  local field = UI.field("", string.rep("香港-long-value-", 20))
  field.focused, field.selectAll = true, true
  field:draw(12, 12, 96, 0, 0)
  local x, y, w, h = love.graphics.getScissor()
  check("input preserves parent clipping", x == 10 and y == 10 and w == 100 and h == 60)
  love.graphics.pop()

  local oldScene, oldName, oldOverlays = App.scene, App.sceneName, App.overlays
  local oldMap3 = App.cfg.get().map3View
  App.cfg.get().map3View = nil
  local oldView = App.cfg.get().lobbyView
  local rec = App.sessions.open({ host = "lobby-test.example", user = "test", noRemember = true })
  local function settle()
    for _ = 1, 6 do
      fx.update(0.5)
    end
  end
  local function button(scene, id)
    scene:draw()
    for _, b in ipairs(scene.buttons) do
      if b.id == id then
        return b
      end
    end
  end
  settle()
  for _, view in ipairs({ "map", "map2", "map3" }) do
    App.switch(view)
    settle()
    check(
      "choosing lobby saves " .. view,
      App.sceneName == view and App.cfg.get().lobbyView == view
    )
    App.cfg.load()
    check("lobby selection survives config reload " .. view, App.lobbyView() == view)
    local scene = App.scene
    if view == "map" then
      local originalText, originalUI = G.text, G.ui
      local contained = true
      G.text = function(value, x, y, ...)
        local b = scene.labelBounds
        contained = contained
          and x >= b.padding
          and y >= b.padding
          and x + G.textWidth(value) <= b.w - b.padding
          and y + G.fontTerm:getHeight() <= b.h - b.padding
        return originalText(value, x, y, ...)
      end
      G.ui = function(value, x, y, ...)
        local b = scene.labelBounds
        contained = contained
          and x >= b.padding
          and y >= b.padding
          and x + G.uiWidth(value) <= b.w - b.padding
          and y + G.fontUI:getHeight() <= b.h - b.padding
        return originalUI(value, x, y, ...)
      end
      local oldName, oldHost = rec.name, rec.host
      rec.name, rec.host = string.rep("香港", 40), string.rep("long-host-", 40)
      scene:drawLabel(scene.sel, 1)
      G.text, G.ui = originalText, originalUI
      rec.name, rec.host = oldName, oldHost
      check("Map 1 popup text stays inside its padded frame", contained)
    end
    App.switch("lobby")
    check("current lobby return keeps scene " .. view, App.scene == scene)
    App.switch("terminal", { id = rec.id })
    settle()
    App.scene:keypressed("f2", none)
    settle()
    check("F2 returns to selected lobby " .. view, App.sceneName == view)
    local disconnect = button(App.scene, "disconnect")
    local originalDisconnect, selected = App.disconnectSession
    App.disconnectSession = function(target)
      selected = target
    end
    if disconnect then
      disconnect.fn()
    end
    check("visible lobby disconnect targets selected session " .. view, selected == rec)
    App.disconnectSession = originalDisconnect
    if view == "map3" then
      local wall = App.scene
      wall:update(0.3)
      wall:draw()
      check("monitor wall includes every session", #wall.cards == #App.sessions.list)
      check("monitor wall starts with room for 100 sessions", wall.cols * wall.rows >= 100)
      local entries = wall.entries
      wall.entries = {}
      for i = 1, 100 do
        wall.entries[i] = rec
      end
      wall:fit(100)
      settle()
      wall:draw()
      local contained = #wall.cards == 100
      for _, c in ipairs(wall.cards) do
        contained = contained
          and c.w > 0
          and c.h > 0
          and c.x >= 0
          and c.y >= wall.top
          and c.x + c.w <= App.D.vw
          and c.y + c.h <= wall.bottom
      end
      check("100 monitors fit on one page with no clipping", contained)
      wall.entries = entries
      wall:fit()
      settle()
      wall.field.focused = true
      wall.field.value = "no-such-monitor-xyz"
      wall:refresh()
      check("Map3 search excludes nonmatching sessions", #wall.entries == 0)
      wall.field.value = rec.host .. " " .. rec.user
      wall:refresh()
      check(
        "Map3 search matches multiple address terms",
        #wall.entries > 0 and wall.entries[1].host == rec.host and wall.entries[1].user == rec.user
      )
      wall:keypressed("escape", none)
      check(
        "Map3 Escape clears search",
        wall.field.value == "" and #wall.entries == #App.sessions.list
      )
      local realCount = #App.sessions.list
      wall:toggleSimulation()
      wall:update(0.2)
      check(
        "simulation contains 100 isolated fake sessions",
        #wall.entries == 100 and #App.sessions.list == realCount
      )
      local fake = wall.entries[1]
      local simView = wall:view(fake)
      local rendered = simView.renders
      wall:update(1.2)
      check("simulation produces live terminal updates", simView.renders > rendered)
      wall:open()
      check("simulation cannot open a real terminal", App.sceneName == "map3")
      local Banner = require("src.ascii_banner")
      check(
        "word art accepts eight words",
        Banner.lines("CAUSEWAY BAY OFFICE SHOWS ONE HUNDRED LIVE NODES") ~= nil
      )
      check(
        "word art rejects nine words",
        Banner.lines("one two three four five six seven eight nine") == nil
      )
      check("word art rejects shell metacharacters", Banner.command("$(touch bad)") == nil)
      wall.command.value = "CAUSEWAY BAY OFFICE"
      wall:sendWordArt()
      wall:update(1)
      check("word art reaches simulated sessions", #simView.art > 5)
      wall:sendArt("CAT")
      check("cat art reaches simulated sessions", #simView.art == 3)
      wall.command.value = "pwd"
      wall:sendCommand()
      check(
        "simulated pwd has a fake working directory",
        simView.reply == "/home/sim/" .. fake.name
      )

      wall:toggleSimulation()
      check(
        "stopping simulation restores real sessions",
        not wall.simulation and #wall.entries == realCount
      )
      local oldWrite, oldState = App.core.write, App.core.state
      local writes = {}
      App.core.write = function(id, text)
        writes[#writes + 1] = { id = id, text = text }
      end
      App.core.state = function()
        return App.core.ST.CONNECTED
      end
      wall.field.value = rec.host
      wall:refresh()
      wall.command.value = "pwd"
      local expected = #wall:recipients()
      wall:sendCommand()
      check(
        "Commander sends pwd only to shown connected nodes",
        #writes == expected and #writes > 0 and writes[1].text == "pwd\r"
      )
      App.core.write, App.core.state = oldWrite, oldState
      wall.field.value = ""
      wall:refresh()
      wall:fit()
      wall:move(12, -8, 2)
      wall:remember()
      App.cfg.save()
      App.cfg.load()
      local restored = require("src.scenes.map3").new(App)
      check(
        "Map3 view survives config reload",
        restored.capacity == nil
          and restored.camera.z == 2
          and restored.camera.x == 12
          and restored.camera.y == -8
      )
      wall:fit()
      settle()
      local tv = App.view(rec.id)
      local cols, rows, renders = tv.cols, tv.rows, tv.renders
      wall:zoomBy(3)
      settle()
      wall:draw()
      check("monitor wall zoom enlarges screens", wall.camera.z > 1)
      check(
        "monitor zoom preserves terminal grid and cached canvas",
        tv.cols == cols and tv.rows == rows and tv.renders == renders
      )
      local oldOS, oldDown = love.system.getOS, love.keyboard.isDown
      love.system.getOS = function()
        return "OS X"
      end
      love.keyboard.isDown = function()
        return false
      end
      local z = wall.camera.z
      wall:wheelmoved(0.5, 1.25)
      wall:wheelmoved(0.5, 1.25)
      settle()
      check(
        "Mac trackpad pans both axes and accumulates fractional input",
        math.abs(wall.camera.x - 18 / z) < 0.001
          and math.abs(wall.camera.y - 45 / z) < 0.001
          and wall.camera.z == z
      )
      love.keyboard.isDown = function()
        return true
      end
      wall:wheelmoved(0, 1)
      settle()
      check("Mac modified scroll zooms", wall.camera.z > z)
      love.system.getOS, love.keyboard.isDown = oldOS, oldDown
      wall:fit()
      settle()
      check(
        "monitor wall fit restores overview",
        wall.camera.z == 1 and wall.camera.x == 0 and wall.camera.y == 0
      )
    end
    if view == "map2" then
      App.scene.field.value = "missing"
      App.scene:setFilter(2)
      App.scene:keypressed("escape", none)
      check(
        "grid Escape clears filters without leaving lobby",
        App.scene.field.value == "" and App.scene.filter == 1
      )
    end
    App.switch("terminal", { id = rec.id })
    settle()
    local D = App.D
    local oldW, oldH = D.w, D.h
    for _, size in ipairs({ { 1080, 800 }, { 800, 1400 }, { 640, 400 } }) do
      D.resize(size[1], size[2])
      App.scene:layout()
      App.scene:drawTabStrip(rec)
      local fits = true
      local toolbar = {}
      for _, b in ipairs(App.scene.buttons) do
        if b.y < App.scene:chromeTop() - require("src.scenes.terminal").CWD_H then
          fits = fits and b.x >= 0 and b.x + b.w <= D.vw
          for _, other in ipairs(toolbar) do
            fits = fits
              and not (
                b.x < other.x + other.w
                and b.x + b.w > other.x
                and b.y < other.y + other.h
                and b.y + b.h > other.y
              )
          end
          toolbar[#toolbar + 1] = b
        end
      end
      check("terminal controls fit without overlapping at " .. size[1] .. "x" .. size[2], fits)
      App.scene:drawStatus(rec)
      check(
        "status text keeps separate columns at " .. size[1],
        App.scene.statusLeftEnd < App.scene.statusRightX
      )
    end
    D.resize(oldW, oldH)
    App.scene:layout()
    local close = button(App.scene, "disconnect")
    check("terminal exposes Disconnect", close ~= nil)
    if close then
      close.fn()
    end
    App.updateIris(0.5)
    check("disconnect returns to chosen lobby " .. view, App.sceneName == view)
    App.updateIris(0.6)
    if view ~= "map3" then
      rec = App.sessions.open({ host = "lobby-test.example", user = "test", noRemember = true })
    end
  end
  App.cfg.get().map3View = oldMap3
  App.cfg.get().lobbyView = oldView
  App.cfg.save()
  App.scene, App.sceneName, App.overlays = oldScene, oldName, oldOverlays
end

return M
