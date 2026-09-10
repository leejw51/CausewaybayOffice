-- AI side panel (lives inside the terminal scene). Provider mascots on top
-- (agent_openai / agent_claude / agent_grok), chat history, input box.
-- Streams deltas from Core.llmTakeDelta with a typewriter feel. Tab (or a
-- click on a mascot) switches provider, Enter sends, Ctrl+Enter reviews the
-- last answer to the session (only the fenced code blocks when there are
-- any), Esc cancels a running request. Reasoning models (gpt-5, grok-4.6)
-- send nothing for ~20 s before the first delta: while the request is
-- STREAMING with no text yet the panel shows a "thinking" bubble with the
-- elapsed seconds and the mascot bouncing.
--
-- Every chat bubble carries COPY (clipboard) and X (drop it from the context
-- sent with the next question); CLEAR ALL empties the context.
--
-- Shift+Tab (or the NOTES / CHAT button) switches to note mode: whatever is
-- typed is saved to sqlite through the core (Core.noteAdd) and indexed for
-- BM25 at once and for semantic search in the background. PASTE saves the
-- clipboard as a new note without typing. Each note has COPY and X (delete).
-- FIND turns the input into a query: BM25 hits update as you type, Enter
-- runs the hybrid pass (vector search: local n-gram model offline, OpenAI
-- embeddings when indexing is on). READ opens a note full screen.
--
-- The notes feed the chat on their own: every question is searched against
-- them first and the best hits ride along in the system prompt ("+N notes"
-- on the bubble). AUTO NOTE (terminal bar) captures the screen, asks the
-- model for a short summary when a key exists, and saves both as a note;
-- without a key the capture itself becomes the note.

local UI = require("src.ui")
local Config = require("src.config")

local AI = {}
AI.__index = AI

AI.SYSTEM =
  "You are a terse terminal sidekick for a developer working over ssh in Hong Kong. Answer with commands first."
AI.MASCOT = { openai = "agent_openai", anthropic = "agent_claude", xai = "agent_grok" }
AI.NOTE_LIMIT = 200
AI.HIT_LIMIT = 50
AI.CONTEXT_NOTES = 5 -- notes attached to a chat question
AI.CONTEXT_CHARS = 600 -- per attached note
AI.CAPTURE_CHARS = 1500 -- screen text kept under an auto note summary
AI.AUTO_SYSTEM =
  "You turn a terminal screen into a short note for later search. State what was run, what happened, and every concrete fact worth finding again: paths, hosts, versions, ports, error messages. Plain text, at most 10 lines, no preamble."

function AI.new(app, sessionId)
  local p = setmetatable({}, AI)
  p.app = app
  p.sessionId = sessionId
  p.messages = {} -- {role, content, provider}
  p.chatInput = UI.field("", "", {
    placeholder = "ask about this terminal",
    maxLen = 4000,
    historyKey = "ai.prompt",
    restore = true,
  })
  p.noteInput = UI.field("", "", {
    placeholder = "write a note",
    maxLen = 4000,
    historyKey = "ai.note",
    restore = true,
  })
  p.input = p.chatInput
  p.input.focused = true
  p.mode = "chat" -- "chat" | "notes"
  p.notes = {} -- oldest first (drawn top to bottom, newest at the bottom)
  p.notesLoaded = false
  p.finding = false
  p.hits = {}
  p.lastQuery = nil
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
  p.headerBtns = {}
  p.bubbleBtns = {}
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
  if self.auto then
    self.app.core.llmCancel(self.auto.req)
    self.app.core.llmFree(self.auto.req)
    self.auto = nil
  end
end

-- Esc: cancel a running request (an auto note keeps its raw capture), else
-- leave note search. Returns true when the key was used up (the panel stays
-- open).
function AI:cancel()
  if self.req then
    self.app.core.llmCancel(self.req)
    return true
  end
  if self.auto then
    self.app.core.llmCancel(self.auto.req)
    return true
  end
  if self.mode == "notes" and self.finding then
    self:setFinding(false)
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

-- Clipboard + a short flash so the click is felt.
function AI:copyText(text)
  if not text or text == "" then
    return false
  end
  love.system.setClipboardText(text)
  self.app.fx.flash(0.15, 0.4, 0.86, 0.94, 0.25)
  self.app.audio.play("select")
  return true
