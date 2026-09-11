-- Scene-local synthetic output. Never enters Sessions or calls the Rust core.
local ffi = require("ffi")
local TV = require("src.term_view")
local M = {}
function M.new()
  local sim = { list = {}, views = {}, time = 0 }
  for i = 1, 100 do
    sim.list[i] = {
      id = -i,
      name = string.format("demo-%03d", i),
      host = string.format("node-%03d.test", i),
      user = "sim",
      port = 22,
      simulated = true,
    }
  end
  function sim:view(rec)
    local v = self.views[rec.id]
    if not v then
      v = TV.new(nil, nil)
      v.simCells = ffi.new("CboCell[?]", 80 * 24)
      v.simTick = -1
      self.views[rec.id] = v
    end
    return v
  end
  function sim:update(dt, entries)
    self.time = self.time + dt
    for _, rec in ipairs(entries) do
      local v = self:view(rec)
      local tick = math.floor(self.time + (-rec.id % 10) / 10)
      if v.simTick ~= tick or v.dirty then
        local cells = v.simCells
        for j = 0, 80 * 24 - 1 do
          cells[j].cp, cells[j].width = 32, 1
          cells[j].fg, cells[j].bg = 0x73D07C, 0x101830
        end
        local function line(row, text, color)
          for col = 1, math.min(80, #text) do
            local c = cells[row * 80 + col - 1]
            c.cp, c.fg = text:byte(col), color or 0x73D07C
          end
        end
        line(0, "SIMULATION / " .. rec.name .. " / NO CONNECTION", 0x66DBF0)
        line(2, "$ " .. (v.command or "cargo run --release -- monitor-demo"), 0xDED187)
        line(3, v.reply or "Synthetic worker output / test mode", 0x66DBF0)
        for row = 4, 20 do
          local job = tick * 17 + row + -rec.id * 100
          line(
            row,
            string.format(
              "[%06d] worker-%02d  job %06d  OK  %3d ms",
              tick,
              -rec.id,
              job,
              job % 97 + 1
            )
          )
        end
        line(
          22,
          string.format(
            "CPU %2d%%   QUEUE %3d   FRAME %06d",
            (tick * 7 - rec.id) % 100,
            (tick - rec.id) % 128,
            tick
          ),
          0xDED187
        )
        local art = v.art or {}
        if #art > 0 then
          local offset = #art > 20 and (tick % math.ceil(#art / 20)) * 20 or 0
          for i = 1, math.min(20, #art - offset) do
            line(i + 2, art[offset + i], 0xDED187)
          end
        end
        v:renderCells(cells, 80, 24)
        v.simTick, v.dirty = tick, false
        v.cx, v.cy = tick % 60, 23
      end
      v:update(dt)
    end
  end
  function sim:send(rec, command)
    local v = self:view(rec)
    v.command = command
    v.art = {}
    if command:sub(1, 6) == "printf" then
      local first = true
      for part in command:gmatch("'([^']*)'") do
        if first then
          first = false
        else
          v.art[#v.art + 1] = part
        end
      end
    end
    v.reply = command == "pwd" and ("/home/sim/" .. rec.name)
      or command == "ls" and "README.md  src  Cargo.toml  logs"
      or "[simulation] command received; nothing executed"
    v.dirty = true
  end
  function sim:release()
    for _, v in pairs(self.views) do
      if v.canvas then
        v.canvas:release()
      end
    end
    self.views = {}
  end
  return sim
end
return M
