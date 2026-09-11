-- Small built-in bitmap alphabet: no subprocess, network, or font dependency.
local M = {}
local glyphs = {
  A = "01110/10001/11111/10001/10001",
  B = "11110/10001/11110/10001/11110",
  C = "01111/10000/10000/10000/01111",
  D = "11110/10001/10001/10001/11110",
  E = "11111/10000/11110/10000/11111",
  F = "11111/10000/11110/10000/10000",
  G = "01111/10000/10111/10001/01111",
  H = "10001/10001/11111/10001/10001",
  I = "11111/00100/00100/00100/11111",
  J = "00111/00010/00010/10010/01100",
  K = "10001/10010/11100/10010/10001",
  L = "10000/10000/10000/10000/11111",
  M = "10001/11011/10101/10001/10001",
  N = "10001/11001/10101/10011/10001",
  O = "01110/10001/10001/10001/01110",
  P = "11110/10001/11110/10000/10000",
  Q = "01110/10001/10101/10010/01101",
  R = "11110/10001/11110/10010/10001",
  S = "01111/10000/01110/00001/11110",
  T = "11111/00100/00100/00100/00100",
  U = "10001/10001/10001/10001/01110",
  V = "10001/10001/10001/01010/00100",
  W = "10001/10001/10101/11011/10001",
  X = "10001/01010/00100/01010/10001",
  Y = "10001/01010/00100/00100/00100",
  Z = "11111/00010/00100/01000/11111",
  ["0"] = "01110/10011/10101/11001/01110",
  ["1"] = "00100/01100/00100/00100/01110",
  ["2"] = "01110/10001/00010/00100/11111",
  ["3"] = "11110/00001/01110/00001/11110",
  ["4"] = "10010/10010/11111/00010/00010",
  ["5"] = "11111/10000/11110/00001/11110",
  ["6"] = "01110/10000/11110/10001/01110",
  ["7"] = "11111/00010/00100/01000/01000",
  ["8"] = "01110/10001/01110/10001/01110",
  ["9"] = "01110/10001/01111/00001/01110",
  ["!"] = "00100/00100/00100/00000/00100",
  ["?"] = "01110/10001/00110/00000/00100",
  ["-"] = "00000/00000/11111/00000/00000",
  ["."] = "00000/00000/00000/00000/00100",
}
function M.lines(text)
  local words = {}
  for word in text:gmatch("%S+") do
    words[#words + 1] = word:upper()
  end
  if #words == 0 or #words > 8 then
    return nil, "Enter 1 to 8 words for WORD ART"
  end
  if #text > 128 then
    return nil, "Keep WORD ART within 128 characters"
  end
  if text:find("[^%w%s!?.%-]") then
    return nil, "WORD ART supports English letters, numbers and ! ? . -"
  end
  local lines = {}
  for _, word in ipairs(words) do
    for start = 1, #word, 10 do
      local chunk = word:sub(start, start + 9)
      for row = 1, 5 do
        local parts = {}
        for ch in chunk:gmatch(".") do
          local pattern = glyphs[ch] or glyphs["?"]
          parts[#parts + 1] =
            pattern:sub((row - 1) * 6 + 1, (row - 1) * 6 + 5):gsub("1", "#"):gsub("0", " ")
        end
        lines[#lines + 1] = table.concat(parts, " ")
      end
      lines[#lines + 1] = ""
    end
  end
  return lines
end
function M.command(text)
  local lines, err = M.lines(text)
  if not lines then
    return nil, err
  end
  local args = {}
  for _, line in ipairs(lines) do
    args[#args + 1] = "'" .. line .. "'"
  end
  return "printf '%s\\n' " .. table.concat(args, " ")
end
return M
