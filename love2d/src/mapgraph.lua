-- World-map graph + walk maths (pure Lua, no drawing; tested in src/test.lua).
--   MG.load()                 -> { image, platforms = {{x,y}...} (0..1), adj = {i -> {j...}} }
--   MG.bfs(nodes, from, to)   -> { from, ..., to } or nil
--   MG.segmentDuration(len)   -> seconds (380 ms per 100 px, min 220 ms)
--   MG.walkDuration(points)   -> total seconds over a polyline
--   MG.facing(dx)             -> 1 (right) / -1 (left)
--   MG.bob(u, steps)          -> vertical bob in px for progress u (0..1)

local json = require("src.json")

local MG = {}

MG.FILE = "assets/map_nodes.json"
MG.PER_PAGE = 10 -- bundled map has ten selectable stages

-- Hand-made fallback: 8 platforms on a winding S-curve, chain adjacency.
function MG.fallback()
  local platforms = {
    { x = 0.10, y = 0.78 },
    { x = 0.24, y = 0.62 },
    { x = 0.38, y = 0.72 },
    { x = 0.50, y = 0.52 },
    { x = 0.62, y = 0.66 },
    { x = 0.74, y = 0.44 },
    { x = 0.86, y = 0.56 },
    { x = 0.92, y = 0.30 },
  }
  local paths = {}
  for i = 1, #platforms - 1 do
    paths[#paths + 1] = { i - 1, i }
  end
  return { image = "map_causeway", platforms = platforms, paths = paths, fallback = true }
end

local function normalize(raw)
  local nodes =
    { image = raw.image or "map_causeway", platforms = {}, paths = {}, fallback = raw.fallback }
  for i, p in ipairs(raw.platforms or {}) do
    nodes.platforms[i] = { x = tonumber(p.x) or 0.5, y = tonumber(p.y) or 0.5 }
  end
  for _, e in ipairs(raw.paths or {}) do
    local a, b = tonumber(e[1]), tonumber(e[2])
    if a and b then
      nodes.paths[#nodes.paths + 1] = { a, b }
    end
  end
  -- adjacency (1-based platform indices; the JSON uses 0-based pairs)
  nodes.adj = {}
  for i = 1, #nodes.platforms do
    nodes.adj[i] = {}
  end
  for _, e in ipairs(nodes.paths) do
    local a, b = e[1] + 1, e[2] + 1
    if nodes.adj[a] and nodes.adj[b] then
      nodes.adj[a][#nodes.adj[a] + 1] = b
      nodes.adj[b][#nodes.adj[b] + 1] = a
    end
  end
  return nodes
end

-- Loads assets/map_nodes.json when present and valid, else the fallback.
function MG.load(path)
  path = path or MG.FILE
  if love and love.filesystem and love.filesystem.getInfo(path) then
    local raw = love.filesystem.read(path)
    local t = raw and json.decode(raw)
    if type(t) == "table" and type(t.platforms) == "table" and #t.platforms >= 2 then
      return normalize(t)
    end
  end
  return normalize(MG.fallback())
end

-- Shortest path (in hops) through the adjacency graph.
function MG.bfs(nodes, from, to)
  if not nodes.adj[from] or not nodes.adj[to] then
    return nil
  end
  if from == to then
    return { from }
  end
  local prev = { [from] = from }
  local queue = { from }
  local head = 1
  while head <= #queue do
    local cur = queue[head]
    head = head + 1
    for _, nb in ipairs(nodes.adj[cur]) do
      if not prev[nb] then
        prev[nb] = cur
        if nb == to then
          local path = { to }
          local at = to
          while at ~= from do
            at = prev[at]
            table.insert(path, 1, at)
          end
          return path
        end
        queue[#queue + 1] = nb
      end
    end
  end
  return nil
end

-- 380 ms per 100 px, never shorter than 220 ms.
function MG.segmentDuration(len)
  return math.max(0.22, 0.38 * len / 100)
end

function MG.walkDuration(points)
  local total = 0
  for i = 2, #points do
    local dx, dy = points[i].x - points[i - 1].x, points[i].y - points[i - 1].y
    total = total + MG.segmentDuration(math.sqrt(dx * dx + dy * dy))
  end
  return total
end

function MG.facing(dx)
  if dx < 0 then
    return -1
  end
  return 1
end

-- Cosine-shaped vertical bob: y += sin(u * pi * steps) * 2 px.
function MG.bob(u, steps)
  return math.sin(u * math.pi * steps) * 2
end

-- Steps taken on a segment (one per ~16 px, at least 1).
function MG.steps(len)
  return math.max(1, math.floor(len / 16 + 0.5))
end

-- Platform assignment: hosts without a `platform` get the smallest unused
-- index in first-seen order; existing indices never move. Returns the hosts
-- table (mutated) and true when something changed.
function MG.assignPlatforms(hosts)
  local used = {}
  local changed = false
  for _, h in ipairs(hosts) do
    local p = h.platform
    if
      p ~= nil and (type(p) ~= "number" or p < 0 or p > 1000000 or p ~= math.floor(p) or used[p])
    then
      h.platform, changed = nil, true
    elseif p ~= nil then
      used[p] = true
    end
  end
  local pending = {}
  for _, h in ipairs(hosts) do
    if h.platform == nil then
      pending[#pending + 1] = h
    end
  end
  table.sort(pending, function(a, b)
    local fa, fb = a.firstSeen or a.lastUsed or 0, b.firstSeen or b.lastUsed or 0
    if fa == fb then
      return (a.host or "") < (b.host or "")
    end
    return fa < fb
  end)
  for _, h in ipairs(pending) do
    local i = 0
    while used[i] do
      i = i + 1
    end
    h.platform = i
    used[i] = true
    changed = true
  end
  return hosts, changed
end

function MG.page(platform)
  return math.floor(platform / MG.PER_PAGE)
end

function MG.slot(platform)
  return platform % MG.PER_PAGE
end

return MG
