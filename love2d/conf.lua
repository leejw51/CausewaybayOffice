function love.conf(t)
  t.identity = "causewaybayoffice"
  t.version = "11.5"
  t.console = false
  t.accelerometerjoystick = false
  t.gammacorrect = false

  t.window.title = "CAUSEWAYBAY OFFICE"
  t.window.icon = nil
  t.window.width = 1280
  t.window.height = 800
  t.window.minwidth = 640
  t.window.minheight = 400
  t.window.resizable = true
  t.window.vsync = 1
  t.window.msaa = 0
  t.window.highdpi = false
  t.window.usedpiscale = false
  t.window.fullscreen = false
  t.window.fullscreentype = "desktop"

  t.modules.physics = false
  t.modules.video = false
  t.modules.thread = false
end
