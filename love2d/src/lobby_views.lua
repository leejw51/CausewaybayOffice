-- Both lobby layouts share the same selector; the chosen layout is home.
local M = {}

function M.disconnect(app, buttons, rec, right, y, focus)
  local G = app.G
  local label = "DISCONNECT"
  local w = G.uiWidth(label) + 16
  local x = right - w
  local enabled = rec ~= nil and not rec.closing
  G.panel(x, y, w, 20, "ink", enabled and "rust" or "dgray")
  G.ui(label, x + 8, y + 6, enabled and "rust" or "dgray")
  buttons[#buttons + 1] = {
    id = "disconnect",
    x = x,
    y = y,
    w = w,
    h = 20,
    enabled = enabled,
    fn = function()
      if enabled then
        app.disconnectSession(rec, focus)
      end
    end,
  }
  return w
end

function M.draw(app, buttons, current, right, y)
  local G = app.G
  local w = G.uiWidth("MAP 1") + 14
  local x = right - w * 2 - 4
  for i, name in ipairs({ "map", "map2" }) do
    local bx = x + (i - 1) * (w + 4)
    local selected = current == name
    G.panel(bx, y, w, 20, selected and "dblue" or "ink", selected and "cyan" or "gray")
    G.ui("MAP " .. i, bx + 7, y + 6, selected and "white" or "gray")
    buttons[#buttons + 1] = {
      id = name,
      x = bx,
      y = y,
      w = w,
      h = 20,
      fn = function()
        app.switch(name)
      end,
    }
  end
end

return M
