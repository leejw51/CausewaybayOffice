-- Keyboard -> terminal bytes (xterm-ish), and the app-reserved chords.

local K = {}

K.SPECIAL = {
  ["return"] = "\r",
  kpenter = "\r",
  backspace = "\x7f",
  tab = "\t",
  escape = "\x1b",
  up = "\x1b[A",
  down = "\x1b[B",
  right = "\x1b[C",
  left = "\x1b[D",
  home = "\x1b[H",
  ["end"] = "\x1b[F",
  pageup = "\x1b[5~",
  pagedown = "\x1b[6~",
  delete = "\x1b[3~",
  insert = "\x1b[2~",
  f1 = "\x1bOP",
  f2 = "\x1bOQ",
  f3 = "\x1bOR",
  f4 = "\x1bOS",
  f5 = "\x1b[15~",
  f6 = "\x1b[17~",
  f7 = "\x1b[18~",
  f8 = "\x1b[19~",
  f9 = "\x1b[20~",
  f10 = "\x1b[21~",
  f11 = "\x1b[23~",
  f12 = "\x1b[24~",
}

-- Chords the app keeps for itself (never sent to the terminal).
-- returns action name or nil
function K.appChord(key, m)
  if key == "f1" then
    return "help"
  end
  if key == "f11" then
    return "fullscreen"
  end
  if key == "f2" then
    return "lobby"
  end
  if m.gui then
    if key == "v" then
      return "paste"
    end
    if key == "c" then
      return "copy"
    end
    if key == "n" then
      return "new"
    end
    if key == "k" then
      return "search"
    end
    if key == "," then
      return "settings"
    end
    if key == "q" then
      return "quit"
    end
  end
  if m.ctrl then
    if key == "escape" then
      return "lobby"
    elseif key == "o" then
      return "orientation"
    elseif key == "n" then
      return "new"
    elseif key == "k" then
      return m.shift and "history" or "search"
    elseif key == "r" then
      return "rename"
    elseif key == "tab" then
      return m.shift and "cycleBack" or "cycle"
    elseif key == "space" then
      return "ai"
    elseif key == "," then
      return "settings"
    elseif key == "v" and m.shift then
      return "paste"
    elseif key == "=" or key == "+" or key == "kp+" then
      return "zoomIn"
    elseif key == "-" or key == "kp-" then
      return "zoomOut"
    end
  end
  return nil
end

-- Modifier state. On macOS it is read from the OS (CoreGraphics session
-- flags), not from SDL: system shortcuts such as Cmd+Shift+5 (screen
-- recording) swallow the key-up of Cmd/Shift, so SDL keeps reporting them as
-- held and every keypress and text event is dropped until the modifier is
-- pressed again. That is why typing died while the Mac recorded the screen.
local osFlags
if love.system.getOS() == "OS X" then
  local ok, fn = pcall(function()
    local ffi = require("ffi")
    ffi.cdef("uint64_t CGEventSourceFlagsState(int32_t stateID);")
    local C = ffi.load("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    C.CGEventSourceFlagsState(0) -- probe: raises if the symbol is missing
    return function()
      return tonumber(C.CGEventSourceFlagsState(0)) -- combined session state
    end
  end)
  if ok then
    osFlags = fn
  end
end
K.osFlags = osFlags

local SHIFT, CTRL, ALT, GUI = 0x20000, 0x40000, 0x80000, 0x100000

function K.mods()
  if osFlags then
    local f = osFlags()
    return {
      ctrl = f % (CTRL * 2) >= CTRL,
      shift = f % (SHIFT * 2) >= SHIFT,
      alt = f % (ALT * 2) >= ALT,
      gui = f % (GUI * 2) >= GUI,
    }
  end
  local kb = love.keyboard
  return {
    ctrl = kb.isDown("lctrl", "rctrl"),
    shift = kb.isDown("lshift", "rshift"),
    alt = kb.isDown("lalt", "ralt"),
    gui = kb.isDown("lgui", "rgui"),
  }
end

-- Bytes for a keypressed event that the terminal should receive, or nil when
-- the key will arrive through love.textinput (plain printable keys).
function K.translate(key, m)
  m = m or {}
  if m.gui then
    return nil
  end
  if key == "tab" and m.shift then
    return "\x1b[Z"
  end
  local sp = K.SPECIAL[key]
  if sp then
    if m.shift and (key == "up" or key == "down" or key == "left" or key == "right") then
      return "\x1b[1;2" .. sp:sub(-1)
    end
    if m.alt and (key == "left" or key == "right") then
      return "\x1b[1;3" .. sp:sub(-1)
    end
    return sp
  end
  if m.ctrl then
    if #key == 1 then
      local b = key:byte()
      if b >= 97 and b <= 122 then
        return string.char(b - 96)
      end
      if key == "[" then
        return "\x1b"
      elseif key == "]" then
        return "\x1d"
      elseif key == "\\" then
        return "\x1c"
      elseif key == "/" or key == "-" then
        return "\x1f"
      end
    end
    return nil
  end
  if m.alt and #key == 1 then
    return "\x1b" .. key
  end
  return nil
end

return K
