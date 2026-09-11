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
-- sent with the next question); CLEAR empties the context.
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
--
-- Tools (src/tools.lua): the request carries the enabled tools; when the
-- model answers with function calls the panel runs them one by one (a
-- command waits for RUN / SKIP unless AUTO RUN is on), appends the results
-- and asks again, up to AI.MAX_TOOL_ROUNDS per question. define_tool adds a
-- harness live: the next request already has it, and the panel says so.
--
-- Body text is drawn at the terminal's glyph size (cfg.aiTermFont). Fenced
-- code blocks get COPY, RUN (review, then paste into the shell) and
-- PRACTICE: the block is shown line by line in a local input field; what
-- is typed is matched against the current line and the panel advances on Enter. Ctrl+Shift+Space moves the keyboard between the
-- chat input and the terminal while the panel is open (TERM / CHAT button).
--
-- MCP: text pushed by Claude Code (office_send) shows as an MCP bubble,
-- office_practice starts a practice, office_type opens the review sheet.

local UI = require("src.ui")
local Config = require("src.config")
local Tools = require("src.tools")

local AI = {}
AI.__index = AI

AI.SYSTEM =
  "You are a coding agent in an SSH terminal. Be concise and complete the user's requested work."
AI.MASCOT = { openai = "agent_openai", anthropic = "agent_claude", xai = "agent_grok" }
AI.TOOL_GUIDE = table.concat({
  "You can call tools. read_screen shows the user's terminal; use it before answering questions about what is on screen.",
  "run_command types one command into the terminal (the user approves it) and returns the screen.",
  "When asked to write, build or create a program, implement it in the connected terminal and run it, unless the user explicitly asks only for an explanation or code sample. Do not stop at a fenced code block.",
  "Inspect pwd, existing files and available compilers first with run_command. Use write_file for exact source text. Choose a fresh project folder for a new example and preserve unrelated files. Prefer minimal dependencies; a Rust Hello World can use rustc directly.",
  "Compile and execute with run_command, read the result, and fix errors before finishing. Include a short summary in each run_command to explain the current step. Report paths and observed output; never claim success without a successful result.",
  "Stay inside the task workspace and its subfolders. Outside file operations and all unrestricted shell commands require explicit per-operation approval. Do not bypass a denied operation using another tool, symlinks, scripts, or a different command. CODE can automatically write files inside the workspace; it does not grant outside access. The confined file writer requires python3 on the SSH host; if unavailable, explain the failure and request approval before using an unrestricted alternative.",
  "search_notes / save_note use the user's local notes. define_tool creates a reusable command tool with {param} placeholders when the user asks for a new harness; remove_tool deletes one.",
  "Put every command or code sample in a fenced ``` block: the panel adds RUN and PRACTICE buttons to those. Keep answers short.",
}, " ")
AI.MAX_TOOL_ROUNDS = 6
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
    placeholder = "ask, or paste code (Shift+Enter: new line)",
    maxLen = 8000,
    historyKey = "ai.prompt",
    restore = true,
    multiline = true,
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
  p.focusTerm = false -- keyboard goes to the terminal while the panel is open
  p.practice = nil -- coding practice: {title, lines, i, typed, errors, done}
  p.mcpPending = {}
  p.toolJob = nil -- {call, job} running now
  p.toolQueue = {} -- calls of the current turn still to run
  p.toolRounds = 0
  p.turnTools = nil
  p.turnSystem = AI.SYSTEM
  p.harnessNote = nil -- "harness updated" notice, drawn until the next answer
  if not Tools.loaded then
    Tools.load(app.core)
  end
  return p
end

-- ---- text scale: chat body at the terminal's glyph size ---------------------

-- Virtual px per terminal-font px: the grid is drawn at D.termZoom screen px
-- per glyph px, the chrome at D.s, so one 16 px Unifont line covers
-- 16*zoom/s virtual px. cfg.aiTermFont = false keeps the old UI scale (1).
function AI:textScale()
  if Config.get().aiTermFont == false then
    return 1
  end
  local D = self.app.D
  return math.max(0.25, (D.termZoom or 1) / (D.s or 1))
end

-- Body text is drawn in *screen* space, the way term_view draws the grid:
-- Unifont at its native 16 px, scaled only by the whole-number terminal
-- zoom. Scaling a 16 px bitmap face by a fraction (0.5 at the default UI
-- scale) would resample every stem and the text would turn to mush, so the
-- transform is reset instead and the glyphs land on the same pixel grid as
-- the terminal's own. Returns the wrap width in font units.
function AI:pushBodySpace(vx, vy, vwidth)
  local app = self.app
  local D, fx = app.D, app.fx
  local zoom = Config.get().aiTermFont == false and D.s or (D.termZoom or 1)
  love.graphics.push()
  love.graphics.origin()
  love.graphics.translate(
    math.floor((D.ox + fx.shakeX + vx) * D.s),
    math.floor((D.oy + fx.shakeY + vy) * D.s)
  )
  love.graphics.scale(zoom, zoom)
  love.graphics.setFont(app.G.fontTerm)
  return math.max(8, math.floor((vwidth or 0) * D.s / zoom))
end

-- Wrapped body text at (vx, vy), `vwidth` wide, both in virtual px.
function AI:bodyText(text, vx, vy, vwidth, col, a)
  local wrap = self:pushBodySpace(vx, vy, vwidth)
  self.app.G.color(col or "white", a)
  love.graphics.printf(text, 0, 0, wrap, "left")
  love.graphics.pop()
end

-- One unwrapped line; returns its width in virtual px (for the caret and
-- the practice colouring).
function AI:bodyLine(text, vx, vy, col, a)
  self:pushBodySpace(vx, vy, 0)
  self.app.G.color(col or "white", a)
  love.graphics.print(text, 0, 0)
  love.graphics.pop()
  return self:bodyWidth(text)
end

function AI:bodyWidth(text)
  return self.app.G.fontTerm:getWidth(text) * self:textScale()
end

-- ---- markdown-ish segments --------------------------------------------------

