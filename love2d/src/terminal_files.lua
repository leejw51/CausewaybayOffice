-- Literal paths from rendered terminal text. Never evaluates shell output.
local M = {}
function M.clean(text)
  if type(text) ~= "string" or text == "" or text:find("[%z\1-\31\127]") then
    return nil
  end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text:find("://", 1, true) or text == "->" then
    return nil
  end
  text = text:gsub(":%d+:%d+:?$", ""):gsub(":%d+:?$", "")
  if
    (text:sub(1, 1) == "'" and text:sub(-1) == "'")
    or (text:sub(1, 1) == '"' and text:sub(-1) == '"')
  then
    text = text:sub(2, -2)
  end
  return text ~= "" and text or nil
end
function M.resolve(cwd, filename)
  return M.resolveLiteral(cwd, M.clean(filename))
end
function M.resolveLiteral(cwd, path)
  if
    type(path) ~= "string"
    or path == ""
    or path:find("[%z\1-\31\127]")
    or path:find("://", 1, true)
  then
    return nil
  end
  if path:sub(1, 1) == "/" or path == "~" or path:sub(1, 2) == "~/" then
    return path
  end
  if not cwd or cwd == "" then
    return nil
  end
  return cwd:gsub("/+$", "") .. "/" .. path
end
function M.at(view, col, row)
  if not view.cells or row < 0 or row >= view.rows or col < 0 or col >= view.cols then
    return nil
  end
  local tokens, value, first, last, quote, escaped = {}, "", nil, nil, nil, false
  local function finish()
    if first then
      tokens[#tokens + 1] = { name = value, literal = value, first = first, last = last }
    end
    value, first, last, quote, escaped = "", nil, nil, nil, false
  end
  for x = 0, view.cols - 1 do
    local cell = view.cells[row * view.cols + x]
    if cell.width ~= 0 then
      local ch = cell.cp == 0 and " " or require("utf8").char(cell.cp)
      if not quote and not escaped and ch:match("%s") then
        finish()
      else
        first, last = first or x, x + math.max(1, tonumber(cell.width)) - 1
        if escaped then
          value, escaped = value .. ch, false
        elseif ch == "\\" and quote ~= "'" then
          escaped = true
        elseif quote then
          if ch == quote then
            quote = nil
          else
            value = value .. ch
          end
        elseif ch == "'" or ch == '"' then
          quote = ch
        else
          value = value .. ch
        end
      end
    end
  end
  finish()
  -- In ordinary `ls -l` output, the filename occupies the remainder of
  -- the row, so unquoted spaces belong to it rather than separate links.
  local mode = tokens[1] and tokens[1].literal or ""
  if #mode >= 10 and mode:match("^[dl][rwxstST%-]+[+@.]?$") then
    local firstName = tokens[6] and tokens[6].literal:match("^%d%d%d%d%-%d%d%-%d%d$") and 8 or 9
    local lastName = #tokens
    for i = firstName, lastName do
      if tokens[i].literal == "->" then
        lastName = i - 1
        break
      end
    end
    if tokens[firstName] and lastName >= firstName then
      local a, b = tokens[firstName], tokens[lastName]
      local nameLast = b.last
      -- A literal apostrophe in BSD output can leave the token lexer in
      -- quote mode. Do not include the terminal's blank row padding.
      while nameLast >= a.first do
        local cell = view.cells[row * view.cols + nameLast]
        if cell.width == 0 or (cell.cp ~= 0 and cell.cp ~= 32) then
          break
        end
        nameLast = nameLast - 1
      end
      if col >= a.first and col <= nameLast then
        local raw = {}
        for x = a.first, nameLast do
          local cell = view.cells[row * view.cols + x]
          if cell.width ~= 0 then
            raw[#raw + 1] = cell.cp == 0 and " " or require("utf8").char(cell.cp)
          end
        end
        local name = table.concat(raw)
        -- BSD ls prints apostrophes literally; GNU ls may quote the whole
        -- filename. Only apply shell unquoting to a wholly quoted name.
        if
          firstName == lastName
          and (
            (name:sub(1, 1) == "'" and name:sub(-1) == "'")
            or (name:sub(1, 1) == '"' and name:sub(-1) == '"')
          )
        then
          name = a.literal
        end
        return {
          name = M.clean(name),
          literal = name,
          first = a.first,
          last = nameLast,
          directory = mode:sub(1, 1) == "d",
        }
      end
    end
  end
  for _, token in ipairs(tokens) do
    if col >= token.first and col <= token.last then
      token.directory = token.literal:sub(-1) == "/"
      token.name = M.clean(token.name)
      return token.name and token or nil
    end
  end
end
return M
