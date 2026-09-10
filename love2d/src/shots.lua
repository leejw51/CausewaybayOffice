-- Scripted walkthroughs for screenshots and QA (`love love2d -- --shots[=phase]`).
-- Every step is a timer on the fx clock, so the app runs exactly as it does
-- for a user: input goes through App.textinput / the scene's keypressed,
-- screenshots come from love.graphics.captureScreenshot into the save dir
-- (~/Library/Application Support/LOVE/causewaybayoffice/qa_*.png).
--
-- Phases:
--   art     boot / lobby / connect / terminal / ai / settings (README art)
--   qa      the docs/QA_CHECKLIST.md walkthrough against localhost; prints
--           `[qa] PASS|FAIL|INFO <check> ...` lines and writes qa.log
--   verify  second launch: the fake API key from `qa` survived a restart
--   limit   128-session limit against the black-hole host + lobby fps
--   perf    3 sessions running `yes | head -c 5M`, fps sampled
--   mock    (with --mock) the MOCK badge + connect without a core
--   hero    two lobby frames diffed: the hero's feet never move
--   map     world map: 3 stages, hero walks to localhost and connects
--   display F11 fullscreen and back (grid + core agree)
--   portrait 800x1400 window: lobby columns, AI docked below, map fits width
--   phase 3 (src/shots_p3.lua): hero6 nav nav2 map3 map3verify display3

local M = {}

local utf8 = require("utf8")

-- The strings every unicode check uses (test.lua renders the same list).
M.UNICODE = {
  "你好世界",
  "香港銅鑼灣",
  "안녕하세요",
  "세션 이름",
  "こんにちは",
  "東京タワー",
  "ｶﾀｶﾅ",
  "Příliš žluťoučký kůň úpěl ďábelské ódy",
}

local function chars(str)
  local out = {}
  for c in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = c
  end
  return out
end