end

-- ---- chat context ----------------------------------------------------------

-- Drop one message from the context (index into self.messages).
function AI:clearMessage(i)
  if not self.messages[i] then
    return false
  end
  table.remove(self.messages, i)
  self.app.audio.play("close")
  return true
end

function AI:clearAll()
  if #self.messages == 0 then
    return false
  end
  self.messages = {}
  self.error = nil
  self.scrollTarget = 0
  self.app.audio.play("close")
  self.app.fx.flash(0.1, 0.9, 0.5, 0.3, 0.2)
  return true
end

-- ---- notes -----------------------------------------------------------------

function AI:setMode(mode)
  if mode == self.mode then
    return
  end
  self.mode = mode
  self.input.focused = false
  self.input = mode == "notes" and self.noteInput or self.chatInput
  self.input.focused = true
  self.error = nil
  if mode == "notes" then
    self:loadNotes()
  end
  self.scrollTarget = math.huge
  self.app.audio.play("click")
end

function AI:toggleMode()
  self:setMode(self.mode == "chat" and "notes" or "chat")
end

-- Pull the newest notes from the core (newest first) into display order.
function AI:loadNotes()
  local rows = self.app.core.noteList(AI.NOTE_LIMIT)
  self.notes = {}
  for i = #rows, 1, -1 do
    self.notes[#self.notes + 1] = rows[i]
  end
  self.notesLoaded = true
  if self.finding then
    self:refreshHits(false)
  end
end

function AI:noteById(id)
  for _, n in ipairs(self.notes) do
    if n.id == id then
      return n
    end
  end
  return nil
end

-- Save `text` as a new note. Returns the note or nil, err.
function AI:addNote(text)
  local note, err = self.app.core.noteAdd(text, self.sessionId or 0)
  if not note then
    self.error = err or "could not save the note"
    self.app.audio.play("error")
    self.scrollTarget = math.huge
    return nil, self.error
  end
  self.error = nil
  self.notes[#self.notes + 1] = note
  self.scrollTarget = math.huge
  self.app.audio.play("select")
  self.app.fx.flash(0.1, 0.4, 0.86, 0.94, 0.2)
  if self.finding then
    self:refreshHits(false)
  end
  return note
end

-- PASTE: the clipboard becomes a note at once, nothing to type.
function AI:pasteNote()
  local clip = love.system.getClipboardText() or ""
  clip = clip:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("[%z\1-\8\11-\31\127]", "")
  if clip:match("^%s*$") then
    self.error = "clipboard is empty"
    self.app.audio.play("error")
    self.scrollTarget = math.huge
    return nil
  end
  return self:addNote(clip)
end

function AI:deleteNote(id)
  if not self.app.core.noteDelete(id) then
    self.error = "could not delete the note"
    self.app.audio.play("error")
    return false
  end
  for i = #self.notes, 1, -1 do
    if self.notes[i].id == id then
      table.remove(self.notes, i)
    end
  end
  for i = #self.hits, 1, -1 do
    if self.hits[i].id == id then
      table.remove(self.hits, i)
    end
  end
  self.app.audio.play("close")
  return true
end

function AI:setFinding(on)
  if on == self.finding then
    return
  end
  self.finding = on
  self.noteInput.placeholder = on and "search notes" or "write a note"
  self.hits = {}
  self.lastQuery = nil
  if on then
    self:refreshHits(false)
  end
  self.scrollTarget = on and 0 or math.huge
  self.app.audio.play("click")
end

-- BM25 as you type; `semantic` adds the embedding pass (Enter).
function AI:refreshHits(semantic)
  local q = self.noteInput.value
  self.lastQuery = q
  if q:match("^%s*$") then
    self.hits = {}
    return
  end
  self.hits = self.app.core.noteSearch(q, AI.HIT_LIMIT, semantic)
  self.scrollTarget = 0
end

-- Full text for a search hit (the core clips snippets; loaded notes are whole).
function AI:hitText(hit)
  local n = self:noteById(hit.id)
  return n and n.text or hit.snippet or hit.title or ""
end

-- Full-screen reader for one note.
function AI:read(note)
  self.app.push(
    "note",
    { id = note.id, text = note.text, ts_ms = note.ts_ms, sessionId = self.sessionId, panel = self }
  )
end

-- Enter in note mode.
function AI:submitNote()
  if self.finding then
    self:refreshHits(true)
    self.noteInput:remember()
    return
  end
  local text = self.noteInput.value
  if text:match("^%s*$") then
    return
  end
  if self:addNote(text) then
    self.noteInput:remember()
    self.noteInput.value = ""
  end
end

-- ---- notes -> chat context -------------------------------------------------

-- Best saved notes for a question (hybrid search), as texts.
function AI:notesFor(question)
  local out = {}
  for _, hit in ipairs(self.app.core.noteSearch(question, AI.CONTEXT_NOTES, true)) do
    local text = self:hitText(hit)
    if text ~= "" then
      if #text > AI.CONTEXT_CHARS then
        text = text:sub(1, AI.CONTEXT_CHARS) .. "…"
      end
      out[#out + 1] = text
    end
  end
  return out
end

-- System prompt with the notes appended; returns prompt, count.
function AI.systemWithNotes(notes)
  if not notes or #notes == 0 then
    return AI.SYSTEM, 0
  end
  local parts = {
    AI.SYSTEM,
    "",
    "Notes the user saved earlier. Use them when they apply; ignore them otherwise:",
  }
  for i, n in ipairs(notes) do
    parts[#parts + 1] = string.format("[note %d] %s", i, n)
  end
  return table.concat(parts, "\n"), #notes
end

-- ---- auto note -------------------------------------------------------------

-- Terminal capture -> note. With a key the model writes a summary first and
-- the clipped capture follows it; without one the capture is the note.
-- Returns "summarizing" while the request runs, the note when saved.
function AI:autoNote(capture, header)
  capture = (capture or ""):gsub("%s+$", "")
  if capture:match("^%s*$") then
    return nil, "nothing on screen to note"
  end
  header = header or "AUTO NOTE"
  self:setMode("notes")
  self:setFinding(false)
  local app = self.app
  local key = Config.apiKey(self.provider)
  if (key == "" and not app.core.mock) or self.auto then
    return self:addNote(header .. "\n" .. capture)
  end
  local req = app.core.llmStart({
    provider = self.provider,
    apiKey = key,
    model = Config.model(self.provider),
    system = AI.AUTO_SYSTEM,
    messages = { { role = "user", content = capture } },
  })
  if not req then
    return self:addNote(header .. "\n" .. capture)
  end
  self.auto =
    { req = req, text = "", header = header, capture = capture, startedAt = love.timer.getTime() }
  self.scrollTarget = math.huge
  app.audio.play("open")
  return "summarizing"
end

-- Poll the auto note request; save when it ends (raw capture on error/cancel).
function AI:updateAuto()
  local a = self.auto
  if not a then
    return
  end
  local core = self.app.core
  a.text = a.text .. core.llmTakeDelta(a.req)
  local st = core.llmState(a.req)
  if st ~= core.LLM.DONE and st ~= core.LLM.ERROR then
    return
  end
  a.text = a.text .. core.llmTakeDelta(a.req)
  core.llmFree(a.req)
  self.auto = nil
  local capture = a.capture
  if #capture > AI.CAPTURE_CHARS then
    capture = capture:sub(1, AI.CAPTURE_CHARS) .. "…"
  end
  local summary = a.text:gsub("^%s+", ""):gsub("%s+$", "")
  local body
  if summary == "" then
    body = a.header .. "\n" .. capture
  else
    body = a.header .. "\n" .. summary .. "\n\n--- screen ---\n" .. capture
  end
  self:addNote(body)
end

-- ---- chat ------------------------------------------------------------------

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
  local system, used = AI.systemWithNotes(self:notesFor(text))
  local req, err = app.core.llmStart({
    provider = self.provider,
    apiKey = key,
    model = Config.model(self.provider),
    system = system,
    messages = msgs,
  })
  if not req then
    self.error = err or "llm start failed"
    self.scrollTarget = math.huge
    app.audio.play("error")
    return
  end
  self.messages[#self.messages + 1] = { role = "user", content = text, notesUsed = used }
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
  self:updateAuto()
  if self.mode == "notes" and self.finding and self.noteInput.value ~= self.lastQuery then
    self:refreshHits(false)
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
  if key == "tab" and m.shift then
    self:toggleMode()
    return true
  elseif key == "tab" then
    self:setProvider(Config.nextProvider(self.provider))
    return true
  elseif (key == "return" or key == "kpenter") and m.ctrl then
    if self.mode ~= "chat" then
      return true
    end
    local ans = AI.insertText(self:lastAnswer())
    if ans ~= "" and self.sessionId ~= nil then
      self.app.push("paste", { id = self.sessionId, text = ans, ai = true })
      self.app.fx.flash(0.15, 0.4, 0.86, 0.94, 0.25)
      self.app.audio.play("select")
    end
    return true
  elseif key == "return" or key == "kpenter" then
    if self.mode == "notes" then
      self:submitNote()
    else
      self:send()
    end
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
  for _, bt in ipairs(self.headerBtns) do
    if UI.inside(mx, my, bt.x, bt.y, bt.w, bt.h) then
      bt.fn()
      return
    end
  end
  for _, bt in ipairs(self.bubbleBtns) do
    if UI.inside(mx, my, bt.x, bt.y, bt.w, bt.h) then
      bt.fn()
      return
    end
  end
  if self.pasteButton and UI.inside(mx, my, unpack(self.pasteButton)) then
    self:pasteNote()
    return
  end
  if self.sendButton and UI.inside(mx, my, unpack(self.sendButton)) then
    if self.mode == "notes" then
      self:submitNote()
    elseif Config.apiKey(self.provider) == "" and not self.app.core.mock then
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

local function stamp(ts_ms)
  if not ts_ms or ts_ms <= 0 then
    return ""
  end
  return os.date("%m-%d %H:%M", math.floor(ts_ms / 1000))
end

function AI:draw(x, y, w, h, t)
  local app = self.app
  local G, D = app.G, app.D
  self.rect.x, self.rect.y, self.rect.w, self.rect.h = x, y, w, h
  G.frame(x, y, w, h, 0.96)
  local pad = 10
  self.headerBtns, self.bubbleBtns = {}, {}
  self.pasteButton, self.sendButton = nil, nil
  if w < 2 * pad + 40 or h < 2 * pad + 80 then
    return -- mid-slide: just the frame, the content needs room
  end
  local notes = self.mode == "notes"

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
    local dim = notes and 0.25 or 0.35
    G.drawIcon(AI.MASCOT[prov], mx, y + pad - 2 + bob, 32, active and (notes and 0.6 or 1) or dim)
    if active then
      G.color("rust", 0.9)
      love.graphics.rectangle("fill", mx + 4, y + pad + 31, 24, 1)
    end
    self.mascotBtns[#self.mascotBtns + 1] = { x = mx, y = y + pad, w = 32, h = 32, provider = prov }
    mx = mx + 36
  end
  local narrow = w < 220

  -- header buttons, right aligned: mode switch, then CLEAR ALL / FIND
  local hb = {}
  if notes then
    hb[#hb + 1] = {
      "CHAT",
      function()
        self:setMode("chat")
      end,
    }
    hb[#hb + 1] = {
      "FIND",
      function()
        self:setFinding(not self.finding)
      end,
      self.finding,
    }
  else
    hb[#hb + 1] = {
      "NOTES",
      function()
        self:setMode("notes")
      end,
    }
    if #self.messages > 0 then
      hb[#hb + 1] = {
        "CLEAR ALL",
        function()
          self:clearAll()
        end,
      }
    end
  end
  local hy = narrow and (y + 46) or (y + pad + 2)
  local hx = x + w - pad
  for i = #hb, 1, -1 do
    local label, fn, lit = hb[i][1], hb[i][2], hb[i][3]
    local bw = G.uiWidth(label) + 10
    hx = hx - bw
    G.panel(hx, hy, bw, 16, lit and "dblue" or "ink", lit and "cyan" or "rust", 0.9)
    G.ui(label, hx + 5, hy + 4, lit and "cyan" or "yellow")
    self.headerBtns[#self.headerBtns + 1] = { x = hx, y = hy, w = bw, h = 16, fn = fn }
    hx = hx - 4
  end
  local hdrRight = hx -- text to the left must stop here

  local labelX, labelY = narrow and (x + pad) or (mx + 4), narrow and (y + 48) or (y + pad + 6)
  local title = notes and (self.finding and "NOTES  FIND" or "NOTES") or self.provider:upper()
  UI.label(title, labelX, labelY, math.max(20, hdrRight - labelX - 4), notes and "cyan" or "yellow")
  local sub
  if notes then
    local n = #self.notes
    if self.auto then
      sub = string.format(
        "auto note: summarizing the screen  %ds",
        math.floor(love.timer.getTime() - self.auto.startedAt)
      )
    else
      sub = self.finding and string.format("%d hit%s", #self.hits, #self.hits == 1 and "" or "s")
        or string.format("%d saved  Enter adds  PASTE saves the clipboard", n)
    end
  else
    sub = Config.model(self.provider)
  end
  local subX = narrow and (x + pad) or (mx + 4)
  local subY = narrow and (y + 66) or (y + pad + 17)
  local subRight = narrow and (x + w - pad) or (hdrRight - 4)
  sub = UI.fit(sub, math.max(20, subRight - subX))
  G.ui(sub, subX, subY, "gray")
  local headerH = narrow and 82 or 50
  G.color("dblue", 0.6)
  love.graphics.rectangle("fill", x + pad, y + headerH - 4, w - pad * 2, 1)

  -- chat area
  local cx, cy, cw = x + pad, y + headerH, w - pad * 2
  local inputH = 24
  local ch = math.max(0, h - (cy - y) - inputH - 26)
  self.viewH = ch
  love.graphics.push("all")
  UI.clip(cx, cy, cw, ch)
  local yy = cy - math.floor(self.scroll)
  local total = 0
  -- bubble buttons: {label, fn} drawn at the top right, only when the whole
  -- button row is inside the clip (so hidden rows cannot be clicked)
  -- returns the x where the buttons start (text must stop before it)
  local function drawButtons(by, btns)
    local bx = cx + cw - 4
    for i = #btns, 1, -1 do
      local label, fn = btns[i][1], btns[i][2]
      local bw = G.uiWidth(label) + 8
      bx = bx - bw
      G.panel(bx, by, bw, 14, "black", label == "X" and "lred" or "gray", 0.9)
      G.ui(label, bx + 4, by + 3, label == "X" and "lred" or "white", 0.9)
      if by >= cy and by + 14 <= cy + ch then
        self.bubbleBtns[#self.bubbleBtns + 1] = { x = bx, y = by, w = bw, h = 14, fn = fn }
      end
      bx = bx - 3
    end
    return bx
  end
  local function bubble(role, text, provider, btns, meta)
    local isUser = role == "user" or role == "note"
    local lh = UI.wrapHeight(text, cw - 8)
    local bh = lh + 20
    if yy + bh >= cy - 200 and yy <= cy + ch + 200 then
      local edge = isUser and "cyan" or "rust"
      if role == "note" then
        edge = "green"
      elseif role == "hit" then
        edge = "yellow"
      end
      G.panel(cx, yy, cw, bh, isUser and "ink" or "black", edge, 0.8)
      local stop = cx + cw - 4
      if btns then
        stop = drawButtons(yy + 2, btns) - 6
      end
      local function tag(label, col, tx)
        G.ui(label, tx, yy + 4, col, 0.8)
        if meta then
          local mx0 = tx + G.uiWidth(label) + 8
          if stop - mx0 > G.uiWidth("…") then
            G.ui(UI.fit(meta, stop - mx0), mx0, yy + 4, "gray", 0.8)
          end
        end
      end
      if role == "note" or role == "hit" then
        tag(role == "hit" and "HIT" or "NOTE", edge, cx + 4)
      elseif isUser then
        tag("YOU", "cyan", cx + 4)
      else
        G.drawIcon(AI.MASCOT[provider or self.provider], cx + 2, yy + 1, 16)
        tag((provider or self.provider):upper(), "rust", cx + 20)
      end
      UI.wrapped(text, cx + 4, yy + 15, cw - 8, "white")
    end
    yy = yy + bh + 4
    total = total + bh + 4
  end
  if notes then
    if self.finding then
      if self.noteInput.value:match("^%s*$") then
        bubble(
          "assistant",
          "Type to search your notes. Enter also runs the semantic pass.",
          self.provider
        )
      elseif #self.hits == 0 then
        bubble("assistant", "No note matches.", self.provider)
      end
      for _, hit in ipairs(self.hits) do
        local id = hit.id
        local text = self:hitText(hit)
        local src = hit.sources and table.concat(hit.sources, "+") or ""
        bubble("hit", text, nil, {
          {
            "READ",
            function()
              self:read({ id = id, text = text, ts_ms = hit.ts_ms })
            end,
          },
          {
            "COPY",
            function()
              self:copyText(text)
            end,
          },
          {
            "X",
            function()
              self:deleteNote(id)
            end,
          },
        }, stamp(hit.ts_ms) .. (src ~= "" and ("  " .. src) or ""))
      end
    else
      if #self.notes == 0 and not self.error then
        bubble(
          "assistant",
          "Write a note below and press Enter, or PASTE to save the clipboard. Notes are kept in the local database and searchable with FIND.",
          self.provider
        )
      end
      for _, n in ipairs(self.notes) do
        local id, text = n.id, n.text
        bubble("note", text, nil, {
          {
            "READ",
            function()
              self:read(n)
            end,
          },
          {
            "COPY",
            function()
              self:copyText(text)
            end,
          },
          {
            "X",
            function()
              self:deleteNote(id)
            end,
          },
        }, stamp(n.ts_ms))
      end
      if self.auto then
        local dots = string.rep(".", 1 + math.floor(self.blink * 3) % 3)
        bubble(
          "assistant",
          string.format(
            "writing the auto note%s  %ds   (Esc keeps the raw capture)",
            dots,
            math.floor(love.timer.getTime() - self.auto.startedAt)
          ),
          self.provider
        )
      end
    end
  else
    for i, m in ipairs(self.messages) do
      local content = m.content
      bubble(
        m.role,
        content,
        m.provider,
        {
          {
            "COPY",
            function()
              self:copyText(content)
            end,
          },
          {
            "X",
            function()
              self:clearMessage(i)
            end,
          },
        },
        m.notesUsed
            and m.notesUsed > 0
            and string.format("+%d note%s", m.notesUsed, m.notesUsed == 1 and "" or "s")
          or nil
      )
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
  end
  if self.error then
    bubble("assistant", "! " .. self.error, self.provider)
  end
  self.contentH = total
  love.graphics.pop()

  -- input + buttons + hints
  local iy = y + h - inputH - 20
  G.color("dblue", 0.6)
  love.graphics.rectangle("fill", x + pad, iy - 4, w - pad * 2, 1)
  local label
  if notes then
    label = self.finding and "FIND" or "ADD"
  else
    local key = Config.apiKey(self.provider)
    label = key == "" and not app.core.mock and "KEY" or "SEND"
  end
  local bw = G.uiWidth(label) + 12
  local right = x + w - pad
  self.sendButton = { right - bw, iy, bw, 20 }
  G.panel(self.sendButton[1], iy, bw, 20, "ink", "cyan")
  G.ui(label, self.sendButton[1] + 6, iy + 6, "yellow")
  local used = bw + 4
  if notes and not self.finding then
    local pw = G.uiWidth("PASTE") + 12
    self.pasteButton = { right - bw - 4 - pw, iy, pw, 20 }
    G.panel(self.pasteButton[1], iy, pw, 20, "ink", "green")
    G.ui("PASTE", self.pasteButton[1] + 6, iy + 6, "green")
    used = used + pw + 4
  end
  self.input:draw(x + pad, iy, w - pad * 2 - used, t, 0)
  if notes then
    UI.hints({
      { "Enter", self.finding and "search" or "add" },
      { "S-Tab", "chat" },
      { "PgUp/Dn", "scroll" },
      { "Esc", self.finding and "stop find" or "close" },
    }, x + pad, y + h - 16, w - pad * 2)
  else
    UI.hints({
      { "Enter", "send" },
      { "^Enter", "review" },
      { "Tab", "provider" },
      { "S-Tab", "notes" },
      { "Esc", streaming and "cancel" or "close" },
    }, x + pad, y + h - 16, w - pad * 2)
  end
end

return AI