-- Split an answer into {kind = "text" | "code", text, lang} pieces on ```
-- fences. An unclosed fence runs to the end (while streaming).
function AI.segments(text)
  local out = {}
  text = (text or ""):gsub("\r", "")
  local pos = 1
  while true do
    local a, b, lang = text:find("```([^\n]*)\n", pos)
    if not a then
      break
    end
    if a > pos then
      out[#out + 1] = { kind = "text", text = text:sub(pos, a - 1) }
    end
    local c, d = text:find("\n```", b)
    local body
    if c then
      body = text:sub(b + 1, c - 1)
      pos = d + 1
    else
      body = text:sub(b + 1)
      pos = #text + 1
    end
    if body ~= "" and not body:match("^%s*$") then
      out[#out + 1] = { kind = "code", text = body, lang = lang:match("^%s*(%S*)") or "" }
    end
    if not c then
      break
    end
  end
  if pos <= #text then
    local tail = text:sub(pos)
    if not tail:match("^%s*$") or #out == 0 then
      out[#out + 1] = { kind = "text", text = tail }
    end
  end
  -- trim blank edges of text segments (the fences carried the newlines)
  for _, seg in ipairs(out) do
    if seg.kind == "text" then
      seg.text = seg.text:gsub("^\n+", ""):gsub("%s+$", "")
    end
  end
  local kept = {}
  for _, seg in ipairs(out) do
    if seg.kind == "code" or seg.text ~= "" then
      kept[#kept + 1] = seg
    end
  end
  return kept
end

-- ---- keyboard focus ---------------------------------------------------------

function AI:setFocus(term)
  term = term and true or false
  if term == self.focusTerm then
    return
  end
  self.focusTerm = term
  self.input.focused = not term
  self.app.audio.play("click")
end

function AI:toggleFocus()
  self:setFocus(not self.focusTerm)
end

-- ---- coding practice --------------------------------------------------------

-- Lines worth typing: blank lines dropped, trailing spaces trimmed.
function AI.practiceLines(code)
  local lines = {}
  for line in ((code or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("%s+$", "")
    if line ~= "" then
      lines[#lines + 1] = line
    end
  end
  return lines
end

function AI:startPractice(code, title)
  local lines = AI.practiceLines((code or ""):gsub("\t", "    "))
  if #lines == 0 then
    self.app.toast("Nothing to practice")
    return false
  end
  self:setMode("chat")
  self.practice = {
    title = title or "PRACTICE",
    code = code,
    lines = lines,
    i = 1,
    typed = "",
    errors = 0,
    done = false,
    scroll = 0,
    field = UI.field("", "", { maxLen = 200000, placeholder = "Type the highlighted line here" }),
    startedAt = love.timer.getTime(),
  }
  self.input.focused = false
  self.input = self.practice.field
  self.focusTerm = true -- force the focus refresh for the new field
  self:setFocus(false)
  self.scrollTarget = 0
  self.app.toast("Practice here. Enter checks your typing; Run opens a review.")
  return true
end

function AI:stopPractice()
  if not self.practice then
    return
  end
  self.input.focused = false
  self.practice = nil
  self.input = self.mode == "notes" and self.noteInput or self.chatInput
  self.focusTerm = true
  self:setFocus(false)
end

function AI:practiceSkip()
  local p = self.practice
  if not p or p.done then
    return
  end
  p.i, p.typed, p.field.value, p.scroll = p.i + 1, "", "", 0
  p.field.selectAll = false
  if p.i > #p.lines then
    self:practiceFinish()
  end
end

function AI:practiceFinish()
  local p = self.practice
  p.done = true
  p.finishedAt = love.timer.getTime()
  p.field.focused = false
  self.input = self.chatInput
  self.focusTerm = true
  self:setFocus(false)
  self.app.audio.play("select")
  self.app.toast("Practice complete. Back to chat; Run is optional.")
end

function AI:practiceCheck()
  local p = self.practice
  if not p or p.done then
    return
  end
  p.typed = p.field.value
  if p.typed:gsub("%s+$", "") == p.lines[p.i] then
    self:practiceSkip()
  else
    p.errors = p.errors + 1
    p.field.selectAll = true
    self.app.audio.play("error")
    self.app.toast("Not quite. Edit the line or type again. Nothing was sent to the terminal.")
  end
end

-- Local practice input only. Terminal writes never enter this path.
function AI:practiceInput(bytes)
  local p = self.practice
  if not p or p.done then
    return
  end
  for ch in bytes:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if ch == "\r" or ch == "\n" then
      self:practiceCheck()
      if p.done then
        return
      end
    elseif ch == "\127" or ch == "\8" then
      p.field:backspace()
    elseif ch == "\21" then
      p.field.value = ""
    elseif ch:byte() >= 32 then
      p.field:textinput(ch)
    end
    p.typed = p.field.value
  end
end

-- Matched prefix length (bytes) of what was typed against the current line.
function AI.practiceMatch(typed, line)
  local n = 0
  for pos, cp in require("utf8").codes(typed) do
    local ch = require("utf8").char(cp)
    if line:sub(pos, pos + #ch - 1) ~= ch then
      break
    end
    n = pos + #ch - 1
  end
  return n
end

-- ---- MCP inbox --------------------------------------------------------------

-- An item pushed by an MCP client (Claude Code): send -> bubble, practice ->
-- practice + bubble, type -> review sheet + bubble.
function AI:mcpDeliver(item)
  if self:busy() then
    self.mcpPending[#self.mcpPending + 1] = item
    return
  end
  local kind, text = item.kind or "send", item.text or ""
  local title = item.title
  if kind == "practice" then
    self.messages[#self.messages + 1] = {
      role = "assistant",
      provider = "mcp",
      content = (title and (title .. "\n") or "") .. "```\n" .. text .. "\n```",
      mcp = true,
    }
    self:startPractice(text, title)
  elseif kind == "type" then
    self.messages[#self.messages + 1] = {
      role = "assistant",
      provider = "mcp",
      content = "Terminal input proposed (review it):\n```\n" .. text .. "\n```",
      mcp = true,
    }
    if self.sessionId ~= nil then
      self.app.push("paste", { id = self.sessionId, text = text, ai = true })
    end
  else
    self.messages[#self.messages + 1] = {
      role = "assistant",
      provider = "mcp",
      content = (title and (title .. "\n") or "") .. text,
      mcp = true,
    }
  end
  self:setMode("chat")
  self.scrollTarget = math.huge
  self.app.audio.play("open")
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

-- A tool loop is in progress (request, running job or calls queued).
function AI:busy()
  return self.req ~= nil or self.toolJob ~= nil or #self.toolQueue > 0
end

-- Coding is an explicit, session-local choice. Access reviews remain mandatory.
function AI:toggleCoding()
  self.coding = not self.coding
  if self.coding then
    Config.get().aiTools = true
    if self.toolJob and not self.toolJob.job.accessReason then
      self:approveTool()
    end
  end
  self.app.toast(
    self.coding and "Code mode: write in the workspace. Outside access still needs approval."
      or "Review mode: approve each new terminal operation with RUN."
  )
end

function AI:activity()
  local job = self.toolJob and self.toolJob.job
  if job then
    if job.needsApproval then
      return job.accessReason and "ALLOW: outside access for this step"
        or "Waiting for RUN — terminal has not started"
    elseif job.kind == "write_file" then
      return string.format(
        "Writing %s · %d/%d steps",
        job.path:match("[^/]+$") or job.path,
        job.index,
        #job.commands
      )
    end
    return string.format(
      "%s · %ds",
      job.summary or ("Running " .. (job.command or "command")),
      math.floor(job.t or 0)
    )
  elseif self.req then
    return self.toolRounds > 0 and "Reading results and preparing the next step…"
      or "Planning the task and preparing terminal actions…"
  elseif self.error then
    return "Needs attention: " .. self.error
  end
  return self.activityNote
    or (
      self.coding and "Code mode · ready to write and run"
      or "Review mode · RUN approves terminal actions"
    )
end

function AI:elapsed()
  if not self.req then
    return 0
  end
  return love.timer.getTime() - self.startedAt
end

function AI:close()
  self:abortTools()
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
  if self:busy() then
    self.activityNote = "Stopped · send a follow-up to continue"
  end
  if self.req then
    self.app.core.llmCancel(self.req)
    self.app.core.llmFree(self.req)
    self.req, self.tw, self.streamText = nil, nil, ""
    self:abortTools()
    return true
  end
  if self.toolJob or #self.toolQueue > 0 then
    self:abortTools()
    self.app.audio.play("close")
    return true
  end
  if self.practice then
    self:stopPractice()
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

-- The AGI page (tools / keys / playground / mcp) for this session.
function AI:openAgi(tab)
  if self.app.hasOverlay("agi") then
    return
  end
  self.app.push("agi", { tab = tab or "tools", sessionId = self.sessionId, panel = self })
end

function AI:setProvider(p)
  if self:busy() then
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
  if self:busy() then
    self:cancel()
  end
  self.messages = {}
  self.error = nil
  self.harnessNote = nil
  self.scrollTarget = 0
  self.followBottom = false
  self.app.audio.play("close")
  self.app.fx.flash(0.1, 0.9, 0.5, 0.3, 0.2)
  return true
end

-- ---- notes -----------------------------------------------------------------

function AI:setMode(mode)
  if mode == self.mode then
    return
  end
  if self.practice then
    self:stopPractice()
  end
  self:setFocus(false)
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

-- The tools sent with a question (nil when tools are off).
function AI:toolList()
  if Config.get().aiTools == false then
    return nil
  end
  local list = Tools.forLlm()
  return #list > 0 and list or nil
end

-- Tool context for src/tools.lua: the terminal scene of this session (when
-- it is on screen) provides the screen text and the write.
function AI:ctx()
  local app, id = self.app, self.sessionId
  local scene = app.scene
  local term = scene and scene.name == "terminal" and scene.id == id and scene or nil
  local record = app.sessions.get(id)
  return {
    core = app.core,
    sessionId = id,
    autoRun = self.coding == true or Config.get().aiAutoRun == true,
    restrictWorkspace = true,
    workspace = self.workspaceRoot,
    cwd = function()
      return id ~= nil and app.core.cwd(id) or ""
    end,
    screenText = function()
      return term and term:screenText() or ""
    end,
    write = term and function(bytes)
      if
        term.id ~= id
        or app.sessions.get(id) ~= record
        or app.core.state(id) ~= app.core.ST.CONNECTED
      then
        return false
      end
      term:write(bytes)
      return true
    end or nil,
    generation = function()
      return id ~= nil and app.core.generation(id) or 0
    end,
    onNote = function(note)
      if self.notesLoaded then
        self.notes[#self.notes + 1] = note
      end
    end,
    onTools = function()
      self:harnessChanged()
    end,
  }
end

-- A tool was defined or removed: the registry is already saved and the next
-- request carries it. Tell the user, no relaunch needed.
function AI:harnessChanged()
  local n = #Tools.user
  self.harnessNote = string.format(
    "%d custom tool%s live (%d total). Manage them in SETUP.",
    n,
    n == 1 and "" or "s",
    #Tools.all()
  )
  self.app.toast("Harness updated live: " .. #Tools.all() .. " tools ready")
  self.app.fx.flash(0.15, 0.9, 0.5, 0.3, 0.2)
  self.app.audio.play("select")
end

-- Messages for the provider: a tool result must follow the assistant call it
-- answers, so calls without results (dropped with X) become plain text and
-- orphan results are left out. MCP bubbles ride along as assistant text.
function AI.sanitize(messages)
  local out = {}
  local i = 1
  while i <= #messages do
    local m = messages[i]
    if m.role == "assistant" and m.tool_calls and #m.tool_calls > 0 then
      local results, j = {}, i + 1
      while j <= #messages and messages[j].role == "tool" do
        results[messages[j].tool_call_id or ""] = messages[j]
        j = j + 1
      end
      local complete = true
      for _, c in ipairs(m.tool_calls) do
        if not results[c.id] then
          complete = false
        end
      end
      if complete then
        local calls = {}
        for _, c in ipairs(m.tool_calls) do
          calls[#calls + 1] = { id = c.id, name = c.name, arguments = c.arguments or "{}" }
        end
        out[#out + 1] = { role = "assistant", content = m.content or "", tool_calls = calls }
        for _, c in ipairs(m.tool_calls) do
          local r = results[c.id]
          out[#out + 1] =
            { role = "tool", tool_call_id = c.id, name = c.name, content = r.content or "" }
        end
      elseif (m.content or "") ~= "" then
        out[#out + 1] = { role = "assistant", content = m.content }
      end
      i = j
    elseif m.role == "tool" then
      i = i + 1 -- orphan result
    else
      out[#out + 1] = { role = m.role, content = m.content or "" }
      i = i + 1
    end
  end
  return out
end

-- Start a request for the current context (question, or tool results).
function AI:request()
  local app = self.app
  local key, src = Config.apiKey(self.provider)
  local req, err = app.core.llmStart({
    provider = self.provider,
    apiKey = key,
    model = Config.model(self.provider),
    system = self.turnSystem,
    messages = AI.sanitize(self.messages),
    tools = self.toolRounds < AI.MAX_TOOL_ROUNDS and self:toolList() or nil,
  })
  if not req then
    self.error = err or "llm start failed"
    self.scrollTarget = math.huge
    app.audio.play("error")
    return false
  end
  self.req = req
  self.keySource = src
  self.streamText = ""
  self.startedAt = love.timer.getTime()
  self.tw = app.fx.typewriter("", 240)
  self.scrollTarget = math.huge
  self.followBottom = true
  return true
end

function AI:send()
  local text = self.input.value:gsub("%s+$", "")
  if text == "" or self:busy() then
    return
  end
  local app = self.app
  local key = Config.apiKey(self.provider)
  self.error = nil
  self.activityNote = nil
  self.workspaceRoot = self.sessionId ~= nil and Tools.normalizePath(app.core.cwd(self.sessionId))
    or nil
  if key == "" and not app.core.mock then
    self.error = "no API key for "
      .. self.provider
      .. " (KEY button, Ctrl+, or "
      .. table.concat(Config.ENV[self.provider], "/")
      .. ")"
    app.audio.play("error")
    self.scrollTarget = math.huge
    self:openAgi("keys")
    return
  end
  local system, used = AI.systemWithNotes(self:notesFor(text))
  self.turnTools = self:toolList()
  if self.turnTools then
    system = system .. "\n\n" .. AI.TOOL_GUIDE
    local cwd = self.sessionId ~= nil and app.core.cwd(self.sessionId) or ""
    system = system
      .. "\nTask workspace (fixed for this turn): "
      .. (cwd ~= "" and cwd or "unknown; use pwd")
  end
  self.turnSystem = system
  self.toolRounds = 0
  self.harnessNote = nil
  self.messages[#self.messages + 1] = { role = "user", content = text, notesUsed = used }
  if not self:request() then
    self.messages[#self.messages] = nil
    return
  end
  self.input:remember()
  self.input.value = ""
end

-- ---- tool loop --------------------------------------------------------------

function AI:abortTools()
  if self.toolJob then
    local j = self.toolJob.job
    if j.cancel and not j.done then
      j:cancel()
    end
    self:toolResult(
      self.toolJob.call,
      j.started and "Cancelled; the command may have run partially." or "Cancelled before running."
    )
    self.toolJob = nil
  end
  for _, call in ipairs(self.toolQueue) do
    self:toolResult(call, "Cancelled before running.")
  end
  self.toolQueue = {}
end

-- Append the result of one call and move on.
function AI:toolResult(call, result)
  self.messages[#self.messages + 1] =
    { role = "tool", tool_call_id = call.id, name = call.name, content = result or "" }
  self.scrollTarget = math.huge
  self.followBottom = true
end

-- Run queued calls; immediate ones resolve here, a command waits in toolJob.
function AI:nextTool()
  while #self.toolQueue > 0 and not self.toolJob do
    local call = table.remove(self.toolQueue, 1)
    local job = Config.get().aiTools == false
        and { done = true, result = "Tools are disabled by the user. This call was not run." }
      or Tools.run(call.name, call.args, self:ctx())
    if job.done then
      self:toolResult(call, job.result)
    else
      self.toolJob = { call = call, job = job }
      self.followBottom = true
      if job.needsApproval then
        self.app.audio.play("open")
      end
    end
  end
  if #self.toolQueue == 0 and not self.toolJob then
    self:continueTurn()
  end
end

-- Every call answered: ask the model again with the results.
function AI:continueTurn()
  self.toolRounds = self.toolRounds + 1
  if self.toolRounds > AI.MAX_TOOL_ROUNDS then
    self.error = "tool loop stopped after " .. AI.MAX_TOOL_ROUNDS .. " rounds"
    self.app.audio.play("error")
    return
  end
  self:request()
end

function AI:approveTool()
  local t = self.toolJob
  if t and t.job.needsApproval then
    t.job:approve()
    self.app.audio.play("select")
  end
end

function AI:denyTool()
  local t = self.toolJob
  if t and t.job.needsApproval then
    t.job:deny()
  end
end

function AI:updateTools(dt)
  local t = self.toolJob
  if not t then
    return
  end
  t.job:update(dt)
  if t.job.done then
    self.toolJob = nil
    self:toolResult(t.call, t.job.result)
    self:nextTool()
  end
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
      local calls = st == core.LLM.DONE and core.llmTakeCalls(self.req) or {}
      if self.toolRounds >= AI.MAX_TOOL_ROUNDS and #calls > 0 then
        calls = {}
        self.error = "Tool limit reached. Ask a follow-up to continue."
      end
      if #calls > 0 then
        -- a tool turn: keep the text (if any) with the calls and run them
        self.messages[#self.messages + 1] = {
          role = "assistant",
          content = self.streamText,
          provider = self.provider,
          tool_calls = calls,
        }
        core.llmFree(self.req)
        self.req = nil
        self.tw = nil
        self.streamText = ""
        -- Queue consumption must not remove the calls from conversation history.
        self.toolQueue = {}
        for i, call in ipairs(calls) do
          self.toolQueue[i] = call
        end
        self:nextTool()
      elseif self.tw.done or st == core.LLM.ERROR then
        if self.streamText ~= "" then
          self.messages[#self.messages + 1] =
            { role = "assistant", content = self.streamText, provider = self.provider }
        end
        core.llmFree(self.req)
        self.req = nil
        self.tw = nil
        self.streamText = ""
        if st == core.LLM.DONE then
          self.activityNote = "Finished · see the result above"
        end
        app.audio.play("select")
      end
    end
  end
  if self.tw then
    self.tw:update(dt)
  end
  self:updateTools(dt)
  self:updateAuto()
  if not self:busy() and #self.mcpPending > 0 then
    local pending = self.mcpPending
    self.mcpPending = {}
    for _, item in ipairs(pending) do
      self:mcpDeliver(item)
    end
  end
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
  if self.practice and not self.practice.done and self.mode == "chat" then
    if key == "return" or key == "kpenter" then
      self:practiceCheck()
    else
      self.input:keypressed(key, m)
      self.practice.typed = self.input.value
    end
    return true
  end
  if key == "tab" and m.shift then
    self:toggleMode()
    return true
  elseif key == "tab" then
    self:setProvider(Config.nextProvider(self.provider))
    return true
  elseif (key == "return" or key == "kpenter") and (m.shift or m.alt) then
    return self.input:keypressed(key, m)
  elseif key == "y" and m.ctrl and self.toolJob and self.toolJob.job.needsApproval then
    self:approveTool()
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
    self.followBottom = false
    self.scrollTarget = math.max(0, self.scrollTarget - math.max(60, (self.viewH or 80) - 20))
    return true
  elseif key == "pagedown" then
    self.scrollTarget = self.scrollTarget + math.max(60, (self.viewH or 80) - 20)
    return true
  elseif key == "home" and m.ctrl then
    self.followBottom = false
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
  if self.practice and not self.practice.done then
    self.practice.typed = self.input.value
  end
end

function AI:hover(mx, my)
  if not mx then
    mx, my = self.app.D.toVirtual(love.mouse.getPosition())
  end
  local r = self.rect
  return UI.inside(mx, my, r.x, r.y, r.w, r.h)
end

function AI:wheelmoved(dy)
  self.followBottom = false
  local mx, my = self.app.D.toVirtual(love.mouse.getPosition())
  if self.practiceBox and UI.inside(mx, my, unpack(self.practiceBox)) then
    local p = self.practice
    p.scroll = math.max(0, math.min(p.maxScroll or 0, (p.scroll or 0) - dy))
    return
  end
  self.scrollTarget = math.max(0, self.scrollTarget - dy * 24)
end

function AI:mousepressed(mx, my)
  if self.inputRect and UI.inside(mx, my, unpack(self.inputRect)) then
    self:setFocus(false)
    return
  end
  if self.practiceBox and UI.inside(mx, my, unpack(self.practiceBox)) then
    self:setFocus(false)
  end
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
    self:setFocus(false)
    if self.practice and not self.practice.done then
      self:practiceCheck()
    elseif self.mode == "notes" then
      self:submitNote()
    elseif self:busy() then
      if self.toolJob and self.toolJob.job.needsApproval then
        self:approveTool()
      else
        self:cancel()
      end
    elseif Config.apiKey(self.provider) == "" and not self.app.core.mock then
      self:openAgi("keys")
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

-- Header buttons: {label, fn, lit} laid out left to right, wrapping into
-- rows. Returns the number of rows used.
function AI:drawHeaderButtons(list, x0, y0, maxW)
  local G = self.app.G
  local bx, row = x0, 0
  for _, b in ipairs(list) do
    local label, fn, lit = b[1], b[2], b[3]
    local bw = G.uiWidth(label) + 10
    if bx + bw > x0 + maxW and bx > x0 then
      bx, row = x0, row + 1
    end
    local by = y0 + row * 19
    G.panel(bx, by, bw, 16, lit and "dblue" or "ink", lit and "cyan" or "rust", 0.9)
    G.ui(label, bx + 5, by + 4, lit and "cyan" or "yellow")
    self.headerBtns[#self.headerBtns + 1] =
      { x = bx, y = by, w = bw, h = 16, fn = fn, label = label }
    bx = bx + bw + 4
  end
  return row + 1
end

-- Buttons are found by label, not by position: the rows wrap and their
-- order changes with the mode, so tests and scripted QA ask for a name.
local function byLabel(list, label)
  for _, bt in ipairs(list) do
    if bt.label == label then
      return bt
    end
  end
  return nil
end

function AI:headerButton(label)
  return byLabel(self.headerBtns, label)
end

function AI:bubbleButton(label)
  return byLabel(self.bubbleBtns, label)
end

-- Every bubble button with this label, top to bottom (one per bubble).
function AI:bubbleButtons(label)
  local out = {}
  for _, bt in ipairs(self.bubbleBtns) do
    if bt.label == label then
      out[#out + 1] = bt
    end
  end
  return out
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
  local streaming = self.req ~= nil
  local thinking = self:thinking()
  local k = self:textScale()
  self.k = k
  local TH = math.max(8, math.ceil(16 * k)) -- one text line, virtual px

  -- provider row: three mascots, the active one bright (bobbing while streaming)
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

  -- title + model (or note counts) beside the mascots, below them when narrow
  local title = notes and (self.finding and "NOTES  FIND" or "NOTES")
    or (self.provider:upper() .. " API")
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
    local key, src = Config.apiKey(self.provider)
    sub = Config.model(self.provider)
    if key ~= "" and src and src ~= "settings" then
      sub = sub .. "  key: " .. src
    elseif key == "" and not app.core.mock then
      sub = sub .. "  no key"
    end
    if self.focusTerm then
      sub = sub .. "  keys -> terminal"
    end
  end
  local narrow = x + w - pad - (mx + 4) < 80
  local labelX, labelY = narrow and (x + pad) or (mx + 4), narrow and (y + 46) or (y + pad + 6)
  UI.label(title, labelX, labelY, math.max(20, x + w - pad - labelX), notes and "cyan" or "yellow")
  local subX, subY = labelX, labelY + 11
  G.ui(UI.fit(sub, math.max(20, x + w - pad - subX)), subX, subY, "gray")

  -- button row(s)
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
      self.coding and "CODE ON" or "CODE",
      function()
        self:toggleCoding()
      end,
      self.coding,
    }
    hb[#hb + 1] = {
      "NOTES",
      function()
        self:setMode("notes")
      end,
    }
    hb[#hb + 1] = {
      "SETUP",
      function()
        self:openAgi("tools")
      end,
    }
    hb[#hb + 1] = {
      self.focusTerm and "CHAT" or "TERM",
      function()
        self:toggleFocus()
      end,
      self.focusTerm,
    }
    if #self.messages > 0 then
      hb[#hb + 1] = {
        "CLEAR",
        function()
          self:clearAll()
        end,
      }
    end
  end
  local buttonsY = narrow and (y + 70) or (y + 46)
  local rows = self:drawHeaderButtons(hb, x + pad, buttonsY, w - pad * 2)
  local headerH = (buttonsY - y) + rows * 19 + 2
  G.color("dblue", 0.6)
  love.graphics.rectangle("fill", x + pad, y + headerH - 4, w - pad * 2, 1)

  -- chat area
  local cx, cy, cw = x + pad, y + headerH, w - pad * 2
  local inputH = self:composerHeight(w - pad * 2 - 64)
  self.practiceBox = nil
  local statusH = notes and 0 or TH * 2 + 8
  local ch = math.max(0, h - (cy - y) - inputH - 26 - statusH)

  -- coding practice: pinned above the chat, never scrolls away
  if self.practice and not notes then
    local ph = self:drawPractice(cx, cy, cw, TH, k)
    cy, ch = cy + ph + 4, math.max(0, ch - ph - 4)
  end
  self.viewH = ch
  love.graphics.push("all")
  UI.clip(cx, cy, cw, ch)
  local yy = cy - math.floor(self.scroll)
  local total = 0

  -- Heights are measured in virtual px; the glyphs themselves are drawn on
  -- the terminal's pixel grid (AI:bodyText).
  local function textH(text, width)
    return UI.wrapHeight(text, math.max(8, width / k)) * k
  end
  local function drawText(text, tx, ty, width, col, a)
    self:bodyText(text, tx, ty, width, col, a)
  end
  -- small buttons drawn right to left from `right`; registered only when
  -- the whole row is inside the clip (hidden rows cannot be clicked)
  local function drawButtons(by, right, btns)
    local bx = right
    for i = #btns, 1, -1 do
      local label, fn, col = btns[i][1], btns[i][2], btns[i][3]
      local bw = G.uiWidth(label) + 8
      bx = bx - bw
      local edge = col or (label == "X" and "lred" or "gray")
      G.panel(bx, by, bw, 14, "black", edge, 0.9)
      G.ui(label, bx + 4, by + 3, col or (label == "X" and "lred" or "white"), 0.9)
      if by >= cy and by + 14 <= cy + ch then
        self.bubbleBtns[#self.bubbleBtns + 1] =
          { x = bx, y = by, w = bw, h = 14, fn = fn, label = label }
      end
      bx = bx - 3
    end
    return bx
  end
  -- A bubble: header row (tag, meta, buttons at the UI scale), then the
  -- segments: text wrapped at the terminal scale, code in its own panel
  -- with COPY / RUN / PRACTICE.
  local function bubble(role, text, provider, btns, meta, opts)
    opts = opts or {}
    local isUser = role == "user" or role == "note"
    local segs = opts.plain and { { kind = "text", text = text } } or AI.segments(text)
    if #segs == 0 then
      segs = { { kind = "text", text = "" } }
    end
    local heights, bh = {}, 15
    for i, seg in ipairs(segs) do
      if seg.kind == "code" then
        heights[i] = 16 + textH(seg.text, cw - 16) + 6
      else
        heights[i] = textH(seg.text, cw - 8)
      end
      bh = bh + heights[i] + (i < #segs and 4 or 0)
    end
    bh = bh + 6
    if yy + bh >= cy - 300 and yy <= cy + ch + 300 then
      local edge = isUser and "cyan" or "rust"
      if role == "note" then
        edge = "green"
      elseif role == "hit" then
        edge = "yellow"
      elseif role == "tool" then
        edge = "amber"
      elseif provider == "mcp" then
        edge = "neon_pink"
      end
      G.panel(cx, yy, cw, bh, isUser and "ink" or "black", edge, 0.8)
      local stop = cx + cw - 4
      if btns then
        stop = drawButtons(yy + 2, cx + cw - 4, btns) - 6
      end
      -- The tag and its meta share the row with the buttons: both are cut to
      -- `stop` so a long provider name cannot run underneath them.
      local function tag(label, col, tx)
        local shown = UI.fit(label, math.max(0, stop - tx))
        G.ui(shown, tx, yy + 4, col, 0.8)
        if meta then
          local mx0 = tx + G.uiWidth(shown) + 8
          if stop - mx0 > G.uiWidth("…") then
            G.ui(UI.fit(meta, stop - mx0), mx0, yy + 4, "gray", 0.8)
          end
        end
      end
      if role == "note" or role == "hit" then
        tag(role == "hit" and "HIT" or "NOTE", edge, cx + 4)
      elseif role == "tool" then
        tag("TOOL", "amber", cx + 4)
      elseif isUser then
        tag("YOU", "cyan", cx + 4)
      elseif provider == "mcp" then
        tag("MCP", "neon_pink", cx + 4)
      else
        G.drawIcon(AI.MASCOT[provider or self.provider] or "agent_openai", cx + 2, yy + 1, 16)
        tag((provider or self.provider):upper(), "rust", cx + 20)
      end
      local sy = yy + 15
      for i, seg in ipairs(segs) do
        if seg.kind == "code" then
          local code = seg.text
          G.panel(cx + 4, sy, cw - 8, heights[i], "navy", "green", 0.9)
          local lang = seg.lang ~= "" and seg.lang or "code"
          G.ui(UI.fit(lang, 60), cx + 8, sy + 4, "green", 0.8)
          local cbtns = {
            {
              "COPY",
              function()
                self:copyText(code)
              end,
              "cyan",
            },
          }
          if self.sessionId ~= nil then
            cbtns[#cbtns + 1] = {
              "RUN",
              function()
                self:runCode(code)
              end,
              "yellow",
            }
            cbtns[#cbtns + 1] = {
              "PRACTICE",
              function()
                self:startPractice(code, lang ~= "code" and lang or "PRACTICE")
              end,
              "green",
            }
          end
          drawButtons(sy + 1, cx + cw - 8, cbtns)
          drawText(code, cx + 8, sy + 16, cw - 16, "white", 0.95)
        else
          drawText(seg.text, cx + 4, sy, cw - 8, "white")
        end
        sy = sy + heights[i] + 4
      end
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
          self.provider,
          nil,
          nil,
          { plain = true }
        )
      elseif #self.hits == 0 then
        bubble("assistant", "No note matches.", self.provider, nil, nil, { plain = true })
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
        }, stamp(hit.ts_ms) .. (src ~= "" and ("  " .. src) or ""), { plain = true })
      end
    else
      if #self.notes == 0 and not self.error then
        bubble(
          "assistant",
          "Write a note below and press Enter, or PASTE to save the clipboard. Notes are kept in the local database and searchable with FIND.",
          self.provider,
          nil,
          nil,
          { plain = true }
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
        }, stamp(n.ts_ms), { plain = true })
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
          self.provider,
          nil,
          nil,
          { plain = true }
        )
      end
    end
  else
    for i, m in ipairs(self.messages) do
      local content = m.content or ""
      if m.role == "tool" then
        -- a tool result: the first lines, READ for the whole thing
        local shown, lines = {}, 0
        for line in (content .. "\n"):gmatch("(.-)\n") do
          lines = lines + 1
          if lines <= 6 then
            shown[#shown + 1] = line
          end
        end
        if lines > 6 then
          shown[#shown + 1] = string.format("… (%d lines, READ)", lines)
        end
        bubble("tool", table.concat(shown, "\n"), nil, {
          {
            "READ",
            function()
              self:readText(content, "TOOL " .. (m.name or ""))
            end,
          },
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
        }, m.name or "", { plain = true })
      else
        local meta
        if m.tool_calls and #m.tool_calls > 0 then
          local names = {}
          for _, c in ipairs(m.tool_calls) do
            names[#names + 1] = c.name
          end
          meta = "calls " .. table.concat(names, ", ")
          if content == "" then
            content = "(calling " .. table.concat(names, ", ") .. ")"
          end
        elseif m.notesUsed and m.notesUsed > 0 then
          meta = string.format("+%d note%s", m.notesUsed, m.notesUsed == 1 and "" or "s")
        end
        bubble(m.role, content, m.provider, {
          {
            "READ",
            function()
              self:readText(
                m.content or "",
                m.role == "user" and "YOU" or (m.provider or ""):upper()
              )
            end,
          },
          {
            "COPY",
            function()
              self:copyText(m.content or "")
            end,
          },
          {
            "X",
            function()
              self:clearMessage(i)
            end,
          },
        }, meta)
      end
    end
    if #self.messages == 0 and not self.req and not self.error then
      local key = Config.apiKey(self.provider)
      bubble(
        "assistant",
        key == ""
            and not app.core.mock
            and "Add an API key to chat here. For Claude Code, open SETUP > MCP and ask there; its answers can appear here."
          or "Describe what to build or fix on the SSH computer. CODE writes files within your current folder. Shell commands need access approval because they can reach outside it. Review the step, then ALLOW or SKIP. STOP interrupts.",
        self.provider,
        {
          {
            "EXPLAIN",
            function()
              self.input.value = "Explain what is on my terminal and suggest the next step."
              self:send()
            end,
          },
          {
            "FIX",
            function()
              self.input.value =
                "Help diagnose the error on my terminal. Inspect it and propose a fix."
              self:send()
            end,
          },
        },
        nil,
        { plain = true }
      )
    end
    if self.harnessNote then
      bubble("tool", self.harnessNote, nil, {
        {
          "SETUP",
          function()
            self:openAgi("tools")
          end,
        },
      }, "harness", { plain = true })
    end
    local tj = self.toolJob
    if tj then
      local job = tj.job
      if job.needsApproval then
        local review = job.kind == "write_file"
            and ("Write file: " .. job.path .. "\n\n" .. job.preview)
          or ("wants to run:\n$ " .. (job.command or ""))
        if job.accessReason then
          review = job.accessReason .. "\n\n" .. review
        end
        bubble("tool", review, nil, {
          {
            job.accessReason and "ALLOW" or "RUN",
            function()
              self:approveTool()
            end,
            "yellow",
          },
          {
            "SKIP",
            function()
              self:denyTool()
            end,
          },
        }, tj.call.name .. "  (^Y approves)", { plain = true })
      else
        local dots = string.rep(".", 1 + math.floor(self.blink * 3) % 3)
        bubble(
          "tool",
          string.format(
            "%s%s  %ds\n$ %s",
            job.waiting and "still running" or "running",
            dots,
            math.floor(job.t or 0),
            job.command or ""
          ),
          nil,
          {
            {
              "STOP",
              function()
                self:cancel()
              end,
              "lred",
            },
          },
          tj.call.name,
          { plain = true }
        )
      end
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
      bubble("assistant", shown, self.provider, nil, self.toolRounds > 0 and "after tools" or nil)
    end
  end
  if self.error then
    bubble("assistant", "! " .. self.error, self.provider, nil, nil, { plain = true })
  end
  self.contentH = total
  if self.followBottom and not notes then
    self.scrollTarget = math.max(0, total - ch)
  end
  love.graphics.pop()

  -- input + buttons + hints
  local iy = y + h - inputH - 20
  G.color("dblue", 0.6)
  love.graphics.rectangle("fill", x + pad, iy - 4, w - pad * 2, 1)
  local label
  if self.practice and not self.practice.done then
    label = "CHECK"
  elseif notes then
    label = self.finding and "FIND" or "ADD"
  elseif self:busy() then
    label = self.toolJob
        and self.toolJob.job.needsApproval
        and (self.toolJob.job.accessReason and "ALLOW" or "RUN")
      or "STOP"
  else
    local key = Config.apiKey(self.provider)
    label = key == "" and not app.core.mock and "KEY" or "SEND"
  end
  local bw = G.uiWidth(label) + 12
  local right = x + w - pad
  self.sendButton = { right - bw, iy, bw, 20 }
  if not notes then
    local status = self:activity()
    self.activityText = status
    self:bodyLine(
      UI.fit(status, (w - pad * 2 - 8) / k),
      x + pad + 4,
      iy - statusH,
      self.error and "lred" or "cyan"
    )
    local workspace = self.workspaceRoot
      or (self.sessionId ~= nil and app.core.cwd(self.sessionId))
      or ""
    local rec = app.sessions.get(self.sessionId)
    workspace = Config.hidePath(workspace, rec and rec.user, rec and rec.host)
    local workspaceLabel = "Workspace: " .. (workspace ~= "" and workspace or "unknown")
    local workspaceW = (w - pad * 2 - 8) / k
    if G.uiWidth(workspaceLabel) > workspaceW then
      workspaceLabel = "Workspace: …/" .. (workspace:match("[^/]+$") or workspace)
    end
    self:bodyLine(UI.fit(workspaceLabel, workspaceW), x + pad + 4, iy - statusH + TH, "gray")
  end
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
  self:drawComposer(x + pad, iy, w - pad * 2 - used, inputH - 4, t)
  if self.practice and not self.practice.done then
    UI.hints({ { "Enter", "check" }, { "Esc", "chat" } }, x + pad, y + h - 16, w - pad * 2)
  elseif notes then
    UI.hints({
      { "Enter", self.finding and "search" or "add" },
      { "S-Tab", "chat" },
      { "PgUp/Dn", "scroll" },
      { "Esc", self.finding and "stop find" or "close" },
    }, x + pad, y + h - 16, w - pad * 2)
  elseif self.focusTerm then
    UI.hints({
      { "^S-Space", "chat" },
      { "PgUp/Dn", "scroll" },
      { "Esc", "shell" },
    }, x + pad, y + h - 16, w - pad * 2)
  else
    UI.hints({
      { "Enter", "send" },
      { "S-Enter", "line" },
      { "^Enter", "review" },
      { "Tab", "provider" },
      { "^S-Space", "term" },
      { "Esc", self:busy() and "cancel" or "close" },
    }, x + pad, y + h - 16, w - pad * 2)
  end
end

-- The practice block: title row, the current line with the typed prefix
-- coloured (green matched, red wrong), the next line dimmed. Returns height.
-- Wrap at glyph boundaries without losing spaces, indentation or UTF-8.
function AI:bodyRows(text, width)
  local rows, row, start, used = {}, "", 1, 0
  local utf8 = require("utf8")
  for pos, cp in utf8.codes(text) do
    local ch = utf8.char(cp)
    local size = self:bodyWidth(ch)
    if ch == "\n" or (used + size > width and row ~= "") then
      rows[#rows + 1] = { text = row, start = start }
      row, used, start = "", 0, pos
    end
    if ch == "\n" then
      start = pos + 1
    else
      row, used = row .. ch, used + size
    end
  end
  rows[#rows + 1] = { text = row, start = start }
  return rows
end

function AI:composerHeight(width)
  local rows = self:bodyRows(self.input.value, math.max(16, width - 16))
  return math.max(28, math.min(4, #rows) * math.ceil(16 * self:textScale()) + 12)
end

function AI:drawComposer(x, y, w, h, t)
  local G = self.app.G
  local focused = not self.focusTerm
  self.inputRect = { x, y, w, h }
  G.panel(x, y, w, h, "ink", focused and "cyan" or "dgray")
  local text = self.input.value
  local placeholder = text == ""
  if placeholder then
    text = self.practice and not self.practice.done and "Type the practice line here"
      or self.mode == "notes" and "Write a note…"
      or "Ask, write code, or fix errors…"
  end
  local rows = self:bodyRows(text, math.max(8, w - 16))
  local lh = math.ceil(16 * self:textScale())
  local visible = math.max(1, math.floor((h - 8) / lh))
  local first = math.max(1, #rows - visible + 1)
  love.graphics.push("all")
  UI.clip(x + 3, y + 3, w - 6, h - 6)
  for i = first, #rows do
    local yy = y + 4 + (i - first) * lh
    if self.input.selectAll and focused and not placeholder then
      G.panel(x + 3, yy, self:bodyWidth(rows[i].text) + 2, lh, "dblue", "dblue")
    end
    self:bodyLine(rows[i].text, x + 5, yy, placeholder and "gray" or "white")
  end
  if focused and math.floor(t * 2.5) % 2 == 0 then
    local cx = x + 5 + (placeholder and 0 or self:bodyWidth(rows[#rows].text))
    local cy = y + 4 + (placeholder and 0 or (#rows - first) * lh)
    G.color("cyan")
    love.graphics.rectangle("fill", cx, cy, math.max(1, self:textScale() * 2), lh)
  end
  love.graphics.pop()
end

function AI:drawPractice(cx, cy, cw, TH, k)
  local G, p = self.app.G, self.practice
  p.typed = p.field.value
  local rows = self:bodyRows(
    p.done and "Complete. Back to chat; Run is optional." or p.lines[p.i],
    math.max(8, cw - 12)
  )
  local visible = math.min(6, #rows)
  local ph = 38 + visible * TH + 12
  self.practiceBox = { cx, cy, cw, ph }
  p.maxScroll = math.max(0, #rows - visible)
  if p.lastTyped ~= p.typed then
    p.lastTyped = p.typed
    local caret = 1
    for i, row in ipairs(rows) do
      if row.start <= #p.typed + 1 then
        caret = i
      end
    end
    p.scroll = math.min(p.maxScroll, math.max(0, caret - visible))
  end
  p.scroll = math.max(0, math.min(p.scroll or 0, p.maxScroll))
  G.panel(cx, cy, cw, ph, "black", p.done and "cyan" or "green", 0.95)
  UI.label(
    p.done and "PRACTICE COMPLETE" or string.format("PRACTICE %d/%d", p.i, #p.lines),
    cx + 4,
    cy + 4,
    cw - 8,
    "green"
  )
  local btns = p.done
      and {
        {
          "RUN",
          function()
            self:runCode(p.code)
          end,
        },
        {
          "CLOSE",
          function()
            self:stopPractice()
          end,
        },
      }
    or {
      {
        "READ",
        function()
          self:readText(p.code, "PRACTICE")
        end,
      },
      {
        "SKIP",
        function()
          self:practiceSkip()
        end,
      },
      {
        "STOP",
        function()
          self:stopPractice()
        end,
      },
    }
  local bx = cx + 4
  for _, bt in ipairs(btns) do
    local bw = G.uiWidth(bt[1]) + 8
    G.panel(bx, cy + 18, bw, 14, "black", "gray")
    G.ui(bt[1], bx + 4, cy + 21, "white")
    self.bubbleBtns[#self.bubbleBtns + 1] =
      { x = bx, y = cy + 18, w = bw, h = 14, label = bt[1], fn = bt[2] }
    bx = bx + bw + 3
  end
  local n = p.done and 0 or AI.practiceMatch(p.typed, p.lines[p.i])
  for i = p.scroll + 1, math.min(#rows, p.scroll + visible) do
    local row = rows[i]
    local take = math.max(0, math.min(#row.text, n - row.start + 1))
    local prefix, rest = row.text:sub(1, take), row.text:sub(take + 1)
    local yy = cy + 36 + (i - p.scroll - 1) * TH
    self:bodyLine(prefix, cx + 6, yy, "lgreen")
    self:bodyLine(rest, cx + 6 + self:bodyWidth(prefix), yy, "white")
  end
  local hint = p.maxScroll > 0 and "Scroll here to see more" or "Local practice · nothing runs"
  if not p.done and n < #p.typed then
    hint = "Mismatch · edit or try again"
  end
  self:bodyLine(hint, cx + 6, cy + ph - TH - 2, "gray")
  return ph
end

-- RUN on a code block: review, then paste into this session.
function AI:runCode(code)
  if self.sessionId == nil then
    return false
  end
  local text = code:gsub("%s+$", "") .. "\n"
  self.app.push("paste", { id = self.sessionId, text = text, ai = true })
  self.app.audio.play("select")
  return true
end

-- Full-screen reader for any text (answers, tool results).
function AI:readText(text, title)
  self.app.push("note", { text = text, title = title, sessionId = self.sessionId, readOnly = true })
end

return AI