function M.run(App, phase)
  local fx = App.fx
  local D = App.D
  local none = { ctrl = false, shift = false, alt = false, gui = false }
  local ctrl = { ctrl = true, shift = false, alt = false, gui = false }
  local gui = { ctrl = false, shift = false, alt = false, gui = true }
  local shiftM = { ctrl = false, shift = true, alt = false, gui = false }
  local log = {}
  local fails = 0

  local function say(kind, name, detail)
    local line =
      string.format("[qa] %s %s%s", kind, name, detail and ("  " .. tostring(detail)) or "")
    print(line)
    log[#log + 1] = line
  end
  local function check(name, cond, detail)
    if cond then
      say("PASS", name, detail)
    else
      fails = fails + 1
      say("FAIL", name, detail)
    end
  end
  local function info(name, detail)
    say("INFO", name, detail)
  end

  local function shot(name)
    love.graphics.captureScreenshot(name .. ".png")
    local sc = App.scene
    info(
      "shot " .. name,
      string.format(
        "fps=%d ui-scale=%d window=%dx%d grid=%s",
        love.timer.getFPS(),
        D.s,
        D.w,
        D.h,
        (sc and sc.cols and sc.rows)
            and (sc.cols .. "x" .. sc.rows .. " @" .. (sc.zoom or 1) .. "x")
          or "-"
      )
    )
  end

  local T = 0
  local function at(delay, fn)
    T = T + delay
    fx.after(T, function()
      local ok, err = pcall(fn)
      if not ok then
        check("step at " .. T, false, err)
      end
    end)
  end

  local function typeText(str)
    for _, c in ipairs(chars(str)) do
      App.textinput(c)
    end
  end
  local function key(k, m)
    local target = App.top()
    if target and target.keypressed then
      target:keypressed(k, m or none)
    end
  end
  -- type a shell line through the real key path (textinput + Return)
  local function line(cmd)
    typeText(cmd)
    key("return")
  end
  local function term()
    return App.sceneName == "terminal" and App.scene or nil
  end
  local function finish(extra)
    at(extra or 0.5, function()
      local text = table.concat(log, "\n") .. "\n"
      love.filesystem.write("qa_" .. phase .. ".log", text)
      print(string.format("[qa] %s: %d failures", phase, fails))
      love.event.quit(fails == 0 and 0 or 1)
    end)
  end

  -- setMode resets vsync to conf.lua's value; keep it off or a background
  -- window stops getting frames (see main.lua)
  local function setMode(w, h)
    love.window.setMode(w, h, { resizable = true, vsync = 0, minwidth = 640, minheight = 400 })
    love.window.setVSync(0)
  end

  local function connectLocalhost(fromTerminal)
    App.push("connect", { fromTerminal = fromTerminal })
  end

  -- The title only leaves on Space (no timer, no click). Phases that wait
  -- for the lobby at ~3 s get the key pressed here, outside the at() chain
  -- so their own timings stay put; phases that switch scenes themselves are
  -- unaffected (advance is a no-op once the boot scene is done).
  fx.after(1.5, function()
    if App.sceneName == "boot" then
      key("space")
    end
  end)

  local QA_DIR = "/tmp/cbo_qa"

  -- phase 3 walkthroughs live in their own module
  local H = {
    at = at,
    check = check,
    info = info,
    shot = shot,
    key = key,
    typeText = typeText,
    line = line,
    term = term,
    finish = finish,
    setMode = setMode,
    none = none,
    ctrl = ctrl,
  }
  if require("src.shots_p3").run(App, phase, H) then
    return
  end
  if phase == "polish" then
    require("src.shots_polish").run(App, H)
    return
  end

  if phase == "aichat" then
    local connected
    at(1, function()
      setMode(800, 1400)
      App.setOrientation("portrait")
      connected = App.sessions.open({ host = "localhost", user = os.getenv("USER") or "dev" })
      App.switch("terminal", { id = connected.id })
    end)
    at(3, function()
      check(
        "AI test uses connected real SSH",
        App.core.state(connected.id) == App.core.ST.CONNECTED
      )
      key("space", { ctrl = true, shift = true })
      check("AI shortcut opens chat", App.scene.aiOpen and App.scene.ai ~= nil)
    end)
    at(0.6, function()
      local sc, ai = App.scene, App.scene.ai
      check(
        "vertical AI chat stacks below terminal at full width",
        ai.rect.x == 0 and ai.rect.w == App.D.vw and ai.rect.y >= sc.oy + sc.gh
      )
      ai.input.value, ai.input.selectAll = "", false
      sc:textinput("Reply with exactly CBO_AI_OK and nothing else.")
      local apiKey = App.cfg.apiKey(ai.provider)
      if apiKey == "" then
        print("skipped: no provider API key for live AI chat UI")
        shot("qa_ai_needs_key")
        finish(0.5)
        return
      end
      ai:mousepressed(ai.sendButton[1] + 2, ai.sendButton[2] + 2)
      check("click SEND starts a real AI request", ai.req ~= nil, ai.error)
      local deadline = love.timer.getTime() + 120
      local function poll()
        if ai.req and love.timer.getTime() < deadline then
          fx.after(0.2, poll)
          return
        end
        check(
          "AI response arrives through the live panel",
          ai.req == nil
            and not ai.error
            and ai:lastAnswer()
            and ai:lastAnswer():find("CBO_AI_OK", 1, true) ~= nil,
          ai.error
        )
        shot("qa_ai_stacked")
        sc:keypressed("return", ctrl)
        check("AI command insertion opens a review", App.hasOverlay("paste"))
        if App.hasOverlay("paste") then
          App.pop()
        end
        fx.after(0.6, function()
          setMode(1280, 800)
          App.setOrientation("landscape")
          fx.after(0.6, function()
            check("horizontal AI chat docks beside terminal", ai.rect.x > 0 and ai.rect.y == sc.top)
            shot("qa_ai_side")
            fx.after(0.3, function()
              App.setOrientation("portrait")
              fx.after(0.6, function()
                check(
                  "changing to vertical stacks existing chat",
                  ai.rect.x == 0 and ai.rect.w == App.D.vw and ai.rect.y >= sc.oy + sc.gh
                )
                App.sessions.close(connected.id)
                finish(0.2)
              end)
            end)
          end)
        end)
      end
      fx.after(0.2, poll)
    end)
    return
  end

  -- notes: AUTO NOTE from the terminal bar, typed and pasted notes, FIND,
  -- the full-screen reader, the chat picking notes up. Real SSH + real DB;
  -- every note made here is deleted at the end.
  if phase == "notes" then
    local connected
    -- ids that existed before the phase: everything else is ours to delete
    local preexisting = {}
    for _, n in ipairs(App.core.noteList(5000)) do
      preexisting[n.id] = true
    end
    local function cleanup()
      for _, n in ipairs(App.core.noteList(5000)) do
        if not preexisting[n.id] then
          App.core.noteDelete(n.id)
        end
      end
    end
    at(1, function()
      setMode(1280, 800)
      App.setOrientation("landscape")
      connected = App.sessions.open({ host = "localhost", user = os.getenv("USER") or "dev" })
      App.switch("terminal", { id = connected.id })
    end)
    at(3, function()
      check(
        "notes test uses connected real SSH",
        App.core.state(connected.id) == App.core.ST.CONNECTED
      )
      line("echo CBO_QA_NOTE screen capture for the auto note; uname -s")
    end)
    at(1.5, function()
      local sc = term()
      local pos = require("src.scenes.terminal").toolbar(App.D, App.G)
      check(
        "terminal bar shows RENAME and AUTO NOTE",
        pos["RENAME"] ~= nil and pos["AUTO NOTE"] ~= nil
      )
      local before = #App.core.noteList(500)
      check("AUTO NOTE captures the screen", sc:autoNote() and sc.aiOpen and sc.ai.mode == "notes")
      local deadline = love.timer.getTime() + 120
      local function poll()
        if sc.ai.auto and love.timer.getTime() < deadline then
          fx.after(0.2, poll)
          return
        end
        local after = App.core.noteList(500)
        check(
          "auto note is saved in the database",
          #after == before + 1 and after[1].text:find("^AUTO NOTE"),
          after[1] and after[1].text:sub(1, 80)
        )
        shot("qa_notes_auto")
        local ai = sc.ai
        ai.noteInput.value, ai.noteInput.selectAll = "", false
        sc:textinput(
          "CBO_QA_NOTE restart nginx after the cert renews: sudo systemctl restart nginx"
        )
        sc:keypressed("return", none)
        check(
          "typed note saved, input cleared",
          ai.noteInput.value == "" and ai.notes[#ai.notes].text:find("systemctl", 1, true)
        )
        love.system.setClipboardText("CBO_QA_NOTE wifi password is in the drawer")
        ai:mousepressed(ai.pasteButton[1] + 2, ai.pasteButton[2] + 2)
        check("PASTE saves the clipboard", ai.notes[#ai.notes].text:find("wifi", 1, true))
        fx.after(0.5, function()
          shot("qa_notes_list")
          fx.after(0.3, function()
            -- FIND
            ai:setFinding(true)
            sc:textinput("nginx")
          end)
          fx.after(0.8, function()
            check(
              "FIND lists the nginx note",
              #ai.hits >= 1 and ai:hitText(ai.hits[1]):find("nginx", 1, true)
            )
            shot("qa_notes_find")
            sc:keypressed("return", none) -- hybrid pass
            fx.after(0.8, function()
              check(
                "hybrid FIND keeps the nginx note on top",
                #ai.hits >= 1 and ai:hitText(ai.hits[1]):find("nginx", 1, true),
                ai.hits[1] and ai.hits[1].sources and table.concat(ai.hits[1].sources, "+")
              )
              ai:cancel()
              -- reader
              local n = ai.notes[#ai.notes - 1]
              ai:read(n)
              fx.after(0.5, function()
                check("READ opens the full screen note", App.hasOverlay("note"))
                shot("qa_notes_read")
                App.pop()
                fx.after(0.4, function()
                  -- the chat sees the notes
                  ai:setMode("chat")
                  local notes = ai:notesFor("how do I restart nginx")
                  check(
                    "chat context picks the nginx note",
                    #notes >= 1 and notes[1]:find("nginx", 1, true),
                    notes[1]
                  )
                  ai.messages = {
                    { role = "user", content = "how do I restart nginx", notesUsed = #notes },
                    {
                      role = "assistant",
                      content = "sudo systemctl restart nginx",
                      provider = ai.provider,
                    },
                  }
                  fx.after(0.4, function()
                    shot("qa_notes_chat")
                    setMode(800, 1400)
                    App.setOrientation("portrait")
                    fx.after(0.8, function()
                      ai:setMode("notes")
                      fx.after(0.5, function()
                        shot("qa_notes_portrait")
                        cleanup()
                        check("QA notes removed", #App.core.noteList(500) == before)
                        App.sessions.close(connected.id)
                        finish(0.2)
                      end)
                    end)
                  end)
                end)
              end)
            end)
          end)
        end)
      end
      fx.after(0.2, poll)
    end)
    return
  end

  -- hot note: HOT NOTE -> click a filename -> edit -> Esc uploads it back.
  if phase == "hotnote" then
    local connected
    local dir = love.filesystem.getSaveDirectory() .. "/hot-click"
    os.execute(string.format("mkdir -p '%s'", dir))
    local name = "hot" .. os.time() .. ".txt"
    local remote = dir .. "/" .. name
    local f = assert(io.open(remote, "wb"))
    f:write("alpha\nbeta\n")
    f:close()
    at(1, function()
      setMode(1280, 800)
      App.setOrientation("landscape")
      connected = App.sessions.open({ host = "localhost", user = os.getenv("USER") or "dev" })
      App.switch("terminal", { id = connected.id })
    end)
    at(3, function()
      check(
        "hot note test uses connected real SSH",
        App.core.state(connected.id) == App.core.ST.CONNECTED
      )
      line(string.format("cd '%s'; ls", dir))
    end)
    local row, col
    at(2, function()
      local sc = term()
      local tv = sc:view()
      for r = 0, tv.rows - 1 do
        local text = tv:rowText(r, 0, tv.cols - 1)
        local c = text:find(name, 1, true)
        if c and not text:find("ls", 1, true) then
          row, col = r, c - 1
        end
      end
      check("ls shows the temp file", row ~= nil)
      check("shell folder known", App.core.cwd(connected.id) == dir, App.core.cwd(connected.id))
      local pos = require("src.scenes.terminal").toolbar(App.D, App.G)
      check("terminal bar shows HOT NOTE", pos["HOT NOTE"] ~= nil)
      sc:toggleHotNotePick()
      check("HOT NOTE arms picking", sc.hotNotePicking)
    end)
    at(0.4, function()
      local sc = term()
      shot("qa_hotnote_pick")
    end)
    at(0.4, function()
      local sc = term()
      sc:mousepressed(sc.ox + (col + 1.5) * sc.cellW, sc.oy + (row + 0.5) * sc.cellH, 1)
      check("filename click opens the hot note overlay", App.hasOverlay("hotnote"))
      local ov = App.top()
      local deadline = love.timer.getTime() + 30
      local function poll()
        if ov.state == "download" and love.timer.getTime() < deadline then
          fx.after(0.2, poll)
          return
        end
        check(
          "file downloaded into the editor",
          ov.state == "edit" and ov.editor:line(1) == "alpha",
          ov.error
        )
        ov:keypressed("down", none)
        ov:keypressed("end", none)
        ov:textinput(" 銅鑼灣")
        ov:keypressed("return", none)
        ov:textinput("gamma")
        fx.after(0.3, function()
          shot("qa_hotnote_edit")
        end)
        fx.after(0.6, function()
          ov:keypressed("escape", none)
          check("Esc starts the upload", ov.state == "upload")
          local deadline2 = love.timer.getTime() + 30
          local function poll2()
            if ov.state == "upload" and love.timer.getTime() < deadline2 then
              fx.after(0.2, poll2)
              return
            end
            check(
              "upload finished and the overlay closed",
              ov.uploaded and not App.hasOverlay("hotnote"),
              ov.error
            )
            local g = assert(io.open(remote, "rb"))
            local back = g:read("*a")
            g:close()
            check("remote file holds the edit", back == "alpha\nbeta 銅鑼灣\ngamma\n", back)
            local leftovers = io.popen(string.format("ls -a '%s'", dir)):read("*a")
            check("no temp or backup files remain", not leftovers:find("cbo%-"), leftovers)
            fx.after(0.4, function()
              shot("qa_hotnote_done")
              os.remove(remote)
              -- NEW NOTE into the same folder
              check(
                "NEW NOTE opens an empty editor at once",
                sc:newNote() and App.hasOverlay("hotnote")
              )
              local nv = App.top()
              local newName = nv.fileName
              check(
                "fruit name in the shell folder",
                nv.state == "edit"
                  and nv.remote == dir .. "/" .. newName
                  and newName:match("^%a+%d+%.txt$"),
                newName
              )
              nv:textinput("# 銅鑼灣 todo")
              nv:keypressed("return", none)
              nv:textinput("- tram")
              fx.after(0.3, function()
                shot("qa_newnote_edit")
              end)
              fx.after(0.6, function()
                nv:keypressed("escape", none)
                check("Esc uploads the new file", nv.state == "upload")
                local deadline3 = love.timer.getTime() + 30
                local function poll3()
                  if nv.state == "upload" and love.timer.getTime() < deadline3 then
                    fx.after(0.2, poll3)
                    return
                  end
                  check(
                    "new note upload finished",
                    nv.uploaded and not App.hasOverlay("hotnote"),
                    nv.error
                  )
                  local g2 = io.open(dir .. "/" .. newName, "rb")
                  local body = g2 and g2:read("*a") or nil
                  if g2 then
                    g2:close()
                  end
                  check(
                    "new file landed in the shell folder",
                    body == "# 銅鑼灣 todo\n- tram\n",
                    body
                  )
                  -- reopen: Esc without edits uploads nothing; DISCARD after edits keeps the file
                  local stamp = io.popen(string.format("stat -f %%m '%s/%s'", dir, newName))
                    :read("*l")
                  check(
                    "hot note reopens the new file",
                    sc:hotNote(newName) and App.hasOverlay("hotnote")
                  )
                  local ro = App.top()
                  local deadline4 = love.timer.getTime() + 30
                  local function poll4()
                    if ro.state == "download" and love.timer.getTime() < deadline4 then
                      fx.after(0.2, poll4)
                      return
                    end
                    check(
                      "reopened file shows the saved text",
                      ro.state == "edit" and ro.editor:line(2) == "- tram",
                      ro.error
                    )
                    ro:keypressed("escape", none)
                    check(
                      "Esc on an unchanged file closes without an upload",
                      not App.hasOverlay("hotnote") and ro.state == "edit" and not ro.uploaded
                    )
                    check("hot note again", sc:hotNote(newName))
                    local rd = App.top()
                    local deadline5 = love.timer.getTime() + 30
                    local function poll5()
                      if rd.state == "download" and love.timer.getTime() < deadline5 then
                        fx.after(0.2, poll5)
                        return
                      end
                      rd:textinput("SHOULD NOT LAND")
                      rd:discard()
                      fx.after(0.5, function()
                        local g3 = assert(io.open(dir .. "/" .. newName, "rb"))
                        local kept = g3:read("*a")
                        g3:close()
                        local stamp2 = io.popen(string.format("stat -f %%m '%s/%s'", dir, newName))
                          :read("*l")
                        check(
                          "DISCARD keeps the remote file untouched",
                          kept == body and stamp2 == stamp and not App.hasOverlay("hotnote")
                        )
                        os.remove(dir .. "/" .. newName)
                        App.sessions.close(connected.id)
                        finish(0.2)
                      end)
                    end
                    fx.after(0.2, poll5)
                  end
                  fx.after(0.2, poll4)
                end
                fx.after(0.2, poll3)
              end)
            end)
          end
          fx.after(0.2, poll2)
        end)
      end
      fx.after(0.2, poll)
    end)
    return
  end

  -- kitty graphics: real SSH, the python tool emits every variant, the view
  -- must decode and paint them into the terminal canvas.
  if phase == "kitty" then
    local connected
    at(1, function()
      setMode(1280, 800)
      App.setOrientation("landscape")
      connected = App.sessions.open({ host = "localhost", user = os.getenv("USER") or "dev" })
      App.switch("terminal", { id = connected.id })
    end)
    at(3, function()
      check(
        "kitty test uses connected real SSH",
        App.core.state(connected.id) == App.core.ST.CONNECTED
      )
      local script = love.filesystem.getSource():gsub("/love2d/?$", "") .. "/tools/kitty_test.py"
      line("clear; python3 " .. script .. " --all")
    end)
    at(3, function()
      local sc = term()
      local tv = sc and sc:view()
      local pl = tv and tv.placements or {}
      check("kitty: four placements visible in the app", #pl == 4, #pl)
      check(
        "kitty: textures decoded for every placement",
        tv and tv:imageCount() == 3,
        tv and tv:imageCount()
      )
      local zneg = 0
      for _, p in ipairs(pl) do
        if p.z < 0 then
          zneg = zneg + 1
        end
      end
      check("kitty: one placement under the text (z<0)", zneg == 1, zneg)
      if tv and tv.canvas and pl[1] then
        local data = tv.canvas:newImageData()
        local p = pl[#pl] -- the last one drawn (highest z) is fully visible
        local px = p.col * tv.CW + 30
        local py = p.row * tv.CH + 6
        local r, g, b = data:getPixel(px, py)
        check(
          "kitty: sprite pixels painted in the canvas",
          math.abs(r - 0xB7 / 255) < 0.06
            and math.abs(g - 0x41 / 255) < 0.06
            and math.abs(b - 0x0E / 255) < 0.06,
          ("%.2f %.2f %.2f"):format(r, g, b)
        )
      end
      shot("qa_kitty_images")
    end)
    at(0.5, function()
      line("clear")
    end)
    at(1.5, function()
      local tv = term() and term():view()
      check("kitty: clear removes the images", tv and #tv.placements == 0, tv and #tv.placements)
      shot("qa_kitty_cleared")
      App.sessions.close(connected.id)
      finish(0.2)
    end)
    return
  end

  if phase == "folders" then
    local rec, base
    local child = "my project's 한글"
    at(0.5, function()
      love.filesystem.createDirectory("folder-click/" .. child)
      base = love.filesystem.getSaveDirectory() .. "/folder-click"
      rec = App.sessions.open({
        host = "localhost",
        user = os.getenv("USER") or "dev",
        name = "folder-check",
      })
    end)
    at(3.5, function()
      App.switch("terminal", { id = rec.id })
    end)
    at(0.8, function()
      App.core.write(rec.id, App.sessions.cdCommand(base) .. "ls -l\n")
    end)
    at(1.0, function()
      local sc = App.scene
      local tv = sc:view()
      local clicked = false
      for row = 0, tv.rows - 1 do
        local text = tv:rowText(row, 0, tv.cols - 1)
        if text:match("^d[rwx%-]") and text:find("my project", 1, true) then
          local col
          for x = 0, tv.cols - 1 do
            local token = require("src.terminal_files").at(tv, x, row)
            if token and token.literal == child then
              col = x
              break
            end
          end
          if col then
            local mx = (sc.px + (col + 0.5) * 8 * sc.zoom) / D.s
            local my = (sc.py + (row + 0.5) * 16 * sc.zoom) / D.s
            sc:mousepressed(mx, my, 1)
            sc:mousereleased(mx, my, 1)
            clicked = true
            break
          end
        end
      end
      check(
        "plain click checks a directory name with spaces and quotes",
        clicked and sc.folderProbe ~= nil
      )
    end)
    at(1.5, function()
      check(
        "folder click changed the real SSH shell cwd",
        App.core.cwd(rec.id) == base .. "/" .. child,
        App.core.cwd(rec.id)
      )
      check("folder bar follows automatic cd", App.scene.displayedFolder == App.core.cwd(rec.id))
      shot("qa_folder_click")
    end)
    at(0.2, function()
      local found = false
      for _, b in ipairs(App.scene.buttons) do
        if b.id == "parentFolder" then
          b.fn()
          found = true
          break
        end
      end
      check("cd .. button is available", found)
    end)
    at(1.0, function()
      check(
        "cd .. returned the real shell to its parent",
        App.core.cwd(rec.id) == base,
        App.core.cwd(rec.id)
      )
      shot("qa_folder_parent")
    end)
    finish(0.4)
    return
  end

  if phase == "files" then
    local rec, panel
    at(0.5, function()
      setMode(1280, 900)
      App.setOrientation("landscape")
      rec = App.sessions.open({
        host = "localhost",
        user = os.getenv("USER") or "dev",
        name = "files-check",
      })
    end)
    at(3.5, function()
      App.switch("terminal", { id = rec.id })
    end)
    at(0.8, function()
      check(
        "terminal has direct UPLOAD and DOWNLOAD buttons",
        (function()
          for _, b in ipairs(App.scene.buttons) do
            if b.id == "download" then
              return true
            end
          end
        end)()
      )
      panel = App.push("files", { id = rec.id })
    end)
    at(2, function()
      check(
        "local and remote folders loaded",
        panel.data.panes[1].loaded and panel.data.panes[2].loaded,
        panel.data.error
      )
      shot("qa_files_landscape")
      local before = App.core.typing(rec.id)
      panel:keypressed("l", ctrl)
      panel:textinput("/tmp")
      check("file browser input stays out of the terminal", App.core.typing(rec.id) == before)
      panel:keypressed("return", none)
    end)
    at(1, function()
      panel:prepare("upload", "/tmp/example file.txt")
      check("upload reviews a destination before starting", panel.confirm and not panel.data.active)
      shot("qa_files_upload")
    end)
    at(0.5, function()
      panel:keypressed("escape", none)
      setMode(800, 1400)
      App.setOrientation("portrait")
    end)
    at(0.8, function()
      shot("qa_files_portrait")
      check(
        "portrait still has both file lists",
        panel.data.panes[1].visible > 0 and panel.data.panes[2].visible > 0
      )
    end)
    at(0.5, function()
      App.pop(panel)
      setMode(1280, 900)
      App.setOrientation("landscape")
    end)
    at(0.7, function()
      panel = App.push("transfer", { id = rec.id, op = "download", path = "report.txt" })
      check(
        "terminal download resolves cwd and filename",
        panel.source == App.core.cwd(rec.id) .. "/report.txt"
          and panel.field.value:match("/Downloads/report.txt$")
      )
    end)
    at(0.4, function()
      shot("qa_terminal_download")
      App.pop(panel)
    end)
    at(0.4, function()
      panel = App.push("transfer", { id = rec.id, op = "upload", path = "/tmp/example file.txt" })
      check(
        "terminal drop infers destination filename",
        panel.field.value == App.core.cwd(rec.id) .. "/example file.txt"
      )
    end)
    at(0.4, function()
      shot("qa_terminal_upload")
      App.pop(panel)
      App.core.write(rec.id, "printf '\\nreport.txt  notes.md\\n'\n")
    end)
    at(0.6, function()
      local sc = App.scene
      for _, b in ipairs(sc.buttons) do
        if b.id == "download" then
          b.fn()
          break
        end
      end
      check(
        "DOWNLOAD button enables filename picking",
        sc.downloadPicking and not App.hasOverlay("transfer")
      )
      local tv = sc:view()
      for row = 0, tv.rows - 1 do
        if tv:rowText(row, 0, tv.cols - 1):match("^report.txt  notes.md") then
          love.mouse.setPosition(
            D.ox * D.s + sc.px + 12,
            D.oy * D.s + sc.py + row * 16 * sc.zoom + 8
          )
          break
        end
      end
    end)
    at(0.3, function()
      check("picking highlights the hovered filename", App.scene.hoverFilename == "report.txt")
      check(
        "terminal displays the live shell folder",
        App.scene.displayedFolder == App.core.cwd(rec.id) and App.scene.displayedFolder ~= ""
      )
      shot("qa_terminal_download_pick")
    end)
    at(0.2, function()
      App.scene:keypressed("escape", none)
    end)
    finish(0.5)
    return
  end

  if phase == "restorewrite" or phase == "restoreread" then
    -- Visible text of a session's screen, one string per row.
    local function screenText(id)
      local cells, cols, rows = App.core.snapshot(id)
      local out = {}
      for r = 0, rows - 1 do
        local t = {}
        for c = 0, cols - 1 do
          local cell = cells[r * cols + c]
          if cell.width ~= 0 then
            t[#t + 1] = cell.cp == 0 and " " or utf8.char(cell.cp)
          end
        end
        out[#out + 1] = table.concat(t)
      end
      return table.concat(out, "\n")
    end
    -- No test-installed hook: the application must track ordinary shells.
    local hook = "cd /tmp\n"
    at(1, function()
      App.sessions.persistSessions = true
      if phase == "restorewrite" then
        App.sessions.open({ host = "localhost", user = os.getenv("USER") or "dev", name = "mary-1" })
        App.sessions.open({ host = "localhost", user = os.getenv("USER") or "dev", name = "john-2" })
      else
        -- forget the per-host memory so the JSONL record alone must carry it
        App.core.kvSet("cwd." .. (os.getenv("USER") or "dev") .. "@localhost:22", "")
        App.sessions.restore(App.termGrid())
      end
      App.switch("map2")
    end)
    at(3, function()
      check(
        "two sessions connected after " .. phase,
        #App.sessions.list == 2
          and App.core.state(App.sessions.list[1].id) == App.core.ST.CONNECTED
          and App.core.state(App.sessions.list[2].id) == App.core.ST.CONNECTED
      )
      if phase == "restorewrite" then
        App.sessions.rename(App.sessions.list[2].id, "work-2")
        check(
          "renamed session written to JSONL",
          App.core.sessionsLoad():find("work-2", 1, true) ~= nil
        )
        App.core.write(App.sessions.list[2].id, hook)
      else
        check(
          "names survived a separate app process",
          App.sessions.list[1].name == "mary-1" and App.sessions.list[2].name == "work-2"
        )
        check(
          "restored session carries the saved directory",
          App.sessions.list[2].wantCwd == "/tmp" or App.sessions.list[2].cwd == "/tmp"
        )
        App.core.write(App.sessions.list[2].id, "pwd\n")
      end
    end)
    at(1.5, function()
      local rec = App.sessions.list[2]
      if phase == "restorewrite" then
        check(
          "core sees the OSC 7 directory report",
          App.core.cwd(rec.id) == "/tmp",
          App.core.cwd(rec.id)
        )
        check("directory kept on the session record", rec.cwd == "/tmp", tostring(rec.cwd))
        check(
          "directory written to JSONL",
          App.core.sessionsLoad():find('"cwd":"/tmp"', 1, true) ~= nil,
          App.core.sessionsLoad()
        )
        check(
          "directory remembered for the host",
          App.sessions.lastCwd(rec) == "/tmp",
          tostring(App.sessions.lastCwd(rec))
        )
      else
        local text = screenText(rec.id)
        check("cd was typed after the prompt settled", rec.wantCwd == nil)
        check(
          "restored shell is back in /tmp (pwd prints it)",
          text:find("\n/tmp%s*\n") ~= nil or text:find("\n/private/tmp%s*\n") ~= nil,
          text
        )
        App.sessions.close(App.sessions.list[1].id)
        check(
          "explicit close persisted",
          #require("src.json").decode(App.core.sessionsLoad()).hosts == 1
        )
      end
      shot("qa_" .. phase)
    end)
    finish(0.5)
    return
  end

  if phase == "maps" then
    local connected, second
    at(1, function()
      setMode(1280, 800)
      App.setOrientation("landscape")
      App.sessions.hosts = {}
      App.sessions.saveHosts()
      local cols, rows = App.termGrid()
      connected = App.sessions.open({
        host = "localhost",
        port = 22,
        user = os.getenv("USER") or "dev",
        cols = cols,
        rows = rows,
      })
      second = App.sessions.open({
        host = "localhost",
        port = 22,
        user = os.getenv("USER") or "dev",
        cols = cols,
        rows = rows,
      })
      App.switch("map2")
    end)
    at(3, function()
      check("real core loaded", not App.core.mock)
      check(
        "local server connected",
        connected and App.core.state(connected.id) == App.core.ST.CONNECTED
      )
      check(
        "connection automatically became a favorite",
        #App.sessions.hosts == 1 and App.sessions.hosts[1].favorite
      )
      check("map2 renders the live session", App.sceneName == "map2" and #App.scene.shown == 2)
      shot("qa_map2_grid")
      App.scene.field.value = "localhost"
      App.scene:refresh()
      App.scene:setFilter(2)
    end)
    at(0.5, function()
      check("map2 search and online filter", #App.scene.shown == 2)
      shot("qa_map2_filtered")
    end)
    at(0.3, function()
      setMode(800, 1400)
    end)
    at(0.5, function()
      shot("qa_map2_portrait")
    end)
    at(0.3, function()
      setMode(1280, 800)
      App.switch("map")
    end)
    at(1, function()
      check(
        "Mario map has separate stages for two real sessions",
        #App.scene.hosts == 2 and connected.mapPlatform ~= second.mapPlatform
      )
      local selected = {}
      local originalSwitch = App.switch
      App.switch = function(name, params)
        if name == "terminal" then
          selected[params.id] = true
        end
      end
      for _, h in ipairs(App.scene.hosts) do
        App.scene:connect(require("src.mapgraph").slot(h.platform) + 1)
      end
      App.switch = originalSwitch
      check("both real map sessions are selectable", selected[connected.id] and selected[second.id])
      shot("qa_map_clean")
    end)
    at(0.3, function()
      setMode(800, 1400)
      App.setOrientation("portrait")
    end)
    at(0.5, function()
      check(
        "portrait map covers the tall view (pans sideways)",
        App.scene.L.infoH == 112
          and App.scene.L.mapH == App.scene.L.viewH
          and App.scene.L.mapW > App.D.vw
      )
      local fits = true
      for i = 1, #App.scene.nodes.platforms do
        local _, y = App.scene:toScreen(App.scene:nodeMapPos(i))
        fits = fits and y >= 0 and y <= App.scene.L.viewH
      end
      check("all portrait map stages are within the view's height", fits)
      shot("qa_map_portrait")
    end)
    at(0.3, function()
      local sc = App.scene
      sc:keypressed("down", { shift = true })
      sc:mousepressed(100, 100, 2)
      sc:mousemoved(100, 40)
      sc:mousereleased(100, 40, 2)
      check(
        "portrait map pans sideways only (camera y fixed at 0)",
        sc.cam.y == 0 and sc.cam.x >= 0 and sc.cam.x <= sc.L.mapW - sc.L.viewW
      )
      shot("qa_map_panned")
    end)
    at(0.3, function()
      App.scene:recenter()
      local b = App.displayButtons()[2]
      App.mousepressed((b.x + 1) * App.D.s, (b.y + 1) * App.D.s, 1)
      check("orientation toggle changes mode", not App.D.portrait)
      App.setOrientation("portrait")
      local UI = require("src.ui")
      local field = UI.field("host", "", { historyKey = "connect.host" })
      field:textinput("localhost")
      field:remember()
      local nextField = UI.field("host", "", { historyKey = "connect.host", restore = true })
      check("editbox restores SQLite value without retyping", nextField.value == "localhost")
      nextField.value = "local"
      check(
        "live SQLite suggestion completes with one chord",
        nextField:acceptSuggestion() and nextField.value == "localhost"
      )
      check("favorites JSONL roundtrip", App.core.favoritesLoad():find("localhost", 1, true) ~= nil)
    end)
    at(0.3, function()
      local mx, my = App.scene:toScreen(App.scene:nodeMapPos(4))
      App.scene:mousepressed(mx, my - 6, 1)
    end)
    at(0.5, function()
      check("click empty stage opens connection form", App.hasOverlay("connect"))
      local form = App.overlays[#App.overlays]
      check("form remembers clicked stage", form.params.platform == 3)
      shot("qa_map_empty_connect")
    end)
    at(0.3, function()
      key("escape")
      App.switch("terminal", { id = connected.id })
      App.core.write(connected.id, "PS1='$ '\r")
    end)
    at(0.8, function()
      App.core.write(connected.id, "echo cbo_autocomplete_check")
    end)
    at(0.4, function()
      App.core.write(connected.id, "\r")
    end)
    at(0.8, function()
      local results = App.core.complete(connected.hostId or 0, "echo cbo_auto", 8)
      local learned = false
      for _, row in ipairs(results) do
        if row.cmd == "echo cbo_autocomplete_check" then
          learned = true
        end
      end
      check(
        "real echoed shell command learned in SQLite without raw recording",
        learned and not App.core.recordEnabled()
      )
      App.core.write(connected.id, "echo cbo_auto")
    end)
    at(0.4, function()
      App.scene:refreshCompletion()
      check(
        "terminal shows real-time learned suggestion",
        App.scene.suggestion == "echo cbo_autocomplete_check"
      )
      shot("qa_terminal_completion")
    end)
    at(0.3, function()
      App.scene:acceptCompletion()
      check(
        "completion fills line without executing it",
        App.core.typing(connected.id) == "echo cbo_autocomplete_check"
      )
      App.core.write(connected.id, "\21")
      -- a prompt that ends in an emoji (no $ % # >): readiness comes from the echo
      App.core.write(connected.id, "PS1='🍎 '\r")
    end)
    at(0.8, function()
      App.core.write(connected.id, "echo cbo_auto")
    end)
    at(0.5, function()
      App.scene:refreshCompletion()
      check(
        "emoji prompt still gets the real-time suggestion",
        App.scene.suggestion == "echo cbo_autocomplete_check",
        tostring(App.scene.suggestion)
      )
      check("ghost text is the missing suffix", App.scene:ghostText() == "complete_check")
      shot("qa_terminal_ghost_emoji_prompt")
    end)
    at(0.3, function()
      App.scene:keypressed("right", { ctrl = false, shift = false, alt = false, gui = false })
      check(
        "Right arrow accepts the ghost text under an emoji prompt",
        App.core.typing(connected.id) == "echo cbo_autocomplete_check"
      )
      App.core.write(connected.id, "\21")
      App.switch("map2")
    end)
    at(1.4, function()
      check(
        "return to Map2 finishes at natural scale",
        App.sceneName == "map2" and App.camera.zoom == 1
      )
      App.scene.field.value = ""
      App.scene:setFilter(1)
      App.scene:open(2)
    end)
    at(0.25, function()
      check(
        "Map2 zoom starts before changing scene",
        App.sceneName == "map2" and App.camera.zoom > 1 and App.camera.zoom < 2.8
      )
      check(
        "repeated selection cannot start another transition",
        not App.switch("terminal", { id = connected.id })
      )
      shot("qa_map2_zoom")
    end)
    at(1.1, function()
      check(
        "Map2 zoom opens exact selected session",
        App.sceneName == "terminal" and App.scene.id == second.id and App.camera.zoom == 1
      )
      App.switch("map")
    end)
    at(1.4, function()
      check(
        "map return remembers the same session stage",
        App.scene:hostAt(App.scene.sel)._session == second
      )
      App.scene:connect(App.scene.sel)
    end)
    at(0.25, function()
      check(
        "Mario map also zooms smoothly before switching",
        App.sceneName == "map" and App.camera.zoom > 1
      )
      shot("qa_map_zoom")
    end)
    at(1.1, function()
      check(
        "Mario zoom arrives at exact session",
        App.sceneName == "terminal" and App.scene.id == second.id
      )
      App.disconnectSession(second)
      check("disconnect saves intent before animation finishes", second.closing and App.iris ~= nil)
    end)
    at(0.3, function()
      check("disconnect circle closes before scene swap", App.iris and not App.iris.closed)
      shot("qa_disconnect_circle")
    end)
    at(1, function()
      check(
        "disconnect reveals selected lobby with other session intact",
        App.sceneName == App.lobbyView()
          and App.iris == nil
          and App.sessions.get(second.id) == nil
          and App.core.state(connected.id) == App.core.ST.CONNECTED
      )
      App.switch("map2")
    end)
    at(1.2, function()
      App.scene.field.value = ""
      App.scene:refresh()
      App.scene:disconnectMenu(1)
      local menu = App.top()
      check("Map2 offers an explicit Disconnect choice", menu.items[1][1] == "Disconnect")
      menu:pick(1)
    end)
    at(1.2, function()
      check(
        "Map2 disconnect finishes without losing favorite",
        App.sessions.get(connected.id) == nil and #App.sessions.hosts == 1
      )
    end)
    finish(1)
    return
  end

  if phase == "art" then
    at(1.3, function()
      shot("shot_boot")
      key("space")
    end)
    at(2.9, function()
      shot("shot_lobby")
    end)
    at(0.3, function()
      connectLocalhost()
    end)
    at(0.6, function()
      typeText("localhost")
      shot("shot_connect")
      key("return")
    end)
    at(2.2, function()
      key("return")
    end)
    at(1.4, function()
      line("ls")
      line("echo 你好 안녕 こんにちは Příliš žluťoučký kůň")
    end)
    at(1.0, function()
      shot("shot_terminal")
      term():toggleAI()
    end)
    at(0.6, function()
      line("how do I see who holds port 22?")
    end)
    at(1.5, function()
      shot("shot_ai_thinking")
    end)
    local aiWait = App.core.mock and 3 or 24
    at(aiWait, function()
      shot("shot_ai")
      key("escape")
      App.push("settings")
    end)
    at(0.7, function()
      shot("shot_settings")
    end)
    finish()
    return
  end

  if phase == "map" then
    -- three saved hosts (localhost live + a black hole + an invalid name),
    -- park the hero two stages away and walk him back to localhost
    local user = os.getenv("USER") or "dev"
    local target, startX, sc
    at(3.4, function()
      check("lobby reached", App.sceneName == "lobby")
      App.sessions.hosts = {} -- exactly three stages for the capture
      App.sessions.rememberHost({ host = "10.255.255.1", port = 22, user = user })
      App.sessions.rememberHost({ host = "nosuch.invalid", port = 22, user = user })
      local cols, rows = App.termGrid()
      local rec = App.sessions.open({
        host = "localhost",
        port = 22,
        user = user,
        cols = cols,
        rows = rows,
        keepalive = 15,
      })
      check("localhost session opened", rec ~= nil)
    end)
    at(2.5, function()
      local rec = App.sessions.list[1]
      check("localhost connected", rec and rec.state == App.core.ST.CONNECTED)
      App.switch("map")
    end)
    at(1.0, function()
      sc = App.scene
      check("map scene", App.sceneName == "map")
      check("3 stages on the map", #sc.hosts == 3, #sc.hosts)
      for slot = 1, 8 do
        local h = sc:hostAt(slot)
        if h and h.host == "localhost" then
          target = slot
        end
      end
      check("localhost has a platform", target ~= nil)
      shot("qa_map")
      sc.hero.slot = math.min(#sc.nodes.platforms, (target or 1) + 2)
      sc:placeHero(true)
      sc.sel = target or 1
      startX = sc.hero.x
      check("walk started", sc:startWalk(target or 1))
      local dur = require("src.mapgraph").walkDuration(sc.hero.path or {})
      info("walk duration", string.format("%.2fs", dur))
      -- the arrival shot is scheduled from the measured walk duration
      fx.after(dur + 0.08, function()
        shot("qa_map_arrived")
        check(
          "hero arrived on localhost",
          sc.hero.slot == target and sc.hero.state ~= "walk",
          sc.hero.state
        )
        check("confetti burst", fx.particleCount("confetti") >= 20, fx.particleCount("confetti"))
      end)
    end)
    at(0.4, function()
      shot("qa_map_walk")
      check("hero is walking and moved", sc.hero.state == "walk" and sc.hero.x ~= startX)
      check("hero faces left (dx < 0)", sc.hero.facing == -1)
      check("dust puffs spawned", fx.particleCount("dust") > 0, fx.particleCount("dust"))
    end)
    at(2.2, function()
      check("live session focused -> terminal", App.sceneName == "terminal")
      shot("qa_map_terminal")
    end)
    finish()
    return
  end

  if phase == "display" then
    -- F11: fullscreen and back, grid + core agree both ways
    local user = os.getenv("USER") or "dev"
    local g0
    at(3.4, function()
      local cols, rows = App.termGrid()
      App.sessions.open({
        host = "localhost",
        port = 22,
        user = user,
        cols = cols,
        rows = rows,
        noRemember = true,
      })
    end)
    at(2.5, function()
      App.switch("terminal", { id = App.sessions.list[1].id })
    end)
    at(1.0, function()
      g0 = { App.scene.cols, App.scene.rows }
      shot("qa_display_window")
      App.setFullscreen(true)
    end)
    at(1.4, function()
      shot("qa_display_fullscreen")
      local sc = App.scene
      local i = App.core.info(sc.id)
      check(
        "fullscreen on",
        D.fullscreen == true and love.window.getFullscreen() == true,
        tostring(love.window.getFullscreen())
      )
      check(
        "grid changed with the window",
        sc.cols ~= g0[1] or sc.rows ~= g0[2],
        sc.cols .. "x" .. sc.rows .. " was " .. g0[1] .. "x" .. g0[2]
      )
      check("core grid agrees (fullscreen)", i and i.cols == sc.cols and i.rows == sc.rows)
      App.setFullscreen(false)
    end)
    at(1.4, function()
      shot("qa_display_window2")
      local sc = App.scene
      local i = App.core.info(sc.id)
      check(
        "window restored",
        D.fullscreen == false and sc.cols == g0[1] and sc.rows == g0[2],
        sc.cols .. "x" .. sc.rows
      )
      check("core grid agrees (window)", i and i.cols == sc.cols and i.rows == sc.rows)
      check("display mode persisted", App.cfg.get().display == "window")
    end)
    finish()
    return
  end

  if phase == "portrait" then
    local Term = require("src.scenes.terminal")
    local user = os.getenv("USER") or "dev"
    at(3.4, function()
      setMode(800, 1400)
    end)
    at(0.8, function()
      check("auto orientation is portrait at 800x1400", D.portrait == true, D.vw .. "x" .. D.vh)
      check("portrait keeps the 2x ui scale", D.s == 2, D.s)
      check("lobby columns <= 2", App.scene:columns() <= 2, App.scene:columns())
      shot("qa_portrait_lobby")
      local cols, rows = App.termGrid()
      App.sessions.open({
        host = "localhost",
        port = 22,
        user = user,
        cols = cols,
        rows = rows,
        keepalive = 15,
      })
    end)
    at(2.5, function()
      App.switch("terminal", { id = App.sessions.list[1].id })
    end)
    at(1.0, function()
      term():toggleAI()
    end)
    at(0.8, function()
      shot("qa_portrait_terminal_ai")
      local sc = App.scene
      local i = App.core.info(sc.id)
      check("AI panel docks below in portrait", Term.aiDock(D) == "bottom")
      check(
        "portrait terminal prints the full session name on a title row",
        sc:chromeTop() == 2 * Term.TAB_H and sc.py >= (2 * Term.TAB_H) * D.s,
        sc:chromeTop()
      )
      check("terminal keeps >= 24 rows with the panel open", sc.rows >= 24, sc.rows)
      check(
        "core grid agrees (portrait + AI)",
        i and i.cols == sc.cols and i.rows == sc.rows,
        i and (i.cols .. "x" .. i.rows) or "-"
      )
      key("escape")
    end)
    at(0.6, function()
      App.switch("map")
    end)
    at(1.0, function()
      shot("qa_portrait_map")
      check(
        "map covers the tall view in portrait",
        App.scene.L and App.scene.L.mapH == App.scene.L.viewH and App.scene.L.mapW > D.vw
      )
      check(
        "map info panel below the map",
        App.scene.L and App.scene.L.infoY == App.scene.L.viewY + App.scene.L.viewH
      )
      App.switch("lobby")
    end)
    at(0.8, function()
      setMode(1080, 800)
    end)
    at(0.8, function()
      shot("qa_portrait_back")
      check("landscape again at 1080x800", D.portrait == false)
    end)
    finish()
    return
  end

  if phase == "hero" then
    -- two consecutive animation frames of the lobby hero: the feet/chair
    -- region must not move (the strip is anchored bottom-centre)
    local Lobby = require("src.scenes.lobby")
    local rect, first
    local function heroRect()
      local hero = Lobby.heroStrip(App.G)
      local sy = App.scene:shelfY()
      local rx, ry = D.ox + 16, D.oy + sy + 3 - hero.fh
      return { x = rx * D.s, y = ry * D.s, w = hero.fw * D.s, h = hero.fh * D.s }
    end
    at(3.4, function()
      check("lobby reached", App.sceneName == "lobby")
      rect = heroRect()
      love.graphics.captureScreenshot(function(img)
        first = img
        img:encode("png", "qa_hero_a.png")
      end)
    end)
    at(0.334, function()
      love.graphics.captureScreenshot(function(img)
        img:encode("png", "qa_hero_b.png")
        -- only pixels the sprite itself paints (either frame) count: the
        -- parallax scrolls behind the transparent parts of the figure
        local hero = Lobby.heroStrip(App.G)
        local function painted(sx, sy)
          for f = 1, hero.n do
            local _, _, _, a = hero.data:getPixel((f - 1) * hero.fw + sx, sy)
            if a > 0.5 then
              return true
            end
          end
          return false
        end
        local function diff(y0, y1)
          local d, tot = 0, 0
          for y = y0, y1 - 1 do
            for x = rect.x, rect.x + rect.w - 1 do
              local sx = math.floor((x - rect.x) / D.s)
              local sy = math.floor((y - rect.y) / D.s)
              if painted(sx, sy) then
                local r1, g1, b1 = first:getPixel(x, y)
                local r2, g2, b2 = img:getPixel(x, y)
                tot = tot + 1
                if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.25 then
                  d = d + 1
                end
              end
            end
          end
          return d / math.max(1, tot)
        end
        local feet = diff(rect.y + math.floor(rect.h * 0.7), rect.y + rect.h)
        local upper = diff(rect.y, rect.y + math.floor(rect.h * 0.7))
        check(
          "hero feet/chair region stable between frames",
          feet < 0.01,
          string.format("%.3f", feet)
        )
        info("hero upper region (hands/keyboard) change", string.format("%.3f", upper))
      end)
    end)
    finish(0.6)
    return
  end

  if phase == "mock" then
    at(3.2, function()
      check("mock badge: core is mock", App.core.mock == true)
      shot("qa_mock_lobby")
      connectLocalhost()
    end)
    at(0.6, function()
      typeText("localhost")
      key("return")
    end)
    at(1.5, function()
      key("return")
    end)
    at(1.2, function()
      shot("qa_mock_terminal")
    end)
    finish()
    return
  end

  if phase == "verify" then
    at(0.5, function()
      local k, src = App.cfg.apiKey("openai")
      check(
        "5.1 fake key survived restart (config.json)",
        k == "sk-qa-fake-key-1234567890" and src == "settings",
        k
      )
      check("5.1 masked in UI", App.cfg.mask(k) == "sk-********7890", App.cfg.mask(k))
      App.cfg.get().apiKeys.openai = ""
      App.cfg.save()
      check("5.1 key cleared again", App.cfg.apiKey("openai") ~= "sk-qa-fake-key-1234567890")
    end)
    finish()
    return
  end

  if phase == "limit" then
    local ids = {}
    at(3.2, function()
      local S = App.sessions
      local t0 = love.timer.getTime()
      for _ = 1, 128 do
        local rec = S.open({
          host = "10.255.255.1",
          port = 22,
          user = "qa",
          cols = 80,
          rows = 24,
          noRemember = true,
        })
        if not rec then
          break
        end
        ids[#ids + 1] = rec.id
      end
      check("4.16 128 opens succeed", #ids == 128, #ids)
      check("4.17 core count 128", App.core.count() == 128, App.core.count())
      info("4.16 128 opens took", string.format("%.0f ms", (love.timer.getTime() - t0) * 1000))
      connectLocalhost()
    end)
    at(0.6, function()
      typeText("10.255.255.1")
      key("return")
    end)
    at(0.5, function()
      local ov = App.overlays[#App.overlays]
      check(
        "4.16 129th refused: dialog shows the error",
        ov and ov.error ~= nil and ov.error:find("128") ~= nil,
        ov and ov.error
      )
      check("4.16 129th open returns -1 (still 128)", App.core.count() == 128)
      shot("qa_limit_dialog")
      key("escape")
    end)
    at(0.5, function()
      shot("qa_limit_lobby")
      App.scene.sel = 128
    end)
    at(0.8, function()
      shot("qa_limit_lobby_scrolled")
      info("4.19 lobby fps with 128 cards", love.timer.getFPS())
      check("4.19 lobby fps >= 30 with 128 cards", love.timer.getFPS() >= 30, love.timer.getFPS())
      for _, id in ipairs(ids) do
        App.sessions.close(id)
      end
    end)
    at(1.5, function()
      check(
        "4.18 close+free all -> count 0",
        App.core.count() == 0 and App.sessions.count() == 0,
        App.core.count()
      )
      local rec = App.sessions.open({
        host = "localhost",
        port = 22,
        user = os.getenv("USER"),
        cols = 80,
        rows = 24,
        noRemember = true,
      })
      check("4.18 reopen gets a low id", rec and rec.id == 0, rec and rec.id)
      if rec then
        App.sessions.close(rec.id)
      end
    end)
    finish(1.0)
    return
  end

  if phase == "perf" then
    at(3.2, function()
      connectLocalhost()
    end)
    at(0.5, function()
      typeText("localhost")
      key("return")
    end)
    at(2.0, function()
      key("return")
    end)
    at(1.2, function()
      connectLocalhost(true)
    end)
    at(0.4, function()
      typeText("localhost")
      key("return")
    end)
    at(2.0, function()
      connectLocalhost(true)
    end)
    at(0.4, function()
      typeText("localhost")
      key("return")
    end)
    local samples = {}
    local renders0
    local function alive()
      local n = 0
      for _, rec in ipairs(App.sessions.list) do
        if rec.state == App.core.ST.CONNECTED then
          n = n + 1
        end
      end
      return n
    end
    local function states()
      local out = {}
      for _, rec in ipairs(App.sessions.list) do
        out[#out + 1] = App.core.stateName(rec.state) .. " " .. App.core.error(rec.id)
      end
      return table.concat(out, " | ")
    end
    -- stage A: one 5 MB burst per session (macOS head has no -c 5M)
    at(2.0, function()
      check("perf: 3 sessions", App.sessions.count() == 3, App.sessions.count())
      renders0 = App.view(App.scene.id).renders
      for _, rec in ipairs(App.sessions.list) do
        App.core.write(rec.id, "yes | head -c 5000000; echo YES_DONE\r")
      end
    end)
    for i = 1, 8 do
      at(0.25, function()
        samples[#samples + 1] = love.timer.getFPS()
        if i == 2 then
          shot("qa_perf_yes")
        end
      end)
    end
    at(0.3, function()
      local tv = App.view(App.scene.id)
      info("perf A: fps samples during 3 x 5 MB", table.concat(samples, " "))
      info("perf A: canvas redraws", tv.renders - renders0)
      check("perf A: fps >= 50 during 3 x 5 MB of `yes`", math.min(unpack(samples)) >= 50)
      check(
        "perf A: grid redrew (>= 10 redraws)",
        tv.renders - renders0 >= 10,
        tv.renders - renders0
      )
      check("perf A: all 3 sessions still CONNECTED after 5 MB each", alive() == 3, states())
      App.push("help")
    end)
    at(0.3, function()
      check("perf: help overlay opened while scrolling", App.hasOverlay("help"))
      shot("qa_perf_help")
      key("escape")
    end)
    -- stage B: sustained 1 GB per session (200 x 5 MB), sampled for 4 s
    samples = {}
    at(0.5, function()
      renders0 = App.view(App.scene.id).renders
      for _, rec in ipairs(App.sessions.list) do
        App.core.write(
          rec.id,
          "for i in $(seq 1 200); do yes | head -c 5000000; done; echo YES_DONE\r"
        )
      end
    end)
    for _ = 1, 16 do
      at(0.25, function()
        samples[#samples + 1] = love.timer.getFPS()
      end)
    end
    at(0.3, function()
      local tv = App.view(App.scene.id)
      info("perf B: fps samples during 3 x 1 GB", table.concat(samples, " "))
      info("perf B: canvas redraws in 4 s", tv.renders - renders0)
      check("perf B: fps >= 50 during 3 x 1 GB of `yes`", math.min(unpack(samples)) >= 50)
      check("perf B: all 3 sessions still CONNECTED after the flood", alive() == 3, states())
      for _, rec in ipairs(App.sessions.list) do
        App.core.write(rec.id, "\x03")
      end
    end)
    finish(0.5)
    return
  end

  -- phase == "qa" ------------------------------------------------------------
  local firstName, thirdId
  local pingA
  at(1.3, function()
    check("1.3 boot scene", App.sceneName == "boot")
    check("core is real (not mock)", App.core.mock == false, App.core.path)
    shot("qa_boot")
    key("a")
    check("1.3 title ignores other keys", App.sceneName == "boot")
    key("space")
  end)
  at(2.6, function()
    check("1.3 lobby after boot", App.sceneName == "map" or App.sceneName == "map2", App.sceneName)
    shot("qa_lobby_empty")
    App.push("help")
  end)
  at(0.5, function()
    shot("qa_help")
    key("escape")
  end)
  at(0.4, function()
    connectLocalhost()
  end)
  at(0.5, function()
    typeText("localhost")
    shot("qa_connect")
    key("return")
  end)
  at(2.5, function()
    local rec = App.sessions.list[1]
    check(
      "2.1 session CONNECTED within 2.5 s",
      rec and rec.state == App.core.ST.CONNECTED,
      rec and App.core.stateName(rec.state)
    )
    firstName = rec and rec.name
    check(
      "4.1 auto name adj-noun-NN",
      firstName and firstName:match("^[%w]+%-[%w%-]+%-%d%d$") ~= nil,
      firstName
    )
    shot("qa_lobby_one")
    key("return")
  end)
  at(1.2, function()
    local sc = term()
    check("2.1 terminal scene open", sc ~= nil)
    check(
      "grid >= 80x24 at " .. D.w .. "x" .. D.h .. " with bezel",
      sc and sc.cols >= 80 and sc.rows >= 24,
      sc and (sc.cols .. "x" .. sc.rows)
    )
    local info0 = App.core.info(sc.id)
    check(
      "4.20 core grid == scene grid",
      info0 and info0.cols == sc.cols and info0.rows == sc.rows,
      info0 and (info0.cols .. "x" .. info0.rows)
    )
    pingA = info0 and info0.last_ping_ms
    line(
      "rm -rf "
        .. QA_DIR
        .. "; mkdir -p "
        .. QA_DIR
        .. "; echo $(tput cols)x$(tput lines) > "
        .. QA_DIR
        .. "/tput1.txt"
    )
  end)
  at(0.4, function()
    line("ls -la ~")
  end)
  at(1.0, function()
    shot("qa_terminal_ls")
    line("clear")
  end)
  -- unicode: one echo per line so a dropped byte would show as a missing line
  for _, u in ipairs(M.UNICODE) do
    at(0.25, function()
      line("echo " .. u)
    end)
  end
  at(0.3, function()
    line("echo 你好 안녕 こんにちは Příliš žluťoučký kůň")
  end)
  at(0.3, function()
    -- a wide glyph must wrap whole at the right edge, never be cut in half
    line(
      "printf '%s' 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 012345678; echo 香港銅鑼灣 東京タワー 세션 이름"
    )
  end)
  at(0.3, function()
    line(
      "tput colors; for i in $(seq 0 15); do tput setaf $i; printf 'C%02d ' $i; done; tput sgr0; echo"
    )
  end)
  at(0.6, function()
    shot("qa_terminal_unicode")
    -- IME path: composed CJK text arrives through love.textinput
    line("cat > " .. QA_DIR .. "/ime.txt")
  end)
  at(0.4, function()
    App.textinput("你好")
    App.textinput("안녕")
    key("return")
    term():write("\x04")
  end)
  at(0.4, function()
    line("xxd " .. QA_DIR .. "/ime.txt")
    -- paste (Cmd+V)
    love.system.setClipboardText("echo PASTED_OK > " .. QA_DIR .. "/paste.txt\n")
    key("v", gui)
  end)
  local bells0
  at(0.8, function()
    shot("qa_terminal_ime_xxd")
    bells0 = term().bells
    line("printf '\\a'")
  end)
  at(0.5, function()
    local sc = term()
    check(
      "2.5 bell counted once (shake + flash)",
      sc and sc.bells == bells0 + 1,
      sc and (sc.bells - bells0)
    )
    line("printf '\\e]0;QA TITLE\\a'")
  end)
  at(0.5, function()
    check(
      "2.6 OSC title reaches the core",
      App.core.title(term().id) == "QA TITLE",
      App.core.title(term().id)
    )
    line("seq 1 500")
  end)
  at(1.0, function()
    -- the wheel over the tab strip opens the context menu: park the cursor on the grid
    love.mouse.setPosition(D.w / 2, D.h / 2)
    App.wheelmoved(0, 4)
    App.wheelmoved(0, 4)
  end)
  at(0.3, function()
    local sc = term()
    check("2.7 wheel scrolls back", App.core.scrollOffset(sc.id) > 0, App.core.scrollOffset(sc.id))
    key("pageup", shiftM)
  end)
  at(0.3, function()
    local sc = term()
    local off = App.core.scrollOffset(sc.id)
    check("2.7 Shift+PgUp scrolls a page further", off > 24, off)
    shot("qa_scrollback")
  end)
  at(0.3, function()
    App.core.scroll(term().id, 0)
    line("top -s 1")
  end)
  at(2.5, function()
    shot("qa_top")
    typeText("q")
  end)
  at(0.8, function()
    line("vim " .. QA_DIR .. "/qa.txt")
  end)
  at(1.0, function()
    typeText("i")
    typeText("hello office")
  end)
  at(0.4, function()
    shot("qa_vim_insert")
    key("escape") -- one Esc: raw ESC to vim, must NOT go to the lobby
  end)
  at(0.6, function()
    check("2.4 single Esc stayed in the terminal", App.sceneName == "terminal")
    line(":wq")
  end)
  at(0.8, function()
    line("cat " .. QA_DIR .. "/qa.txt")
    -- Esc Esc within 300 ms -> lobby
    key("escape")
    key("escape")
  end)
  at(1.2, function()
    check("Esc double-tap -> lobby", App.sceneName == "lobby")
    key("return")
  end)
  at(1.0, function()
    -- the first Esc of the double-tap went to zsh as a meta prefix: clear it
    App.core.write(term().id, " \x15")
  end)
  -- AI panel: reflow + thinking + scroll + insert
  local colsBefore, resizesBefore
  at(1.2, function()
    local sc = term()
    colsBefore, resizesBefore = sc.cols, sc.resizes
    sc:toggleAI()
  end)
  at(0.15, function()
    local sc = term()
    check(
      "AI open: no resize during the slide",
      sc.resizes == resizesBefore and sc.cols == colsBefore,
      sc.cols
    )
  end)
  at(0.5, function()
    local sc = term()
    local inf = App.core.info(sc.id)
    check(
      "AI open: grid reflowed once after the slide",
      sc.resizes == resizesBefore + 1 and sc.cols < colsBefore,
      sc.cols .. " (was " .. colsBefore .. ")"
    )
    check(
      "AI open: core resized to the new grid",
      inf.cols == sc.cols and inf.rows == sc.rows,
      inf.cols .. "x" .. inf.rows
    )
    check("AI open: grid still >= 80 cols", sc.cols >= 80, sc.cols)
    App.core.write(sc.id, "echo $(tput cols)x$(tput lines) > " .. QA_DIR .. "/tput_ai.txt\r")
  end)
  at(0.3, function()
    -- the panel owns the keyboard: this goes into the AI input
    typeText(
      "Show a bash one-liner that lists listening TCP ports on macOS, in a fenced code block, then explain in 5 bullet points, then give 3 more fenced code block variants."
    )
    key("return")
  end)
  at(1.5, function()
    local sc = term()
    check("5.2 request running", sc.ai.req ~= nil, sc.ai.error)
    check(
      "thinking state while STREAMING with no text",
      sc.ai:thinking(),
      sc.ai.streamText:sub(1, 20)
    )
    shot("qa_ai_thinking")
  end)
  local aiWait = App.core.mock and 4 or 60 -- gpt-5 reasons for 20-40 s before the text
  at(aiWait, function()
    local sc = term()
    local ans = sc.ai:lastAnswer()
    check(
      "5.2 answer streamed (DONE)",
      sc.ai.req == nil and ans ~= nil and #ans > 40,
      sc.ai.error or (ans and #ans)
    )
    info("5.2 answer length", ans and #ans)
    shot("qa_ai_answer")
    sc.ai:wheelmoved(5)
  end)
  at(0.4, function()
    local sc = term()
    check(
      "AI panel scrolls (wheel)",
      sc.ai.scrollTarget < math.max(0, (sc.ai.contentH or 0) - (sc.ai.viewH or 0)),
      sc.ai.scrollTarget
    )
    shot("qa_ai_scrolled")
    key("pagedown")
    key("pagedown")
    key("pagedown")
    -- Ctrl+Enter: only the code blocks go to the shell
    local ans = sc.ai:lastAnswer() or ""
    local ins = require("src.scenes.ai").insertText(ans)
    check(
      "^Enter inserts code blocks only",
      ans:find("```", 1, true) == nil or (#ins < #ans and ins:find("```", 1, true) == nil),
      #ins .. "/" .. #ans
    )
    App.core.write(sc.id, "cat > " .. QA_DIR .. "/insert.txt\r")
  end)
  at(0.3, function()
    key("return", ctrl)
  end)
  at(0.5, function()
    local sc = term()
    App.core.write(sc.id, "\x04")
    shot("qa_ai_inserted")
    key("escape") -- close the panel
  end)
  at(0.6, function()
    local sc = term()
    local inf = App.core.info(sc.id)
    check("AI close: grid restored", sc.cols == colsBefore and inf.cols == colsBefore, sc.cols)
    line("echo $(tput cols)x$(tput lines) > " .. QA_DIR .. "/tput_after_ai.txt")
    line("clear")
    -- zoom 2x
    key("=", ctrl)
  end)
  at(0.5, function()
    local sc = term()
    check("zoom 2x via Ctrl+=", D.termZoom == 2 and sc.zoom == 2, sc.zoom)
    check(
      "zoom 2x: grid halved and core resized",
      App.core.info(sc.id).cols == sc.cols and sc.cols < colsBefore,
      sc.cols
    )
    line(
      "echo $(tput cols)x$(tput lines) > "
        .. QA_DIR
        .. "/tput_zoom2.txt; echo zoom 2x: $(tput cols)x$(tput lines)"
    )
  end)
  at(0.6, function()
    shot("qa_zoom2")
  end)
  at(0.3, function()
    key("-", ctrl)
  end)
  at(0.4, function()
    local sc = term()
    check("zoom back to 1x via Ctrl+-", D.termZoom == 1 and sc.cols == colsBefore, sc.cols)
    App.setBezel(false)
  end)
  at(0.4, function()
    local sc = term()
    check(
      "bezel off: grid grew + core resized",
      sc.cols > colsBefore and App.core.info(sc.id).cols == sc.cols,
      sc.cols
    )
    line("echo $(tput cols)x$(tput lines) > " .. QA_DIR .. "/tput_nobezel.txt")
  end)
  at(0.6, function()
    shot("qa_nobezel")
  end)
  at(0.3, function()
    App.setBezel(true)
  end)
  at(0.4, function()
    local sc = term()
    check("bezel on: grid restored", sc.cols == colsBefore, sc.cols)
    setMode(1280, 800)
  end)
  at(0.8, function()
    local sc = term()
    info(
      "4.21 setMode(1280,800) actual window",
      D.w .. "x" .. D.h .. " grid " .. sc.cols .. "x" .. sc.rows
    )
    check(
      "4.21 core follows the window",
      App.core.info(sc.id).cols == sc.cols and App.core.info(sc.id).rows == sc.rows
    )
    line("echo $(tput cols)x$(tput lines) > " .. QA_DIR .. "/tput_1280.txt")
  end)
  at(0.5, function()
    shot("qa_resize_1280x800")
  end)
  at(0.3, function()
    setMode(1920, 1080)
  end)
  at(0.8, function()
    local sc = term()
    info(
      "4.21 setMode(1920,1080) actual window",
      D.w .. "x" .. D.h .. " grid " .. sc.cols .. "x" .. sc.rows
    )
    check("4.21 core follows the window (2)", App.core.info(sc.id).cols == sc.cols)
  end)
  at(0.5, function()
    local gw, gh = love.graphics.getDimensions()
    info("4.21 graphics dimensions vs D", gw .. "x" .. gh .. " vs " .. D.w .. "x" .. D.h)
    shot("qa_resize_1920x1080")
  end)
  at(0.3, function()
    setMode(800, 500)
  end)
  at(0.8, function()
    local sc = term()
    info(
      "4.22 setMode(800,500) actual window",
      D.w .. "x" .. D.h .. " grid " .. sc.cols .. "x" .. sc.rows
    )
    check("4.22 shrink: core follows", App.core.info(sc.id).cols == sc.cols)
  end)
  at(0.5, function()
    local gw, gh = love.graphics.getDimensions()
    info("4.22 graphics dimensions vs D", gw .. "x" .. gh .. " vs " .. D.w .. "x" .. D.h)
    shot("qa_resize_800x500")
  end)
  at(0.3, function()
    for i = 1, 10 do
      setMode(900 + i * 15, 600 + i * 10)
      App.resize(love.graphics.getDimensions())
    end
    setMode(1080, 800)
  end)
  at(0.8, function()
    local sc = term()
    check(
      "4.24 10 fast resizes: no error, core in sync",
      App.core.info(sc.id).cols == sc.cols,
      sc.cols .. "x" .. sc.rows
    )
    line("echo $(tput cols)x$(tput lines) > " .. QA_DIR .. "/tput_final.txt")
    line("vim " .. QA_DIR .. "/qa.txt")
  end)
  at(0.8, function()
    App.keypressed("f11")
    love.window.setVSync(0)
  end)
  at(1.2, function()
    local sc = term()
    info(
      "4.23 fullscreen",
      D.w .. "x" .. D.h .. " grid " .. sc.cols .. "x" .. sc.rows .. " fs=" .. tostring(D.fullscreen)
    )
    check(
      "4.23 fullscreen: vim grid == core grid",
      D.fullscreen and App.core.info(sc.id).cols == sc.cols
    )
    shot("qa_fullscreen_vim")
    App.keypressed("f11")
    love.window.setVSync(0)
  end)
  at(2.0, function()
    check(
      "1.8 back from fullscreen",
      not D.fullscreen and not love.window.getFullscreen(),
      D.w .. "x" .. D.h
    )
    key("escape")
  end)
  at(0.5, function()
    line(":q!")
  end)
  at(0.5, function()
    line("echo $$ > " .. QA_DIR .. "/pid1.txt")
    -- keepalive countdown: last_ping advanced since the start (> 15 s ago)
    local inf = App.core.info(term().id)
    check(
      "4.12 last_ping_ms advanced (keepalive ticking)",
      inf.last_ping_ms > (pingA or 0),
      (inf.last_ping_ms - (pingA or 0)) .. " ms"
    )
    shot("qa_status_keepalive")
    -- 3 sessions
    connectLocalhost(true)
  end)
  at(0.4, function()
    typeText("localhost")
    key("return")
  end)
  at(2.0, function()
    line("echo $$ > " .. QA_DIR .. "/pid2.txt")
    connectLocalhost(true)
  end)
  at(0.4, function()
    typeText("localhost")
    key("return")
  end)
  at(2.0, function()
    thirdId = term().id
    line("echo $$ > " .. QA_DIR .. "/pid3.txt")
    check("4.1 three sessions", App.sessions.count() == 3, App.sessions.count())
    local seen = {}
    local dup = false
    for _, r in ipairs(App.sessions.list) do
      if seen[r.name] then
        dup = true
      end
      seen[r.name] = true
    end
    check("4.1 names distinct", not dup)
    key("tab", ctrl)
  end)
  at(0.5, function()
    shot("qa_cycle_1")
    check(
      "4.3 Ctrl+Tab moved to session 1",
      App.sessions.index(term().id) == 1,
      App.sessions.index(term().id)
    )
    key("tab", ctrl)
    key("tab", ctrl)
  end)
  at(0.5, function()
    check(
      "4.3 cycles back around to 3",
      App.sessions.index(term().id) == 3,
      App.sessions.index(term().id)
    )
    key("tab", { ctrl = true, shift = true, alt = false, gui = false })
  end)
  at(0.5, function()
    check(
      "4.4 Ctrl+Shift+Tab goes backwards",
      App.sessions.index(term().id) == 2,
      App.sessions.index(term().id)
    )
    App.push("search")
  end)
  at(0.4, function()
    local adj, noun = firstName:match("^(%w+)%-(%w+)")
    typeText(adj:sub(1, 3) .. " " .. noun:sub(1, 2))
  end)
  at(0.4, function()
    local ov = App.overlays[#App.overlays]
    check(
      "4.5 multi-word fuzzy query finds session 1 first",
      ov.results[1] == App.sessions.list[1].id,
      table.concat(ov.results, ",")
    )
    shot("qa_search_multiword")
    ov.field.value = ""
    typeText("local")
  end)
  at(0.4, function()
    local ov = App.overlays[#App.overlays]
    check("4.6 host query matches all three", #ov.results == 3, #ov.results)
    key("escape")
  end)
  at(0.4, function()
    App.push("rename", { id = term().id })
  end)
  at(0.4, function()
    local ov = App.overlays[#App.overlays]
    ov.field.value = ""
    typeText("빌드-상자 香港")
    key("return")
  end)
  at(0.4, function()
    local rec = App.sessions.get(term().id)
    check(
      "3.9 Korean rename accepted",
      rec.name == "빌드-상자 香港" and App.core.getName(rec.id) == rec.name,
      rec.name
    )
    App.push("rename", { id = term().id })
  end)
  at(0.4, function()
    local ov = App.overlays[#App.overlays]
    ov.field.value = ""
    typeText(string.rep("x", 40))
    check(
      "4.8 40 chars truncated at 32 by the field",
      utf8.len(ov.field.value) == 32,
      utf8.len(ov.field.value)
    )
    key("escape")
  end)
  at(0.4, function()
    App.push("search")
  end)
  at(0.4, function()
    typeText("상자")
  end)
  at(0.4, function()
    local ov = App.overlays[#App.overlays]
    check(
      "3.9 search finds the Korean name",
      ov.results[1] == term().id,
      table.concat(ov.results, ",")
    )
    shot("qa_search_korean")
    key("escape")
  end)
  at(0.4, function()
    key("escape", ctrl)
  end)
  at(1.2, function()
    check("lobby via Ctrl+Esc", App.sceneName == "lobby")
    shot("qa_lobby_three")
    App.scene.sel = 3
    App.scene:closeSelected()
  end)
  at(0.4, function()
    shot("qa_lobby_closing")
  end)
  at(1.2, function()
    check(
      "4.9 Delete: card gone, count down",
      App.sessions.count() == 2 and App.core.count() == 2,
      App.sessions.count()
    )
    connectLocalhost()
  end)
  at(0.4, function()
    typeText("localhost")
    key("return")
  end)
  at(0.6, function()
    local rec = App.sessions.list[3]
    check("4.9 freed slot id reused", rec and rec.id == thirdId, rec and rec.id)
    check(
      "4.9 reused card slides in (anim reset)",
      rec and App.scene.anim[rec.id] and App.scene.anim[rec.id].scale == 1
    )
    shot("qa_lobby_reused")
    App.push("settings")
  end)
  at(0.4, function()
    local ov = App.overlays[#App.overlays]
    ov.sel = 5 -- openai key row
    ov:beginEdit(ov.rows[5])
    typeText("sk-qa-fake-key-1234567890")
  end)
  at(0.3, function()
    shot("qa_settings_editing")
    key("return")
  end)
  at(0.3, function()
    local ov = App.overlays[#App.overlays]
    check(
      "5.1 key masked in settings",
      ov:valueText(ov.rows[5]) == "sk-********7890",
      ov:valueText(ov.rows[5])
    )
    local raw = love.filesystem.read("config.json") or ""
    check("5.1 config.json holds the key", raw:find("sk-qa-fake-key-1234567890", 1, true) ~= nil)
    shot("qa_settings")
    key("escape")
  end)
  at(0.5, function()
    check("mock badge hidden with the real core", not App.core.mock)
    local hosts = love.filesystem.read("hosts.json") or ""
    check("4.10 hosts.json remembers localhost", hosts:find("localhost", 1, true) ~= nil)
  end)
  finish(0.5)
end

return M
