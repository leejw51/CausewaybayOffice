-- AI side panel (lives inside the terminal scene). Provider mascots on top
-- (agent_openai / agent_claude / agent_grok), chat history, input box.
-- Streams deltas from Core.llmTakeDelta with a typewriter feel. Tab (or a
-- click on a mascot) switches provider, Enter sends, Ctrl+Enter reviews the
-- last answer to the session (only the fenced code blocks when there are
-- any), Esc cancels a running request. Reasoning models (gpt-5, grok-4.6)
-- send nothing for ~20 s before the first delta: while the request is
-- STREAMING with no text yet the panel shows a "thinking" bubble with the
-- elapsed seconds and the mascot bouncing.

local UI = require("src.ui")
local Config = require("src.config")

local AI = {}
AI.__index = AI

AI.SYSTEM =
  "You are a terse terminal sidekick for a developer working over ssh in Hong Kong. Answer with commands first."
AI.MASCOT = { openai = "agent_openai", anthropic = "agent_claude", xai = "agent_grok" }

function AI.new(app, sessionId)
  local p = setmetatable({}, AI)
  p.app = app
  p.sessionId = sessionId
  p.messages = {} -- {role, content, provider}
  p.input = UI.field("", "", {
    placeholder = "ask about this terminal",
    maxLen = 4000,
    historyKey = "ai.prompt",
    restore = true,
  })
  p.input.focused = true
  p.provider = Config.get().defaultProvider or "openai"
  if Config.apiKey(p.provider) == "" then
    for _, provider in ipairs(Config.PROVIDERS) do
      if Config.apiKey(provider) ~= "" then
        p.provider = provider
        break
      end
    end
  end
  p.req = nil
  p.tw = nil
  p.streamText = ""
  p.error = nil
  p.scroll = 0
  p.scrollTarget = 0
  p.rect = { x = 0, y = 0, w = 0, h = 0 }
  p.blink = 0
  p.mascotBtns = {}
  p.startedAt = 0
  return p
end

