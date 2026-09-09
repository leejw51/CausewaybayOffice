-- CAUSEWAYBAY OFFICE — retro 8-bit ssh client.
-- Rust core (libcbo_core) + LÖVE UI. `love . -- --test` runs the test suite.

io.stdout:setvbuf("no")

local App = require("src.app")

local testMode = false
local headless = false -- --test / --shots: crash -> error.log + exit 1 instead of the blue screen

-- Print crashes (also to error.log in the save dir), then either quit
-- (headless runs) or fall back to LÖVE's blue screen.
local defaultErrorHandler = love.errorhandler
function love.errorhandler(msg)
  local text = tostring(msg) .. "\n" .. debug.traceback()
  print("CRASH: " .. text)
  pcall(love.filesystem.write, "error.log", text)
  if headless then
    return function()
      return 1
    end
  end
  return defaultErrorHandler(msg)
end

function love.load(args)
  local forceMock = false
  local demo, open, shots = false, false, nil
  for _, a in ipairs(args or {}) do
    if a == "--test" then
      testMode = true
      headless = true
    elseif a == "--mock" then
      forceMock = true
    elseif a == "--demo" then
      demo = true
    elseif a == "--open" then
      open = true
    elseif a == "--shots" or a:sub(1, 8) == "--shots=" then
      -- scripted walkthroughs (src/shots.lua): art | qa | verify | limit | perf | mock
      shots = a:match("^%-%-shots=(%w+)$") or "art"
      headless = true
    end
  end
  if testMode then
    love.filesystem.setIdentity("causewaybayoffice-test")
  elseif shots then
    love.filesystem.setIdentity("causewaybayoffice-qa")
    local ffi = require("ffi")
    ffi.cdef("int setenv(const char*, const char*, int);")
    if not os.getenv("CBO_HOME") then
      ffi.C.setenv("CBO_HOME", love.filesystem.getSaveDirectory() .. "/core", 1)
    end
  elseif forceMock or demo then
    love.filesystem.setIdentity("causewaybayoffice-demo")
  end
  App.init({
    forceMock = forceMock or testMode,
    allowFixtures = shots ~= nil,
    restoreSessions = not (forceMock or testMode or shots or demo),
  })
  if demo then
    -- three sessions for screenshots / feel testing (works with mock or real core)
    local cols, rows = App.termGrid()
    local user = os.getenv("USER") or "dev"
    for _, h in ipairs({ "localhost", "hk-build-01.lan", "fail.invalid" }) do
      App.sessions.open({
        host = h,
        port = 22,
        user = user,
        cols = cols,
        rows = rows,
        noRemember = true,
      })
    end
  end
  if testMode then
    local ok, res = pcall(function()
      return require("src.test").run(App)
    end)
    if not ok then
      print("TEST CRASH: " .. tostring(res))
      love.event.quit(1)
      return
    end
    love.event.quit(res and 0 or 1)
    return
  end
  if shots then
    -- a scripted run may be launched from a non-interactive shell where the
    -- window never becomes frontmost: with vsync on, macOS then stops
    -- delivering frames and the walkthrough never advances
    love.window.setVSync(0)
    require("src.shots").run(App, shots)
  end
  if open and App.sessions.list[1] then
    App.switch("terminal", { id = App.sessions.list[1].id })
  else
    App.switch("boot")
  end
end

function love.update(dt)
  if testMode then
    return
  end
  App.update(dt)
end

function love.draw()
  if testMode then
    return
  end
  App.draw()
end

function love.keypressed(key, sc, isRepeat)
  if headless then
    return
  end
  App.keypressed(key, sc, isRepeat)
end

function love.textinput(t)
  if headless then
    return
  end
  App.textinput(t)
end

function love.mousepressed(x, y, b)
  if headless then
    return
  end
  App.mousepressed(x, y, b)
end

function love.mousereleased(x, y, b)
  if headless then
    return
  end
  App.mousereleased(x, y, b)
end

function love.mousemoved(x, y, dx, dy)
  if headless then
    return
  end
  App.mousemoved(x, y, dx, dy)
end

function love.wheelmoved(dx, dy)
  if headless then
    return
  end
  App.wheelmoved(dx, dy)
end

function love.filedropped(file)
  if headless then
    return
  end
  local path = file:getFilename()
  file:close()
  local overlay = App.overlays[#App.overlays]
  if overlay and overlay.filedropped then
    overlay:filedropped(path)
  elseif not overlay and App.sceneName == "terminal" then
    App.push("transfer", { id = App.scene.id, op = "upload", path = path, auto = true })
  end
end

function love.resize(w, h)
  App.resize(w, h)
end

function love.quit()
  require("src.ui").flush()
  App.cfg.save()
  App.sessions.saveHosts()
  App.sessions.update(0)
  App.sessions.saveRestore()
  App.core.shutdown()
end
