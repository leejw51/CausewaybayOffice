-- Procedural chiptune blips (square / triangle), no asset files.
--   Audio.play("connect" | "click" | "error" | "bell" | "open" | "close")

local Audio = {}

local SR = 22050
local sources = {}
Audio.enabled = true
Audio.clicks = false -- key click off by default

local function newData(n)
  return love.sound.newSoundData(n, SR, 16, 1)
end

local function clamp(v)
  if v > 1 then
    return 1
  end
  if v < -1 then
    return -1
  end
  return v
end

local function square(phase, duty)
  return (phase % 1 < (duty or 0.5)) and 1 or -1
end

local function tri(phase)
  local p = phase % 1
  if p < 0.5 then
    return p * 4 - 1
  end
  return 3 - p * 4
end

-- notes: { {freq, dur}, ... } rendered back to back with a short release.
local function render(notes, vol, wave, duty)
  local total = 0
  for _, n in ipairs(notes) do
    total = total + n[2]
  end
  local N = math.max(1, math.floor(SR * total))
  local d = newData(N)
  local i = 0
  local phase = 0
  for _, n in ipairs(notes) do
    local len = math.floor(SR * n[2])
    local f = n[1]
    for k = 0, len - 1 do
      if i >= N then
        break
      end
      local u = k / len
      local env = math.min(1, k / (SR * 0.004)) * (1 - u) ^ 0.6
      local s = 0
      if f > 0 then
        phase = phase + f / SR
        s = wave == "tri" and tri(phase) or square(phase, duty)
      end
      d:setSample(i, clamp(s * vol * env))
      i = i + 1
    end
  end
  local src = love.audio.newSource(d, "static")
  return src
end

local function buzz(dur, vol)
  local N = math.floor(SR * dur)
  local d = newData(N)
  local phase = 0
  for i = 0, N - 1 do
    local u = i / N
    local f = 110 - 40 * u
    phase = phase + f / SR
    local s = square(phase, 0.3) * 0.7 + (love.math.random() * 2 - 1) * 0.3
    d:setSample(i, clamp(s * vol * (1 - u)))
  end
  return love.audio.newSource(d, "static")
end

function Audio.init()
  local ok = pcall(function()
    sources.connect = render({
      { 523, 0.07 },
      { 659, 0.07 },
      { 784, 0.07 },
      { 1047, 0.16 },
    }, 0.22, "sq", 0.25)
    sources.open = render({ { 440, 0.05 }, { 660, 0.08 } }, 0.16, "tri")
    sources.close = render({ { 660, 0.05 }, { 440, 0.08 } }, 0.16, "tri")
    sources.click = render({ { 1800, 0.012 } }, 0.05, "sq", 0.5)
    sources.select = render({ { 880, 0.03 } }, 0.10, "sq", 0.25)
    sources.bell = render({ { 1319, 0.05 }, { 1760, 0.12 } }, 0.20, "tri")
    sources.error = buzz(0.25, 0.25)
  end)
  if not ok then
    Audio.enabled = false
  end
end

function Audio.play(name)
  if not Audio.enabled then
    return
  end
  if name == "click" and not Audio.clicks then
    return
  end
  local s = sources[name]
  if s then
    s:stop()
    s:play()
  end
end

return Audio