-- What Ctrl+Enter types into the terminal: the content of every fenced
-- ``` block (joined, each ending in a newline) when the answer has any,
-- else the whole text. A trailing newline is not added to plain text so a
-- command is not executed before the user has read it.
function AI.insertText(answer)
  if not answer or answer == "" then
    return ""
  end
  local blocks = {}
  for body in answer:gmatch("```[^\n]*\n(.-)```") do
    body = body:gsub("\r", "")
    if body ~= "" and not body:match("^%s*$") then
      if body:sub(-1) ~= "\n" then
        body = body .. "\n"
      end
      blocks[#blocks + 1] = body
    end
  end
  if #blocks > 0 then
    return table.concat(blocks)
  end
  return answer
end

-- True while a request is running and no text has arrived yet.
function AI:thinking()
  return self.req ~= nil and self.streamText == ""
end

function AI:elapsed()
  if not self.req then
    return 0
  end
  return love.timer.getTime() - self.startedAt
end

function AI:close()
  if self.req then
    self.app.core.llmCancel(self.req)
    self.app.core.llmFree(self.req)
    self.req = nil
  end
end

-- Cancel a running request; returns true if there was one.
function AI:cancel()
  if self.req then
    self.app.core.llmCancel(self.req)
    return true
  end
  return false
end

function AI:lastAnswer()
  for i = #self.messages, 1, -1 do
    if self.messages[i].role == "assistant" then
      return self.messages[i].content
    end
  end
  return nil
end

function AI:setProvider(p)
  if self.req then
    return
  end
  self.provider = p
  Config.get().defaultProvider = p
  Config.save()
  self.app.audio.play("click")
end

function AI:send()
  local text = self.input.value
  if text == "" or self.req then
    return
  end
  local app = self.app
  local key, src = Config.apiKey(self.provider)
  self.error = nil
  if key == "" and not app.core.mock then
    self.error = "no API key for "
      .. self.provider
      .. " (Ctrl+, to set, or "
      .. table.concat(Config.ENV[self.provider], "/")
      .. ")"
    app.audio.play("error")
    self.scrollTarget = math.huge
    return
  end
  local msgs = {}
  for _, m in ipairs(self.messages) do
    msgs[#msgs + 1] = { role = m.role, content = m.content }
  end
  msgs[#msgs + 1] = { role = "user", content = text }
  local req, err = app.core.llmStart({
    provider = self.provider,
    apiKey = key,
    model = Config.model(self.provider),
    system = AI.SYSTEM,
    messages = msgs,
  })
  if not req then
    self.error = err or "llm start failed"
    self.scrollTarget = math.huge
    app.audio.play("error")
    return
  end
  self.messages[#self.messages + 1] = { role = "user", content = text }
  self.input:remember()
  self.input.value = ""
  self.req = req
  self.keySource = src
  self.streamText = ""
  self.startedAt = love.timer.getTime()
  self.tw = app.fx.typewriter("", 240)
  self.scrollTarget = math.huge
end

function AI:update(dt)
  self.blink = self.blink + dt
  local app = self.app
  if self.req then
    local core = app.core
    local delta = core.llmTakeDelta(self.req)
    if delta ~= "" then
      self.streamText = self.streamText .. delta
      self.tw:append(delta)
      self.scrollTarget = math.huge
    end
    local st = core.llmState(self.req)
    if st == core.LLM.DONE or st == core.LLM.ERROR then
      -- The worker may have published its final bytes between the first drain
      -- and the state poll. Drain again before deciding to free the request.
      local tail = core.llmTakeDelta(self.req)
      if tail ~= "" then
        self.streamText = self.streamText .. tail
        self.tw:append(tail)
      end
      if st == core.LLM.ERROR then
        self.error = core.llmError(self.req)
        app.audio.play("error")
      end
      if self.tw.done or st == core.LLM.ERROR then
        if self.streamText ~= "" then
          self.messages[#self.messages + 1] =
            { role = "assistant", content = self.streamText, provider = self.provider }
        end
        core.llmFree(self.req)
        self.req = nil
        self.tw = nil
        self.streamText = ""
        app.audio.play("select")
      end
    end
  end
  if self.tw then
    self.tw:update(dt)
  end
  local maxScroll = math.max(0, (self.contentH or 0) - (self.viewH or 0))
  if self.scrollTarget == math.huge then
    self.scrollTarget = maxScroll
  elseif self.req and self.scrollTarget >= maxScroll - 1 then
    -- stick to the bottom while streaming unless the user scrolled up
    self.scrollTarget = math.huge
  end
  self.scrollTarget = math.max(0, math.min(self.scrollTarget, maxScroll))
  self.scroll = app.fx.approach(self.scroll, self.scrollTarget, dt, 14)
end

-- returns true when the key was consumed
function AI:keypressed(key, m)
  if key == "tab" then
    self:setProvider(Config.nextProvider(self.provider))
    return true
  elseif (key == "return" or key == "kpenter") and m.ctrl then
    local ans = AI.insertText(self:lastAnswer())
    if ans ~= "" and self.sessionId ~= nil then
      self.app.push("paste", { id = self.sessionId, text = ans, ai = true })
      self.app.fx.flash(0.15, 0.4, 0.86, 0.94, 0.25)
      self.app.audio.play("select")
    end
    return true
  elseif key == "return" or key == "kpenter" then
    self:send()
    return true
  elseif key == "pageup" then
    self.scrollTarget = math.max(0, self.scrollTarget - math.max(60, (self.viewH or 80) - 20))
    return true
  elseif key == "pagedown" then
    self.scrollTarget = self.scrollTarget + math.max(60, (self.viewH or 80) - 20)
    return true
  elseif key == "home" and m.ctrl then
    self.scrollTarget = 0
    return true
  elseif key == "end" and m.ctrl then
    self.scrollTarget = math.huge
    return true
  end
  return self.input:keypressed(key, m)
end

function AI:textinput(t)
  self.input:textinput(t)
end

function AI:hover(mx, my)
  if not mx then
    mx, my = self.app.D.toVirtual(love.mouse.getPosition())
  end
  local r = self.rect
  return UI.inside(mx, my, r.x, r.y, r.w, r.h)
end

function AI:wheelmoved(dy)
  self.scrollTarget = math.max(0, self.scrollTarget - dy * 24)
end

function AI:mousepressed(mx, my)
  if self.sendButton and UI.inside(mx, my, unpack(self.sendButton)) then
    if Config.apiKey(self.provider) == "" and not self.app.core.mock then
      local settings = self.app.push("settings")
      for i, row in ipairs(settings.rows) do
        if row.id == "key_" .. self.provider then
          settings.sel = i
          break
        end
      end
    else
      self:send()
    end
    return
  end
  for _, bt in ipairs(self.mascotBtns) do
    if UI.inside(mx, my, bt.x, bt.y, bt.w, bt.h) then
      self:setProvider(bt.provider)
      return
    end
  end
end

function AI:draw(x, y, w, h, t)
  local app = self.app
  local G, D = app.G, app.D
  self.rect.x, self.rect.y, self.rect.w, self.rect.h = x, y, w, h
  G.frame(x, y, w, h, 0.96)
  local pad = 10
  if w < 2 * pad + 40 or h < 2 * pad + 80 then
    return -- mid-slide: just the frame, the content needs room
  end

  -- provider row: three mascots, the active one bright (bobbing while streaming)
  local streaming = self.req ~= nil
  local thinking = self:thinking()
  self.mascotBtns = {}
  local mx = x + pad
  for _, prov in ipairs(Config.PROVIDERS) do
    local active = prov == self.provider
    local bob = 0
    if active and thinking then
      -- hop: 4px bounce on a 0.8 s loop while the model reasons
      bob = -math.floor(4 * math.abs(math.sin(t * math.pi / 0.8)) + 0.5)
    elseif active and streaming then
      bob = math.floor(2 * math.sin(t * math.pi * 2 / 1.6) + 0.5)
    end
    G.drawIcon(AI.MASCOT[prov], mx, y + pad - 2 + bob, 32, active and 1 or 0.35)
    if active then
      G.color("rust", 0.9)
      love.graphics.rectangle("fill", mx + 4, y + pad + 31, 24, 1)
    end
    self.mascotBtns[#self.mascotBtns + 1] = { x = mx, y = y + pad, w = 32, h = 32, provider = prov }
    mx = mx + 36
  end
  local narrow = w < 220
  local labelX, labelY = narrow and (x + pad) or (mx + 4), narrow and (y + 48) or (y + pad + 6)
  G.ui(self.provider:upper(), labelX, labelY, "yellow")
  local model = Config.model(self.provider)
  local modelX = narrow and (x + pad) or (mx + 4)
  local modelY = narrow and (y + 59) or (y + pad + 17)
  while G.uiWidth(model) > x + w - modelX - 12 and #model > 1 do
    model = model:sub(1, -2)
  end
  G.ui(model, modelX, modelY, "gray")
  local headerH = narrow and 74 or 50
  G.color("dblue", 0.6)
  love.graphics.rectangle("fill", x + pad, y + headerH - 4, w - pad * 2, 1)

  -- chat area
  local cx, cy, cw = x + pad, y + headerH, w - pad * 2
  local inputH = 24
  local ch = math.max(0, h - (cy - y) - inputH - 26)
  self.viewH = ch
  love.graphics.setScissor((D.ox + cx) * D.s, (D.oy + cy) * D.s, cw * D.s, ch * D.s)
  local yy = cy - math.floor(self.scroll)
  local total = 0
  local function bubble(role, text, provider)
    local isUser = role == "user"
    local lh = UI.wrapHeight(text, cw - 8)
    local bh = lh + 20
    if yy + bh >= cy - 200 and yy <= cy + ch + 200 then
      G.panel(cx, yy, cw, bh, isUser and "ink" or "black", isUser and "cyan" or "rust", 0.8)
      if isUser then
        G.ui("YOU", cx + 4, yy + 4, "cyan", 0.8)
      else
        G.drawIcon(AI.MASCOT[provider or self.provider], cx + 2, yy + 1, 16)
        G.ui((provider or self.provider):upper(), cx + 20, yy + 4, "rust", 0.8)
      end
      UI.wrapped(text, cx + 4, yy + 15, cw - 8, "white")
    end
    yy = yy + bh + 4
    total = total + bh + 4
  end
  for _, m in ipairs(self.messages) do
    bubble(m.role, m.content, m.provider)
  end
  if #self.messages == 0 and not self.req and not self.error then
    local key = Config.apiKey(self.provider)
    bubble(
      "assistant",
      key == ""
          and not app.core.mock
          and "Add your API key with the KEY button below, then ask a question."
        or "Ask a question below. Enter or SEND starts the AI response.",
      self.provider
    )
  end
  if self.req then
    local shown = self.tw and self.tw.text or ""
    if thinking then
      local dots = string.rep(".", 1 + math.floor(self.blink * 3) % 3)
      shown = string.format(
        "thinking%s  %ds   (Esc cancels)",
        dots .. string.rep(" ", 3 - #dots),
        math.floor(self:elapsed())
      )
    elseif math.floor(self.blink * 4) % 2 == 0 then
      shown = shown .. "▌"
    end
    bubble("assistant", shown, self.provider)
  end
  if self.error then
    bubble("assistant", "! " .. self.error, self.provider)
  end
  self.contentH = total
  love.graphics.setScissor()

  -- input + hints
  local iy = y + h - inputH - 20
  G.color("dblue", 0.6)
  love.graphics.rectangle("fill", x + pad, iy - 4, w - pad * 2, 1)
  local key = Config.apiKey(self.provider)
  local label = key == "" and not app.core.mock and "KEY" or "SEND"
  local bw = G.uiWidth(label) + 12
  self.input:draw(x + pad, iy, w - pad * 2 - bw - 4, t, 0)
  self.sendButton = { x + w - pad - bw, iy, bw, 20 }
  G.panel(self.sendButton[1], iy, bw, 20, "ink", "cyan")
  G.ui(label, self.sendButton[1] + 6, iy + 6, "yellow")
  UI.hints({
    { "Enter", "send" },
    { "^Enter", "review" },
    { "Tab", "provider" },
    { "PgUp/Dn", "scroll" },
    { "Esc", streaming and "cancel" or "close" },
  }, x + pad, y + h - 16, w - pad * 2)
end

return AI
