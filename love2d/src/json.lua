-- Tiny JSON encode/decode (no external deps). Handles objects, arrays,
-- strings (with escapes and \uXXXX), numbers, booleans, null.

local J = {}

local esc = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function encodeString(s)
  return '"'
    .. s:gsub('[%c"\\]', function(c)
      return esc[c] or string.format("\\u%04x", c:byte())
    end)
    .. '"'
end

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
      return false
    end
    n = n + 1
  end
  return n == #t
end

local function encode(v, out, indent, depth)
  local tv = type(v)
  if tv == "nil" then
    out[#out + 1] = "null"
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      out[#out + 1] = "null"
    elseif math.floor(v) == v and math.abs(v) < 1e15 then
      out[#out + 1] = string.format("%d", v)
    else
      out[#out + 1] = string.format("%.14g", v)
    end
  elseif tv == "string" then
    out[#out + 1] = encodeString(v)
  elseif tv == "table" then
    local pad = indent and ("\n" .. string.rep("  ", depth + 1)) or ""
    local padEnd = indent and ("\n" .. string.rep("  ", depth)) or ""
    if isArray(v) then
      if #v == 0 then
        out[#out + 1] = "[]"
        return
      end
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then
          out[#out + 1] = ","
        end
        out[#out + 1] = pad
        encode(v[i], out, indent, depth + 1)
      end
      out[#out + 1] = padEnd .. "]"
    else
      local keys = {}
      for k in pairs(v) do
        keys[#keys + 1] = tostring(k)
      end
      table.sort(keys)
      if #keys == 0 then
        out[#out + 1] = "{}"
        return
      end
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then
          out[#out + 1] = ","
        end
        out[#out + 1] = pad .. encodeString(k) .. (indent and ": " or ":")
        encode(v[k], out, indent, depth + 1)
      end
      out[#out + 1] = padEnd .. "}"
    end
  else
    error("json: cannot encode " .. tv)
  end
end

function J.encode(v, pretty)
  local out = {}
  encode(v, out, pretty, 0)
  return table.concat(out)
end

-- Decoder ------------------------------------------------------------------

local function skip(s, i)
  local _, e = s:find("^[ \t\r\n]*", i)
  return e + 1
end

local decodeValue

local function utf8char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + math.floor(cp / 0x1000) % 0x40,
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  end
end

local unesc =
  { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local function decodeString(s, i)
  -- s:sub(i,i) == '"'
  local out = {}
  i = i + 1
  while true do
    local c = s:sub(i, i)
    if c == "" then
      error("json: unterminated string")
    elseif c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local n = s:sub(i + 1, i + 1)
      if n == "u" then
        local hex = s:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16) or 63
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
          local lo = tonumber(s:sub(i + 2, i + 5), 16) or 0
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          i = i + 6
        end
        out[#out + 1] = utf8char(cp)
      else
        out[#out + 1] = unesc[n] or n
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

function decodeValue(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local obj = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then
      return obj, i + 1
    end
    while true do
      i = skip(s, i)
      if s:sub(i, i) ~= '"' then
        error("json: expected key at " .. i)
      end
      local k
      k, i = decodeString(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then
        error("json: expected ':' at " .. i)
      end
      local v
      v, i = decodeValue(s, i + 1)
      obj[k] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "," then
        i = i + 1
      elseif d == "}" then
        return obj, i + 1
      else
        error("json: expected ',' or '}' at " .. i)
      end
    end
  elseif c == "[" then
    local arr = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then
      return arr, i + 1
    end
    while true do
      local v
      v, i = decodeValue(s, i)
      arr[#arr + 1] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "," then
        i = i + 1
      elseif d == "]" then
        return arr, i + 1
      else
        error("json: expected ',' or ']' at " .. i)
      end
    end
  elseif c == '"' then
    return decodeString(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if num and #num > 0 then
      return tonumber(num), i + #num
    end
    error("json: unexpected char '" .. c .. "' at " .. i)
  end
end

function J.decode(s)
  if type(s) ~= "string" then
    return nil, "not a string"
  end
  local ok, v = pcall(function()
    local val = decodeValue(s, 1)
    return val
  end)
  if ok then
    return v
  end
  return nil, v
end

return J
