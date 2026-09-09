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
  local path = M.clean(filename)
  if not path then
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
      tokens[#tokens + 1] = { name = value, first = first, last = last }
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
  for _, token in ipairs(tokens) do
    if col >= token.first and col <= token.last then
      token.name = M.clean(token.name)
      return token.name and token or nil
    end
  end
end
return M
