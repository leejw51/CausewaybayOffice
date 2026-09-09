-- Deterministic UI stress gallery: make start ARGS="--mock --shots=polish".
local M = {}
function M.run(App, H)
  local rec
  local long = "香港-development-server-with-a-very-long-name.example.com"
  H.at(1, function()
    assert(App.core.mock, "polish gallery requires --mock")
    App.sessions.hosts = {}
    rec = App.sessions.open({ host = long, user = "administrator", noRemember = true })
    App.sessions.rename(rec.id, "香港-production-session-123456789")
    App.switch("map2")
  end)
  for _, size in ipairs({ { 1280, 800 }, { 800, 1400 }, { 640, 400 } }) do
    local suffix = size[1] .. "x" .. size[2]
    H.at(1.4, function()
      H.setMode(size[1], size[2])
      App.overlays = {}
      App.switch("map2")
    end)
    H.at(1.4, function()
      H.shot("polish_grid_" .. suffix)
      local grid = App.scene
      local fits = true
      for _, b in ipairs(grid.buttons) do
        fits = fits and b.x >= 0 and b.x + b.w <= App.D.vw
      end
      H.check("grid controls fit " .. suffix, fits)
      App.switch("map")
    end)
    H.at(1.4, function()
      H.shot("polish_map_" .. suffix)
      App.switch("terminal", { id = rec.id })
    end)
    H.at(1.4, function()
      H.shot("polish_terminal_" .. suffix)
      App.scene:toggleAI()
    end)
    H.at(1, function()
      App.scene.ai.input.value = string.rep("long input 香港 ", 20)
      H.shot("polish_ai_" .. suffix)
    end)
    for _, name in ipairs({
      "connect",
      "settings",
      "search",
      "rename",
      "password",
      "help",
      "history",
      "paste",
      "menu",
      "files",
      "transfer",
    }) do
      H.at(0.6, function()
        App.overlays = {}
        local params = {
          id = rec.id,
          initial = long,
          prompt = long,
          text = string.rep(long .. "\n", 20),
          title = long,
          items = { { "Disconnect " .. long }, { "Cancel" } },
          op = "download",
          path = "/tmp/" .. long,
        }
        local overlay = App.push(name, params)
        if name == "connect" then
          for _, field in ipairs(overlay.fields) do
            if not field.numeric then
              field.value = string.rep(long, 3)
            end
          end
          overlay.error = "Connection failed: " .. long
        elseif name == "settings" then
          overlay.sel = 3
        end
      end)
      H.at(0.4, function()
        H.shot("polish_" .. name .. "_" .. suffix)
      end)
    end
  end
  H.finish(0.6)
end
return M
