-- Opt-in live Grok coding-agent check: no canned answer, source, or tool calls.
local M = {}

function M.run(App, H, language)
  local isGo = language == "go"
  local prompt = isGo and "write golang code to producer, consumer using channel, produce integer"
    or "write rust code for helloworld"
  local Config, Tools = App.cfg, require("src.tools")
  local json = require("src.json")
  local started, sc, ai, setup, rec, root, relative, opening
  local oldAuto, oldKey = Config.get().aiAutoRun, Config.get().apiKeys.xai
  local oldTools = Config.get().aiTools
  local seen, trace, completed, pendingId, writingShot = {}, {}, false, nil, false
  local originalUpdate = App.update
  local function finish(ok, detail)
    if completed then
      return
    end
    completed = true
    App.update = originalUpdate
    H.check(
      "codeagent: live Grok writes, builds and runs " .. (isGo and "Go" or "Rust"),
      ok,
      detail
    )
    if ai then
      ai:close()
    end
    Config.get().aiAutoRun, Config.get().apiKeys.xai = oldAuto, oldKey
    Config.get().aiTools = oldTools
    love.filesystem.write(
      "codeagent_report.json",
      json.encode({
        ok = ok,
        directory = root,
        provider = "xai",
        model = Config.model("xai"),
        prompt = prompt,
        trace = trace,
        messages = ai and ai.messages or {},
        error = detail,
      })
    )
    H.shot("codeagent_result")
    H.finish(0.6)
  end
  local function poll()
    if completed then
      return
    end
    local elapsed = love.timer.getTime() - started
    if elapsed > 240 then
      finish(false, "Timed out after 240 seconds")
      return
    end
    if not sc then
      if App.sceneName == "terminal" and App.scene.id == rec.id then
        sc = App.scene
        sc:toggleAI()
        ai = sc.ai
        ai.provider = "xai"
        Config.get().aiTools, Config.get().aiAutoRun = true, false
        Config.get().apiKeys.xai = os.getenv("GROK_API_KEY") or os.getenv("XAI_API_KEY") or oldKey
      elseif not opening and App.core.state(rec.id) == App.core.ST.CONNECTED then
        opening = true
        App.switch("terminal", { id = rec.id })
      end
    elseif not setup and elapsed > 3 then
      setup = Tools.commandJob("cd " .. Tools.shellQuote(root), ai:ctx(), true)
    elseif setup and not setup.done then
      setup:update(0.1)
    elseif setup and not ai.codeTestSent then
      if not setup.success then
        finish(false, setup.result)
        return
      end
      ai.codeTestSent = true
      ai:toggleCoding()
      -- The exact requested user flow, through the terminal's chat input.
      ai.input.value = ""
      sc:textinput(prompt)
      sc:keypressed("return", H.none)
      H.info("codeagent: provider and model", "xai / " .. Config.model("xai"))
      H.info("codeagent: isolated working folder", root)
      H.shot("codeagent_prompt")
    elseif ai.codeTestSent then
      local tj = ai.toolJob
      if tj and tj.job.kind == "write_file" and tj.job.started and not writingShot then
        writingShot = true
        H.shot("codeagent_writing")
      end
      if tj and tj.job.needsApproval then
        if pendingId ~= tj.call.id then
          pendingId = tj.call.id
          love.filesystem.write(
            "codeagent_pending.json",
            json.encode({
              id = pendingId,
              root = root,
              command = tj.job.command,
              reason = tj.job.accessReason,
              messages = ai.messages,
            })
          )
          H.info("codeagent: waiting for deliberate access approval", pendingId)
          H.shot("codeagent_approval")
        end
        -- QA automation may acknowledge one reviewed call. Never auto-approve
        -- calls, and never set the product's Auto Run flag to bypass the review.
        local ack = io.open("love2d/build/codeagent-approval.txt", "r")
        if ack then
          local approved = ack:read("*a")
          ack:close()
          if approved == pendingId and ai.sendButton then
            ai:mousepressed(ai.sendButton[1] + 2, ai.sendButton[2] + 2)
          end
        end
      end
      for _, msg in ipairs(ai.messages) do
        for _, call in ipairs(msg.tool_calls or {}) do
          if not seen[call.id] then
            seen[call.id] = true
            trace[#trace + 1] = { name = call.name, args = call.args }
            H.info("codeagent: Grok called", call.name)
          end
        end
      end
      if not ai:busy() then
        local wrote, ran = false, false
        for _, msg in ipairs(ai.messages) do
          if msg.role == "tool" then
            wrote = wrote or (msg.name == "write_file" and msg.content:find("^Wrote ") ~= nil)
            ran = ran
              or (
                msg.name == "run_command"
                and msg.content:find("[success]", 1, true) ~= nil
                and (
                  (isGo and msg.content:find("go run", 1, true) and msg.content:match("\n[^\n]*%d"))
                  or (
                    not isGo
                    and msg.content:lower():find("hello,? world!") ~= nil
                    and (
                      msg.content:find("rustc", 1, true) ~= nil
                      or msg.content:find("cargo", 1, true) ~= nil
                    )
                  )
                )
              )
          end
        end
        local sources = {}
        local function scan(dir)
          for _, name in ipairs(love.filesystem.getDirectoryItems(dir)) do
            local path = dir .. "/" .. name
            local info = love.filesystem.getInfo(path)
            if info and info.type == "directory" and name ~= "target" then
              scan(path)
            elseif name:match(isGo and "%.go$" or "%.rs$") then
              sources[#sources + 1] = path
            end
          end
        end
        scan(relative)
        H.check("codeagent: source exists on disk", #sources > 0, table.concat(sources, ", "))
        H.check("codeagent: write_file executed", wrote)
        H.check("codeagent: compiler and program succeeded", ran)
        finish(wrote and ran and #sources > 0 and not ai.error, ai.error)
        return
      end
    end
  end
  H.at(2.2, function()
    if Config.apiKey("xai") == "" then
      finish(false, "GROK_API_KEY or XAI_API_KEY required")
      return
    end
    H.setMode(isGo and 800 or 1280, isGo and 1400 or 900)
    relative = "codeagent-" .. App.core.nowMs()
    love.filesystem.createDirectory(relative)
    root = love.filesystem.getSaveDirectory() .. "/" .. relative
    rec = App.sessions.open({
      host = "localhost",
      port = 22,
      user = os.getenv("USER"),
      cols = 100,
      rows = 32,
      noRemember = true,
    })
    if not rec then
      finish(false, "Could not open localhost SSH")
      return
    end
    -- Avoid restoring a previously remembered working folder in this test.
    rec.wantCwd, rec.cwdArmed = nil, true
    started = love.timer.getTime()
    -- Poll once per frame. Rescheduling a timer from inside fx.updateTimers
    -- can repeatedly fire in the same frame when dt exceeds the interval.
    App.update = function(dt)
      originalUpdate(dt)
      poll()
    end
  end)
end

return M
