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
  for _, view in ipairs({ "map", "map2" }) do
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
    if view == "map" then
      rec = App.sessions.open({ host = "lobby-test.example", user = "test", noRemember = true })
    end
  end
  App.cfg.get().lobbyView = oldView
  App.cfg.save()
  App.scene, App.sceneName, App.overlays = oldScene, oldName, oldOverlays
end

return M
