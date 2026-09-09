-- Atomic saves in the private LÖVE save directory. Restrict access BEFORE
-- writing keys; a failed save leaves the previous file intact.
local ffi = require("ffi")
ffi.cdef("int chmod(const char *path, unsigned int mode);")
local M = {}

function M.write(name, data)
  local dir = love.filesystem.getSaveDirectory()
  local ok, err = love.filesystem.createDirectory("")
  if not ok then
    return false, err
  end
  if ffi.os ~= "Windows" and ffi.C.chmod(dir, 448) ~= 0 then
    return false, "cannot make save directory private"
  end
  local temp = name .. ".tmp"
  ok, err = love.filesystem.write(temp, data)
  if not ok then
    return false, err
  end
  if ffi.os ~= "Windows" and ffi.C.chmod(dir .. "/" .. temp, 384) ~= 0 then
    return false, "cannot make save file private"
  end
  return os.rename(dir .. "/" .. temp, dir .. "/" .. name)
end

return M
