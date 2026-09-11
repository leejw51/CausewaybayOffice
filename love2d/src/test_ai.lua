-- In-engine tests for the AI assist page: tool registry and executor,
-- the panel's tool loop (mock core), harness updates, coding practice,
-- MCP delivery, multi-line fields, the AGI page and the playground.
local M = {}

function M.run(App, check)
  local json = require("src.json")
  local UI = require("src.ui")
  local Tools = require("src.tools")
  local AI = require("src.scenes.ai")
  local Agi = require("src.scenes.agi")
  local Term = require("src.scenes.terminal")
  local Core, Config, fx = App.core, App.cfg, App.fx
  local none = { ctrl = false, shift = false, alt = false, gui = false }
  local shiftM = { ctrl = false, shift = true, alt = false, gui = false }

  -- json: an empty object survives (tool schemas need "properties": {})
  check(
    "json.object keeps {} an object",
    json.encode({ a = json.object({}), b = {} }) == '{"a":{},"b":[]}'
  )

  -- ---- tools registry ----------------------------------------------------
  Core.jsonlSave(Tools.STORE, {})
  Tools.load(Core)
  check("no user tools at start", #Tools.user == 0 and Tools.loaded)
  check("shell quoting splices quotes", Tools.shellQuote("a b'c") == "'a b'\\''c'")
  check(
    "template expansion quotes every argument",
    Tools.expand("df -h {path} {missing}", { path = "/tmp/x y" }) == "df -h '/tmp/x y' ''"
  )
  local ps = Tools.paramsOf("path, count")
  check("params parse from a comma list", #ps == 2 and ps[1] == "path" and ps[2] == "count")
  check(
    "a hyphenated name is split into identifiers, never passed through",
    table.concat(Tools.paramsOf("bad-name"), ",") == "bad,name"
  )
  check(
    "tool names are identifiers",
    Tools.validName("disk_free") and not Tools.validName("rm -rf")
  )
  local bad, err = Tools.add({ name = "read_screen", command = "x" }, Core)
  check("built-in names cannot be replaced", bad == nil and err:find("built%-in"))
  local t, err2 = Tools.add(
    { name = "disk_free", description = "free space", command = "df -h {path}", params = "path" },
    Core
  )
  check("user tool added", t ~= nil and t.command == "df -h {path}", err2)
  local schema = Tools.schema(t)
  check(
    "schema lists the params as required strings",
    schema.type == "object"
      and schema.properties.path.type == "string"
      and schema.required[1] == "path"
  )
  check(
    "schema of a no-arg tool is an object",
    json.encode(Tools.schema(Tools.find("list_tools"))):find('"properties":{}', 1, true) ~= nil
  )
  Tools.load(Core) -- reload from the store: the definition is persisted
  check(
    "user tool persists in tools.jsonl rows",
    Tools.find("disk_free") ~= nil and #Tools.user == 1
  )
  local llmTools = Tools.forLlm()
  local names = {}
  for _, tool in ipairs(llmTools) do
    names[tool.name] = true
  end
  check(
    "request tool list carries built-ins and the user tool",
    names.read_screen and names.define_tool and names.disk_free and names.run_command
  )
  Tools.setEnabled("disk_free", false, Core)
  local enabled = {}
  for _, tool in ipairs(Tools.forLlm()) do
    enabled[tool.name] = true
  end
  check("a disabled tool leaves the request", enabled.disk_free == nil and enabled.read_screen)
  Tools.setEnabled("disk_free", true, Core)

  check(
    "read_screen lines is optional in the actual sent schema",
    llmTools[1].parameters.required == nil
  )

  -- executor: immediate tools and command jobs
  local written, gen = {}, 0
  local ctx = {
    core = Core,
    sessionId = 0,
    autoRun = false,
    screenText = function()
      return "line1\nline2\nline3\n\n"
    end,
    write = function(b)
      written[#written + 1] = b
      gen = gen + 1
    end,
    generation = function()
      return gen
    end,
  }
  local job = Tools.run("read_screen", { lines = 2 }, ctx)
  check("read_screen returns the last rows", job.done and job.result == "line2\nline3", job.result)
  job = Tools.run("nope", {}, ctx)
  check("unknown tool is an error result", job.done and job.result:find("unknown tool"))
  job = Tools.run("run_command", { command = "" }, ctx)
  check("empty command refused", job.done and job.result:find("empty"))
  job = Tools.run("disk_free", { path = "/srv" }, ctx)
  check(
    "user tool waits for approval",
    not job.done and job.needsApproval and job.command == "df -h '/srv'"
  )
  job:deny()
  check(
    "SKIP answers the model without typing",
    job.done and job.result:find("declined") and #written == 0
  )
  job = Tools.run("run_command", { command = "uptime" }, ctx)
  job:approve()
  check("RUN types a tracked command", written[1]:find("eval 'uptime'", 1, true) and not job.done)
  check(
    "completion marker cannot match the echoed command",
    not written[1]:find(job.marker, 1, true)
  )
  job:update(0.1)
  gen = gen + 1 -- the shell answered
  job:update(0.1)
  check("job waits for the screen to settle", not job.done)
  job:update(Tools.TIMEOUT + 1)
  check("silence and timeout never complete a running command", not job.done and job.waiting)
  local originalScreen = ctx.screenText
  ctx.screenText = function()
    return "old unrelated output\n"
      .. job.startMarker
      .. "\nline1\nline2\n"
      .. job.marker
      .. ":0\n$ "
  end
  job:update(0.1)
  check(
    "explicit completion captures the output",
    job.done
      and job.result:find("line2")
      and not job.result:find(job.marker, 1, true)
      and not job.result:find("old unrelated", 1, true)
  )
  ctx.screenText = originalScreen
  ctx.autoRun = true
  written = {}
  job = Tools.run("run_command", { command = "id" }, ctx)
  check("AUTO RUN skips the approval", job.started and written[1]:find("eval 'id'", 1, true))
  job = Tools.run("define_tool", { name = "cpu", description = "load", command = "uptime" }, ctx)
  check(
    "define_tool adds a live tool",
    job.done and Tools.find("cpu") ~= nil and Tools.find("cpu").command == "uptime"
  )
  job = Tools.run("remove_tool", { name = "cpu" }, ctx)
  check("remove_tool drops it", job.done and Tools.find("cpu") == nil)

  -- Execute only our generated shell transport in a private test folder.
  -- This catches quoting/UTF-8 damage that a mock terminal cannot detect.
  do
    local dir = "file-tool-" .. Core.nowMs()
    love.filesystem.createDirectory(dir)
    local root = love.filesystem.getSaveDirectory() .. "/" .. dir
    local screen, writes = "", 0
    local fileCtx = {
      core = Core,
      autoRun = false,
      restrictWorkspace = true,
      workspace = root,
      cwd = function()
        return root
      end,
      screenText = function()
        return screen
      end,
      write = function(command)
        writes = writes + 1
        local pipe = assert(io.popen(command .. " 2>&1"))
        screen = pipe:read("*a")
        pipe:close()
        return true
      end,
    }
    local source = string.rep("\tprintln!(\"Hello, 香港! $HOME `pwd` 'quoted'\");\r\n", 9)
    local fileJob = Tools.run("write_file", { path = "a 'quoted'.rs", content = source }, fileCtx)
    check(
      "file writing waits for approval and previews exact source",
      writes == 0 and fileJob.needsApproval and fileJob.preview == source
    )
    fileJob:approve()
    for _ = 1, 100 do
      if fileJob.done then
        break
      end
      fileJob:update(0.1)
    end
    check(
      "file chunks preserve exact source bytes",
      fileJob.success and love.filesystem.read(dir .. "/a 'quoted'.rs") == source
    )
    check("large sources use several bounded terminal writes", writes > 3)
    fileCtx.autoRun = true
    local duplicate =
      Tools.run("write_file", { path = "a 'quoted'.rs", content = "replacement" }, fileCtx)
    for _ = 1, 100 do
      if duplicate.done then
        break
      end
      duplicate:update(0.1)
    end
    check(
      "existing source survives an unapproved overwrite",
      duplicate.success == false and love.filesystem.read(dir .. "/a 'quoted'.rs") == source
    )
    local edit = Tools.run(
      "write_file",
      { path = "a 'quoted'.rs", content = "replacement\n", overwrite = true },
      fileCtx
    )
    for _ = 1, 100 do
      if edit.done then
        break
      end
      edit:update(0.1)
    end
    check(
      "explicit overwrite publishes the new source",
      edit.success and love.filesystem.read(dir .. "/a 'quoted'.rs") == "replacement\n"
    )
    local beforeEscape = writes
    local escape = Tools.run("write_file", { path = "../escape.rs", content = "no" }, fileCtx)
    check(
      "outside writes wait even with Auto Run enabled",
      escape.needsApproval and escape.accessReason ~= nil and writes == beforeEscape
    )
    escape:deny()
    check("declining outside access writes nothing", writes == beforeEscape)
    check(
      "workspace containment handles traversal and sibling prefixes",
      not Tools.insideWorkspace(root, root .. "/../escape.rs")
        and not Tools.insideWorkspace(root, root .. "-sibling/file")
        and Tools.insideWorkspace(root, root .. "/src/../hello.rs")
    )
    local outsideDir = dir .. "-outside"
    love.filesystem.createDirectory(outsideDir)
    local outsideRoot = love.filesystem.getSaveDirectory() .. "/" .. outsideDir
    local pipe = assert(
      io.popen(
        "ln -s " .. Tools.shellQuote(outsideRoot) .. " " .. Tools.shellQuote(root .. "/link")
      )
    )
    pipe:read("*a")
    pipe:close()
    local linked = Tools.run("write_file", { path = "link/escape.rs", content = "no" }, fileCtx)
    for _ = 1, 20 do
      if linked.done then
        break
      end
      linked:update(0.1)
    end
    check(
      "symlink directories cannot redirect a confined write outside",
      linked.success == false and love.filesystem.getInfo(outsideDir .. "/escape.rs") == nil
    )
    os.remove(root .. "/link")
    love.filesystem.remove(outsideDir)
    local shell = Tools.run("run_command", { command = "cat ../secret" }, fileCtx)
    check(
      "shell commands require outside-access approval even in Auto Run",
      shell.needsApproval and shell.accessReason ~= nil and not shell.started
    )
    local custom = Tools.run("disk_free", { path = "../" }, fileCtx)
    check(
      "custom command tools cannot bypass workspace approval",
      custom.needsApproval and custom.accessReason ~= nil and not custom.started
    )
    for _, name in ipairs(love.filesystem.getDirectoryItems(dir)) do
      love.filesystem.remove(dir .. "/" .. name)
    end
    love.filesystem.remove(dir)
  end

  -- ---- config: keys in apikeys.jsonl ---------------------------------------
  local before = Config.get().apiKeys.xai
  Config.setApiKey("xai", "  xai-test-key ")
  local rows = Core.jsonlLoad(Config.KEYS_FILE) or {}
  local found
  for _, row in ipairs(rows) do
    if row.provider == "xai" then
      found = row.key
    end
  end
  check("API key lands trimmed in apikeys.jsonl rows", found == "xai-test-key")
  Config.setApiKey("xai", "")
  rows = Core.jsonlLoad(Config.KEYS_FILE) or {}
  found = nil
  for _, row in ipairs(rows) do
    if row.provider == "xai" then
      found = row.key
    end
  end
  check("removed key is written as empty", found == "")
  Config.get().apiKeys.xai = before

  do
    local savedLoad, savedGet, savedMock = Core.jsonlLoad, Core.kvGet, Core.mock
    Core.mock = false
    Core.kvGet = function()
      return '{"apiKeys":{"xai":"old-test-key"}}'
    end
    Core.jsonlLoad = function()
      return {}
    end
    check(
      "deleting a JSONL key row does not restore the SQLite copy",
      Config.load().apiKeys.xai == ""
    )
    Core.jsonlLoad, Core.kvGet, Core.mock = savedLoad, savedGet, savedMock
    Config.load()
    Config.get().apiKeys.xai = before
  end

  -- Every setting the assist page writes must be declared in defaults():
  -- config.merge only keeps keys it already knows, so an undeclared one is
  -- silently dropped on the next load.
  do
    local cfg = Config.get()
    local saved = {}
    for _, name in ipairs({ "aiTools", "aiAutoRun", "aiTermFont", "mcpAuto", "mcpPort" }) do
      saved[name] = cfg[name]
    end
    cfg.aiTools, cfg.aiAutoRun, cfg.aiTermFont = false, true, false
    cfg.mcpAuto, cfg.mcpPort = true, 9999
    local encoded = json.encode(cfg)
    Config.load() -- back to defaults
    local fresh = Config.get()
    local declared = json.decode(encoded)
    for name, value in pairs({
      aiTools = false,
      aiAutoRun = true,
      aiTermFont = false,
      mcpAuto = true,
      mcpPort = 9999,
    }) do
      check(
        "config declares " .. name .. " so it survives a reload",
        declared[name] == value and type(fresh[name]) == type(value)
      )
    end
    for name, value in pairs(saved) do
      fresh[name] = value
    end
  end

  -- ---- segments + sanitize -------------------------------------------------
  local segs = AI.segments("Run this:\n```bash\nls -la\n```\nthen done")
  check(
    "fenced code splits into segments",
    #segs == 3
      and segs[2].kind == "code"
      and segs[2].lang == "bash"
      and segs[2].text == "ls -la"
      and segs[3].text == "then done"
  )
  segs = AI.segments("```\nstreaming")
  check(
    "unclosed fence runs to the end",
    #segs == 1 and segs[1].kind == "code" and segs[1].text == "streaming"
  )
  check(
    "plain text is one segment",
    #AI.segments("hi") == 1 and AI.segments("hi")[1].kind == "text"
  )
  local msgs = AI.sanitize({
    { role = "user", content = "q" },
    {
      role = "assistant",
      content = "",
      tool_calls = { { id = "a", name = "read_screen", arguments = "{}" } },
    },
    { role = "tool", tool_call_id = "a", name = "read_screen", content = "screen" },
    {
      role = "assistant",
      content = "dropped result",
      tool_calls = { { id = "b", name = "x", arguments = "{}" } },
    },
    { role = "tool", tool_call_id = "zzz", content = "orphan" },
    { role = "assistant", content = "note", provider = "mcp" },
  })
  check(
    "sanitize keeps complete call/result pairs and drops orphans",
    #msgs == 5
      and msgs[2].tool_calls[1].id == "a"
      and msgs[3].role == "tool"
      and msgs[4].tool_calls == nil
      and msgs[4].content == "dropped result"
      and msgs[5].content == "note"
  )

  -- ---- panel tool loop with the mock core -----------------------------------
  local lib = require("src.core_mock")
  local id = Core.open({ host = "ai-test.example", port = 22, user = "t", cols = 40, rows = 8 })
  Core.update(1)
  local oldScene, oldName, oldOverlays = App.scene, App.sceneName, App.overlays
  local fakeTerm = {
    name = "terminal",
    id = id,
    screenText = function()
      return "m4max ~% cd /Users/x\nm4max ~%"
    end,
    write = function(_, b)
      Core.write(id, b)
    end,
  }
  App.scene, App.sceneName, App.overlays = fakeTerm, "terminal", {}
  local ai = AI.new(App, id)
  -- Simulated time: the mock streams 60 chars a second and the typewriter
  -- 240, so a full lorem answer needs several seconds of it.
  local function pump(seconds, until_)
    local t = 0
    while t < seconds do
      Core.update(0.05)
      ai:update(0.05)
      fx.update(0.05)
      t = t + 0.05
      if until_ and until_() then
        return true
      end
    end
    return until_ == nil
  end
  ai.input.value = "what is on my screen?"
  ai:send()
  check(
    "send starts a request with tools",
    ai.req ~= nil and ai.turnTools ~= nil and #ai.turnTools >= 7
  )
  pump(40, function()
    return not ai:busy()
  end)
  local kinds = {}
  for _, m in ipairs(ai.messages) do
    kinds[#kinds + 1] = m.role .. (m.tool_calls and "+calls" or "")
  end
  check(
    "tool loop: user, call, result, answer",
    table.concat(kinds, ",") == "user,assistant+calls,tool,assistant",
    table.concat(kinds, ",")
  )
  check(
    "read_screen result carries the screen text",
    ai.messages[3].content:find("m4max", 1, true) ~= nil
  )
  check(
    "final answer streamed after the tool",
    ai.messages[4].content:find("openai", 1, true) ~= nil
  )
  check("tool rounds counted", ai.toolRounds == 1)
  check(
    "consuming the queue preserves tool calls for the next provider request",
    ai.messages[2].tool_calls[1] ~= nil
      and AI.sanitize(ai.messages)[2].tool_calls[1].name == "read_screen"
  )

  local realStart, followupHasTool = Core.llmStart, false
  Core.llmStart = function(args)
    for _, t in ipairs(args.tools or {}) do
      if t.name == "disk_usage" then
        followupHasTool = true
      end
    end
    return realStart(args)
  end
  ai.input.value = "please define a tool for disk space"
  ai:send()
  pump(40, function()
    return not ai:busy()
  end)
  Core.llmStart = realStart
  check("follow-up request includes the just-defined tool", followupHasTool)
  local du = Tools.find("disk_usage")
  check(
    "the model's define_tool call lands in the registry",
    du ~= nil and du.command == "du -sh {path}"
  )
  check("harness notice shown to the user", ai.harnessNote ~= nil and ai.harnessNote:find("live"))
  local live = {}
  for _, tool in ipairs(Tools.forLlm()) do
    live[tool.name] = true
  end
  check("new harness is in the next request without relaunch", live.disk_usage == true)
  check(
    "a tool the AI defined survives a reload of the store",
    (function()
      Tools.load(Core)
      return Tools.find("disk_usage") ~= nil
    end)()
  )
  ai:clearAll()
  ai.input.value = "what is on screen?"
  ai:send()
  ai:cancel()
  pump(2)
  check(
    "cancelled request cannot publish or execute late tool calls",
    not ai:busy() and #ai.messages == 1
  )
  ai:clearAll()

  -- approval flow: a command tool waits for RUN
  local gen0 = Core.generation(id)
  ai.toolQueue = { { id = "c9", name = "run_command", args = { command = "uptime" } } }
  ai:nextTool()
  check(
    "command waits in the panel for approval",
    ai.toolJob ~= nil and ai.toolJob.job.needsApproval
  )
  ai:toggleCoding()
  check(
    "CODE does not silently approve unrestricted SSH commands",
    ai.coding and ai.toolJob.job.needsApproval and Core.generation(id) == gen0
  )
  ai:draw(0, 0, 360, 440, 0)
  check("pending access is reported persistently", ai.activityText:find("ALLOW", 1, true) ~= nil)
  ai:mousepressed(ai.sendButton[1] + 2, ai.sendButton[2] + 2)
  check("RUN types into the session", Core.generation(id) > gen0)
  check(
    "main action starts the pending tool rather than cancelling it",
    ai.toolJob ~= nil and ai.toolJob.job.started and ai:activity():find("Running", 1, true) ~= nil
  )
  ai.coding = false
  local oldScreen = fakeTerm.screenText
  local commandMarker = ai.toolJob.job.marker
  fakeTerm.screenText = function()
    return "up 3 days\n" .. commandMarker .. ":0"
  end
  pump(20, function()
    return ai.toolJob == nil
  end)
  fakeTerm.screenText = oldScreen
  check(
    "approved command result appended and the turn continues",
    ai.messages[1] and ai.messages[1].role == "tool" and ai.messages[1].content:find("uptime")
  )
  ai:close()
  ai:clearAll()
  ai.error = nil

  local context = ai:ctx()
  fakeTerm.id = id + 1
  local switchedJob = Tools.commandJob("pwd", context, true)
  check(
    "a queued command cannot follow a reused terminal view",
    switchedJob.done and switchedJob.result:find("session changed")
  )
  fakeTerm.id = id

  local continueTurn, toolsOn = ai.continueTurn, Config.get().aiTools
  ai.continueTurn = function() end
  Config.get().aiTools = false
  local beforeDisabled = Core.generation(id)
  ai.toolQueue = { { id = "disabled", name = "run_command", args = { command = "pwd" } } }
  ai:nextTool()
  check(
    "turning tools off prevents queued commands",
    ai.toolJob == nil
      and Core.generation(id) == beforeDisabled
      and ai.messages[1].content:find("disabled")
  )
  ai.continueTurn, Config.get().aiTools = continueTurn, toolsOn
  ai:clearAll()

  -- ---- practice ---------------------------------------------------------------
  local lines = AI.practiceLines("echo hi\n\n  ls -la   \n")
  check("practice lines drop blanks and trailing spaces", #lines == 2 and lines[2] == "  ls -la")
  check(
    "practice starts in a local field",
    ai:startPractice("echo hi\nls -la", "demo") and not ai.focusTerm
  )
  ai:practiceInput("echo h")
  check(
    "typed prefix tracked",
    ai.practice.typed == "echo h" and AI.practiceMatch(ai.practice.typed, "echo hi") == 6
  )
  ai:practiceInput("x\127i\r")
  check(
    "backspace and Enter advance on a matching line",
    ai.practice.i == 2 and ai.practice.errors == 0
  )
  ai:practiceInput("ls\r")
  check("a wrong line counts a retry and stays", ai.practice.i == 2 and ai.practice.errors == 1)
  ai:practiceInput("ls -la\r")
  check(
    "retry replaces the wrong line, completion returns to chat",
    ai.practice.done == true and ai.input == ai.chatInput and not ai.focusTerm
  )
  ai:stopPractice()
  check("stop returns the keyboard to the chat", ai.practice == nil and not ai.focusTerm)

  -- ---- MCP delivery -------------------------------------------------------------
  Core.mockMcpPush("send", "Try this:\n```\necho from claude\n```", "hint")
  local items = Core.mcpTake()
  check("inbox drains once", #items == 1 and #Core.mcpTake() == 0)
  ai:mcpDeliver(items[1])
  local last = ai.messages[#ai.messages]
  check(
    "MCP text becomes an MCP bubble",
    last.provider == "mcp" and last.content:find("echo from claude")
  )
  ai:mcpDeliver({ kind = "practice", text = "pwd\nls", title = "warmup" })
  check(
    "MCP practice starts a practice",
    ai.practice ~= nil and ai.practice.lines[1] == "pwd" and not ai.focusTerm
  )
  ai:stopPractice()
  ai:mcpDeliver({ kind = "type", text = "ls -la\n" })
  check("MCP typed input goes through the review sheet", App.hasOverlay("paste"))
  App.overlays = {}
  check(
    "App routes inbox items to the terminal scene",
    (function()
      fakeTerm.deliverMcp = function(_, item)
        fakeTerm.got = item
      end
      App.deliverMcp({ kind = "send", text = "x" })
      return fakeTerm.got ~= nil
    end)()
  )
  ai:clearAll()

  -- ---- multi-line field -----------------------------------------------------------
  local f = UI.field("", "", { multiline = true, maxLen = 100 })
  f.focused = true
  f:textinput("print(1)")
  f:keypressed("return", shiftM)
  f:textinput("print(2)")
  check("Shift+Enter inserts a newline", f.value == "print(1)\nprint(2)" and #f:lines() == 2)
  check("multi-line display marks the break", f:display():find("⏎", 1, true) ~= nil)
  local single = UI.field("", "", { maxLen = 100 })
  check("single-line field still refuses newlines", not single:textinput("a\nb"))

  local wrapped = ai:bodyRows("  香港 example with indentation and spaces", 32)
  local reconstructed = {}
  for _, row in ipairs(wrapped) do
    reconstructed[#reconstructed + 1] = row.text
    check("wrapped practice row fits", ai:bodyWidth(row.text) <= 32)
  end
  check(
    "practice wrapping preserves every character",
    table.concat(reconstructed) == "  香港 example with indentation and spaces"
  )
  check("practice matching stops at a Unicode boundary", AI.practiceMatch("你", "他") == 0)

  -- ---- panel draw smoke at the terminal scale -------------------------------------
  ai.messages = {
    { role = "user", content = "show me" },
    { role = "assistant", content = "Here:\n```sh\nls -la\n```", provider = "openai" },
    { role = "tool", name = "read_screen", tool_call_id = "z", content = "a\nb\nc\nd\ne\nf\ng\nh" },
  }
  local okDraw, drawErr = pcall(function()
    ai:draw(0, 0, 256, 300, 0)
  end)
  check("panel draws code, tool and chat bubbles", okDraw, drawErr)
  check("code block offers RUN and PRACTICE buttons", #ai.bubbleBtns >= 8)
  check(
    "text scale follows the terminal zoom",
    math.abs(ai:textScale() - App.D.termZoom / App.D.s) < 1e-6
  )
  ai:startPractice("tail -f /var/log/syslog", "sh")
  ai:practiceInput("tail -f")
  okDraw, drawErr = pcall(function()
    ai:draw(0, 0, 256, 300, 0)
  end)
  check("panel with a practice draws", okDraw, drawErr)
  check(
    "the practice block is pinned above the chat with SKIP and STOP",
    ai:bubbleButton("SKIP") ~= nil and ai:bubbleButton("STOP") ~= nil
  )
  okDraw, drawErr = pcall(function()
    ai:draw(0, 0, 140, 200, 0)
  end)
  check("narrow panel with a practice draws", okDraw, drawErr)
  ai:stopPractice()
  ai:clearAll()

  -- ---- terminal scene: focus routing, buttons ---------------------------------------
  local sc = Term.new(App, { id = id })
  App.scene, App.sceneName = sc, "terminal"
  sc:layout()
  sc:toggleAI()
  for _ = 1, 8 do
    fx.update(0.1)
  end
  sc.ai.input.value, sc.ai.input.selectAll = "", false
  sc:textinput("q")
  check("chat focus: typing goes to the input", sc.ai.input.value == "q")
  local g0 = Core.generation(id)
  sc:keypressed("space", { ctrl = true, shift = true, alt = false, gui = false })
  check("Ctrl+Shift+Space moves the keyboard to the terminal", sc.ai.focusTerm)
  sc:textinput("w")
  check(
    "terminal focus: typing goes to the shell, not the chat",
    Core.generation(id) > g0 and sc.ai.input.value == "q"
  )
  sc:keypressed("space", { ctrl = true, shift = true, alt = false, gui = false })
  check("and back", not sc.ai.focusTerm)
  sc:draw()
  sc.ai:draw(0, 0, 260, 400, 0)
  check(
    "the panel keeps setup and terminal focus within reach",
    sc.ai:headerButton("SETUP") and sc.ai:headerButton("TERM")
  )
  check("Ctrl+G is the AGI chord", require("src.keys").appChord("g", { ctrl = true }) == "agi")
  local menuHasAgi = false
  sc:openMenu(4, 20)
  for _, item in ipairs(App.top().items) do
    menuHasAgi = menuHasAgi or item[1]:find("AGI") ~= nil
  end
  App.overlays = {}
  check("the context menu offers the AGI page", menuHasAgi)
  -- Practice edits never reach SSH, including mistakes, paste and Return.
  sc.ai:startPractice("echo correct", "sh")
  local originalWrite, sent = Core.write, ""
  Core.write = function(_, bytes)
    sent = sent .. bytes
  end
  sc:textinput("echo wrong")
  sc:keypressed("return", none)
  check("wrong practice input does not execute", sent == "" and sc.ai.practice.errors == 1)
  sc:textinput("echo correct")
  sc:keypressed("return", none)
  check(
    "correct practice input does not execute and returns to chat",
    sent == "" and sc.ai.practice.done and sc.ai.input == sc.ai.chatInput
  )
  sc:keypressed("escape", none)
  check(
    "Esc dismisses practice without reaching the shell",
    sent == "" and not sc.ai.practice and not sc.ai.focusTerm
  )
  sc.ai:draw(0, 0, 260, 400, 0)
  sc.ai:setFocus(true)
  local r = sc.ai.inputRect
  sc.ai:mousepressed(r[1] + 2, r[2] + 2)
  sc:textinput("question")
  check(
    "clicking the composer restores chat focus",
    sent == "" and not sc.ai.focusTerm and sc.ai.input.value:find("question")
  )
  sc.ai:startPractice("echo reviewed", "sh")
  sc:textinput("echo reviewed")
  sc:keypressed("return", none)
  sc.ai:draw(0, 0, 260, 400, 0)
  local run = sc.ai:bubbleButton("RUN")
  run.fn()
  check("practice RUN opens review before writing", App.hasOverlay("paste") and sent == "")
  App.overlays = {}
  sc.ai:stopPractice()
  Core.write = originalWrite
  sc:openAgi("keys")
  check(
    "AGI opens on the keys tab",
    App.hasOverlay("agi") and App.overlays[#App.overlays].tab == "keys"
  )
  App.overlays = {}

  -- ---- AGI page -----------------------------------------------------------------------
  local agi = Agi.new(App, { tab = "tools", sessionId = id, panel = sc.ai })
  agi:openForm(nil)
  agi.form.fields[1][2].value = "mem_free"
  agi.form.fields[2][2].value = "free memory"
  agi.form.fields[3][2].value = "free -m {unit}"
  agi.form.fields[4][2].value = "unit"
  check(
    "AGI form saves a tool live",
    agi:saveForm() and Tools.find("mem_free") ~= nil and agi.form == nil
  )
  for i, tool in ipairs(agi:toolRows()) do
    if tool.name == "mem_free" then
      agi.sel = i
    end
  end
  agi:openForm(agi:selectedTool())
  agi.form.fields[3][2].value = "free -h"
  agi:saveForm()
  check("AGI edit updates the command", Tools.find("mem_free").command == "free -h")
  agi:openForm(agi:selectedTool())
  agi.form.fields[1][2].value = "invalid name!"
  check(
    "invalid rename preserves the existing tool",
    not agi:saveForm() and Tools.find("mem_free") ~= nil
  )
  agi.form = nil
  check("AGI delete removes a user tool", agi:deleteTool() and Tools.find("mem_free") == nil)
  agi.sel = 1
  check("built-ins refuse delete", not agi:deleteTool())
  agi:setTab("keys")
  agi.sel = 3
  agi:beginEdit("key", "xai")
  agi.edit.field:textinput("xai-from-agi")
  agi:commitEdit()
  check("AGI key editor stores the key", Config.get().apiKeys.xai == "xai-from-agi")
  agi:clearKey("xai")
  check(
    "AGI removes the key",
    Config.get().apiKeys.xai == ""
      and Config.apiKey("xai") == (os.getenv("XAI_API_KEY") or os.getenv("GROK_API_KEY") or "")
  )
  Config.get().apiKeys.xai = before
  agi:setTab("play")
  agi.play.prompt.value = "cbo_ping please"
  check("playground sends", agi:playSend(nil, false) and agi.play.req ~= nil)
  local t = 0
  while agi.play.req and t < 10 do
    Core.update(0.05)
    agi:update(0.05)
    t = t + 0.05
  end
  check(
    "playground reports OK with the reply",
    agi.play.status:find("^OK") and agi.play.text:find("CBO_PONG"),
    agi.play.status
  )
  check(
    "playground TOOLS TEST asks with tools",
    agi:playSend(Agi.TOOLS_TEST, true) and agi.play.tools
  )
  t = 0
  while agi.play.req and t < 10 do
    Core.update(0.05)
    agi:update(0.05)
    t = t + 0.05
  end
  check(
    "playground sees the tool call",
    agi.play.status:find("tool call read_screen"),
    agi.play.status
  )
  agi:setTab("mcp")
  -- App.setMcp is what the button and the autostart in App.init both call.
  check(
    "App.setMcp starts the server and points it at the terminal on screen",
    App.setMcp(true) and Core.mcpInfo().running and Core.mcpInfo().session == id
  )
  check("App.setMcp stops it again", App.setMcp(false) and not Core.mcpInfo().running)
  -- AUTO START at launch: App.init calls this, so the decision and the port
  -- it passes are checked here rather than by relaunching the app.
  do
    local cfg = Config.get()
    local realStart, realMock = Core.mcpStart, Core.mock
    local startedWith
    Core.mcpStart = function(port)
      startedWith = port
      return true
    end
    Core.mock = false -- pretend a real core is loaded
    cfg.mcpAuto, cfg.mcpPort = true, 8123
    check(
      "AUTO START brings the server up on the configured port",
      App.mcpAutoStart() and startedWith == 8123
    )
    startedWith = nil
    cfg.mcpAuto = false
    check("AUTO START off starts nothing", not App.mcpAutoStart() and startedWith == nil)
    cfg.mcpAuto = true
    Core.mock = true
    check(
      "AUTO START never opens a socket under the mock core",
      not App.mcpAutoStart() and startedWith == nil
    )
    Core.mcpStart, Core.mock = realStart, realMock
    cfg.mcpAuto, cfg.mcpPort = false, 8765
  end
  agi:toggleMcp()
  check(
    "MCP starts from the page",
    Core.mcpInfo().running
      and agi:claudeCommand():find("^claude mcp add %-%-transport http office http://127%.0%.0%.1")
  )
  do
    local cfg = Config.get()
    local oldMask = cfg.maskIds
    local url = Core.mcpInfo().url
    local token = url:match("/mcp/([^/]+)")
    cfg.maskIds = true
    check(
      "privacy masks the MCP token in the displayed connection command",
      token ~= nil
        and not agi:claudeCommand(true):find(token, 1, true)
        and agi:claudeCommand(true):find("[hidden]", 1, true) ~= nil
    )
    check(
      "explicit MCP copy keeps the usable credential in privacy mode",
      agi:claudeCommand():find(url, 1, true) ~= nil
    )
    local drawn = {}
    local originalText, originalWrapped = App.G.text, UI.wrapped
    App.G.text = function(text, ...)
      drawn[#drawn + 1] = tostring(text)
      return originalText(text, ...)
    end
    UI.wrapped = function(text, ...)
      drawn[#drawn + 1] = tostring(text)
      return originalWrapped(text, ...)
    end
    local rendered, renderError = pcall(function()
      agi:draw()
    end)
    App.G.text, UI.wrapped = originalText, originalWrapped
    check(
      "MCP privacy rendering never draws the bearer token",
      rendered and not table.concat(drawn, "\n"):find(token, 1, true),
      renderError
    )
    cfg.maskIds = false
    check(
      "MCP connection details remain readable outside privacy mode",
      agi:claudeCommand(true):find(url, 1, true) ~= nil
    )
    cfg.maskIds = oldMask
  end
  agi:toggleMcp()
  check("MCP stops", not Core.mcpInfo().running)
  for _, tab in ipairs(Agi.TABS) do
    agi:setTab(tab)
    local ok, e = pcall(function()
      agi:draw()
    end)
    check("AGI " .. tab .. " tab draws", ok, e)
  end
  agi:leave()

  sc.ai:close()
  Tools.remove("disk_free", Core)
  Tools.remove("disk_usage", Core)
  Core.close(id)
  App.scene, App.sceneName, App.overlays = oldScene, oldName, oldOverlays
  lib.reset()
end

return M
