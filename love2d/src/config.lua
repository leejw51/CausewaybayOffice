-- Settings persisted to SQLite; legacy config.json is imported once.
-- Explicit API keys are private local settings, excluded from input history.

local json = require("src.json")

local C = {}

C.FILE = "config.json"
C.PROVIDERS = { "openai", "anthropic", "xai" }
C.DEFAULT_MODELS = { openai = "gpt-5", anthropic = "claude-opus-5", xai = "grok-4.6" }
C.ENV = {
  openai = { "OPENAI_API_KEY" },
  anthropic = { "ANTHROPIC_API_KEY" },
  xai = { "XAI_API_KEY", "GROK_API_KEY" },
}

local function defaults()
  return {
    apiKeys = { openai = "", anthropic = "", xai = "" },
    defaultProvider = "openai",
    models = { openai = "", anthropic = "", xai = "" },
    keepaliveSeconds = 15,
    crt = true,
    bezel = true,
    barrel = false,
    retro = true, -- cool-retro-term stages: bloom, burn-in, noise, flicker, jitter
    phosphor = "amber", -- off | amber | green | white (tube colouring)
    maskIds = false, -- privacy for screen capture: ids/addresses drawn as ****
    fontScale = 1,
    termZoom = 1,
    keyClicks = false,
    sound = true,
    seenTermHint = false,
    lobbyView = "map2", -- map (Map 1) | map2 (Map 2)
    display = "window", -- window | fullscreen
    orientation = "auto", -- auto | landscape | portrait
    orientationFor = "", -- window shape a forced orientation was chosen for
  }
end

C.data = defaults()

local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      merge(dst[k], v)
    elseif type(dst[k]) == type(v) and type(v) ~= "table" then
      dst[k] = v
    end
  end
end

function C.load()
  C.data = defaults()
  local core = package.loaded["src.core"]
  local persistent = core and core.lib and not core.mock
  local raw = persistent and core.kvGet("ui.config") or ""
  local imported = raw == ""
  if imported then
    raw = love.filesystem.read(C.FILE)
  end
  if raw then
    local t = json.decode(raw)
    if type(t) == "table" then
      merge(C.data, t)
    end
  end
  local d = C.data
  if d.lobbyView ~= "map" then
    d.lobbyView = "map2"
  end
  if d.phosphor ~= "off" and d.phosphor ~= "green" and d.phosphor ~= "white" then
    d.phosphor = "amber"
  end
  if not C.DEFAULT_MODELS[d.defaultProvider] then
    d.defaultProvider = "openai"
  end
  d.keepaliveSeconds = math.max(0, math.min(300, d.keepaliveSeconds))
  d.fontScale = math.max(0.5, math.min(3, d.fontScale))
  d.termZoom = math.max(1, math.min(2, math.floor(d.termZoom)))
  if d.display ~= "fullscreen" then
    d.display = "window"
  end
  if d.orientation ~= "portrait" and d.orientation ~= "landscape" then
    d.orientation = "auto"
  end
  if d.orientationFor ~= "portrait" and d.orientationFor ~= "landscape" then
    d.orientationFor = ""
  end
  if persistent and imported then
    C.save()
  end
  return C.data
end

function C.save()
  local core = package.loaded["src.core"]
  if core and core.lib and not core.mock then
    local saved = core.kvSet("ui.config", json.encode(C.data))
    for _, provider in ipairs(C.PROVIDERS) do
      core.kvSet("apikey." .. provider, C.data.apiKeys[provider] or "")
    end
    if not saved then
      print("[config] SQLite save failed: " .. core.lastError())
    end
    return saved
  end
  local ok, err = require("src.storage").write(C.FILE, json.encode(C.data, true))
  if not ok then
    print("[config] save failed: " .. tostring(err))
  end
  return ok
end

function C.get()
  return C.data
end

-- Key from settings, else env var(s).
-- Privacy for screen capture (PRIVACY button / Settings): every user name,
-- host, address and port is drawn as stars; session and node names stay.
function C.private()
  return C.data.maskIds == true
end

function C.stars(s)
  s = tostring(s or "")
  if s == "" then
    return s
  end
  return string.rep("*", math.min(#s, 6))
end

-- "user@host[:port]" or its masked form.
function C.who(user, host, port)
  if C.private() then
    return "****@****" .. ((port and port ~= 22) and ":**" or "")
  end
  local s = (user or "") .. "@" .. (host or "")
  if port and port ~= 22 then
    s = s .. ":" .. tostring(port)
  end
  return s
end

-- A node's display name: the label if it has one, else the host, which is
-- masked in private mode so an address never doubles as the name.
function C.nodeName(host, rec)
  if rec and rec.name then
    return rec.name
  end
  if host.label and host.label ~= "" then
    return host.label
  end
  return C.private() and "****" or (host.host or "")
end

-- Paths shown in the chrome: the user's own name inside them is masked.
function C.hidePath(path, user, host)
  if not C.private() or not path then
    return path
  end
  for _, needle in ipairs({ user, host }) do
    if needle and needle ~= "" then
      path = path:gsub(needle:gsub("%W", "%%%0"), "****")
    end
  end
  return path
end

function C.apiKey(provider)
  local k = C.data.apiKeys and C.data.apiKeys[provider]
  if k and k ~= "" then
    return k, "settings"
  end
  for _, env in ipairs(C.ENV[provider] or {}) do
    local v = os.getenv(env)
    if v and v ~= "" then
      return v, env
    end
  end
  return "", nil
end

function C.model(provider)
  local m = C.data.models and C.data.models[provider]
  if m and m ~= "" then
    return m
  end
  return C.DEFAULT_MODELS[provider] or ""
end

-- "sk-abc…wxyz" style masking for the settings UI. Never reveals the middle.
function C.mask(key)
  if not key or key == "" then
    return "(not set)"
  end
  local n = #key
  if n <= 8 then
    return string.rep("*", n)
  end
  return key:sub(1, 3) .. string.rep("*", math.min(8, n - 7)) .. key:sub(-4)
end

function C.nextProvider(p)
  for i, name in ipairs(C.PROVIDERS) do
    if name == p then
      return C.PROVIDERS[(i % #C.PROVIDERS) + 1]
    end
  end
  return C.PROVIDERS[1]
end

return C
