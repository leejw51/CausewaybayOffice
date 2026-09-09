-- In-engine tests: `love love2d -- --test`. Always runs against the mock core.
-- Prints TAP-ish lines, then "OK n tests" / "FAIL". Returns true on success.

local M = {}

function M.run(App)
  local ffi = require("ffi")
  local utf8 = require("utf8")
  local json = require("src.json")
  local Keys = require("src.keys")
  local fx = require("src.fx")
  local Core = App.core
  local Config = App.cfg
  local Sessions = App.sessions
  local TermView = require("src.term_view")
  local G = App.G

  local n, fails = 0, 0
  local function check(name, cond, detail)
    n = n + 1
    if cond then
      print("ok " .. n .. " - " .. name)
    else
      fails = fails + 1
      print(
        "not ok " .. n .. " - " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or "")
      )
    end
  end

  check("core is mock in test mode", Core.mock == true)

  -- json roundtrip
  local obj = {
    hosts = { { host = "localhost", port = 22, user = "lee", keypath = "", lastUsed = 1700000000 } },
    name = 'neon-tram-07 你好 "q" \\ \n',
    flag = true,
    neg = -3.5,
    empty = {},
  }
  local enc = json.encode(obj)
  local dec = json.decode(enc)
  check(
    "json roundtrip object",
    dec and dec.hosts[1].host == "localhost" and dec.hosts[1].port == 22
  )
  check("json roundtrip utf8 + escapes", dec and dec.name == obj.name, dec and dec.name)
  check("json roundtrip bool/neg", dec and dec.flag == true and dec.neg == -3.5)
  check("json pretty roundtrip", json.decode(json.encode(obj, true)).hosts[1].user == "lee")
  local u = json.decode('{"a":"\\u4f60\\u597d","b":[1,2,{"c":null}],"d":1e3}')
  check("json \\u escapes", u and u.a == "你好")
  check("json nested array", u and u.b[2] == 2 and type(u.b[3]) == "table")
  check("json exponent", u and u.d == 1000)
  check("json bad input", json.decode("{nope") == nil)

  -- keys
  local none = { ctrl = false, shift = false, alt = false, gui = false }
  local ctrl = { ctrl = true, shift = false, alt = false, gui = false }
  check("key return", Keys.translate("return", none) == "\r")
  check("key backspace", Keys.translate("backspace", none) == "\x7f")
  check("key escape", Keys.translate("escape", none) == "\x1b")
  check("key up", Keys.translate("up", none) == "\x1b[A")
  check("key pageup", Keys.translate("pageup", none) == "\x1b[5~")
  check("key delete", Keys.translate("delete", none) == "\x1b[3~")
  check("key f5", Keys.translate("f5", none) == "\x1b[15~")
  check("key ctrl+c", Keys.translate("c", ctrl) == "\x03")
  check("key ctrl+z", Keys.translate("z", ctrl) == "\x1a")
  check("key ctrl+[", Keys.translate("[", ctrl) == "\x1b")
  check("key plain letter goes via textinput", Keys.translate("a", none) == nil)
  check("chord ctrl+n reserved", Keys.appChord("n", ctrl) == "new")
  check("chord ctrl+k reserved", Keys.appChord("k", ctrl) == "search")
  check("chord ctrl+tab", Keys.appChord("tab", ctrl) == "cycle")
  check("chord ctrl+space", Keys.appChord("space", ctrl) == "ai")
  check("chord ctrl+,", Keys.appChord(",", ctrl) == "settings")
  check("chord ctrl+c NOT reserved", Keys.appChord("c", ctrl) == nil)
  check("chord cmd+v paste", Keys.appChord("v", { gui = true }) == "paste")

  -- easing
  for _, name in ipairs({ "linear", "expoIn", "expoOut", "expoInOut", "backOut" }) do
    local e = fx.ease[name]
    check(name .. "(0)=0", math.abs(e(0)) < 1e-9)
    check(name .. "(1)=1", math.abs(e(1) - 1) < 1e-9)
    local mono = true
    local prev = e(0)
    for i = 1, 100 do
      local v = e(i / 100)
      if name ~= "backOut" and v < prev - 1e-9 then
        mono = false
      end
      prev = v
    end
    check(name .. " monotonic", mono)
  end
  check("expoOut fast start", fx.ease.expoOut(0.25) > 0.8)

  -- mock core lifecycle
  local lib = require("src.core_mock")
  lib.reset()
  Sessions.init(Core)
  local id, err =
    Core.open({ host = "localhost", port = 22, user = "tester", cols = 40, rows = 10 })
  check("open returns id", id ~= nil and id >= 0, err)
  check("state connecting", Core.state(id) == Core.ST.CONNECTING)
  Core.update(0.3)
  check("still connecting at 0.3s", Core.state(id) == Core.ST.CONNECTING)
  Core.update(0.4)
  check("connected after 0.7s", Core.state(id) == Core.ST.CONNECTED)
  local info = Core.info(id)
  check("info host/user", info and info.host == "localhost" and info.user == "tester")
  check("info dims", info and info.cols == 40 and info.rows == 10)
  local gen0 = Core.generation(id)
  Core.write(id, "ls\r")
  check("generation bumps on write", Core.generation(id) > gen0)
  local cells, cols, rows, cnt = Core.snapshot(id)
  check("snapshot fills grid", cnt == 40 * 10 and cols == 40 and rows == 10)
  local cells2 = Core.snapshot(id)
  check("snapshot reuses buffer", cells2 == cells)
  local function screenText()
    local out = {}
    for r = 0, rows - 1 do
      local line = {}
      for c = 0, cols - 1 do
        local cell = cells[r * cols + c]
        if cell.width ~= 0 then
          line[#line + 1] = cell.cp == 0 and " " or require("utf8").char(cell.cp)
        end
      end
      out[#out + 1] = table.concat(line)
    end
    return table.concat(out, "\n")
  end
  local txt = screenText()
  check("ls output shows Cargo.toml", txt:find("Cargo.toml", 1, true) ~= nil)
  check("banner shows CJK", txt:find("你好", 1, true) ~= nil)
  -- find the wide cell and its continuation
  local wideOk = false
  for i = 0, cols * rows - 2 do
    if cells[i].cp == 0x4F60 then -- 你
      wideOk = cells[i].width == 2 and cells[i + 1].width == 0
    end
  end
  check("wide char = width 2 + continuation 0", wideOk)
  Core.write(id, "echo Příliš\r")
  cells = Core.snapshot(id)
  check("echo czech renders", screenText():find("Příliš", 1, true) ~= nil)
  check("utf8Width CJK", Core.utf8Width("你好") == 4)
  check("utf8Width czech", Core.utf8Width("Příliš") == 6)
  check("cursor visible", select(3, Core.cursor(id)) == true)
  Core.write(id, "bell\r")
  check("bell counted once", Core.takeBell(id) == 1 and Core.takeBell(id) == 0)
  -- keepalive
  local before = Core.info(id).last_ping_ms
  Core.update(15.5)
  check("keepalive ping after 15s", Core.info(id).last_ping_ms > before)
  -- scrollback
  for _ = 1, 15 do
    Core.write(id, "echo line\r")
  end
  check("scrollback grows", Core.scrollbackLen(id) > 0)
  Core.scroll(id, 3)
  check("scroll offset", Core.scrollOffset(id) == 3)
  Core.scroll(id, 0)
  Core.resize(id, 60, 12)
  local i2 = Core.info(id)
  check("resize applied", i2.cols == 60 and i2.rows == 12)
  Core.close(id)
  check("closed", Core.state(id) == Core.ST.CLOSED)
  Core.free(id)
  check("freed", Core.info(id) == nil)

  -- session naming uniqueness + model
  lib.reset()
  Sessions.init(Core)
  local names = {}
  local recs = {}
  for i = 1, 5 do
    local rec = Sessions.open({
      host = "h" .. i,
      port = 22,
      user = "u",
      cols = 20,
      rows = 5,
      noRemember = true,
    })
    recs[i] = rec
    names[rec.name] = (names[rec.name] or 0) + 1
  end
  local unique = true
  for _, c in pairs(names) do
    if c > 1 then
      unique = false
    end
  end
  check("5 sessions get unique names", unique)
  check("name format word-number", recs[1].name:match("^[%a]+%-%d+$") ~= nil, recs[1].name)
  check("core knows the name", Core.getName(recs[1].id) == recs[1].name)
  check(
    "nameGenerate avoids live names",
    Core.nameGenerate(os.time() + 1 * 131 + recs[1].id) ~= recs[1].name
  )
  check(
    "rename ok",
    Sessions.rename(recs[2].id, "香港-zqxv") and Core.getName(recs[2].id) == "香港-zqxv"
  )
  check("rename too long rejected", Sessions.rename(recs[2].id, string.rep("x", 33)) == false)
  Core.update(1)
  Sessions.update()
  check("sessions connected", recs[1].state == Core.ST.CONNECTED)
  -- search
  local hits = Core.search("zqxv")
  check("search finds renamed", #hits >= 1 and hits[1] == recs[2].id)
  local all = Core.search("")
  check("empty search lists all", #all == 5)
  local fz = Core.search("h3")
  check("fuzzy host match", #fz >= 1 and fz[1] == recs[3].id, fz[1])
  check("no match", #Core.search("zzzzqqq") == 0)
  -- close flow
  Sessions.close(recs[4].id)
  Sessions.update()
  check(
    "closed session removed from list",
    Sessions.count() == 4 and Sessions.get(recs[4].id) == nil
  )
  check("count", Core.count() == 4)
  -- neighbor cycling
  local nb = Sessions.neighbor(recs[5].id, 1)
  check("neighbor wraps", nb and nb.id == recs[1].id)

  -- hosts persistence
  Sessions.hosts = {}
  Sessions.rememberHost({ host = "example.hk", port = 2222, user = "lee" })
  Sessions.rememberHost({ host = "example.hk", port = 2222, user = "lee" })
  check("recent hosts dedupe", #Sessions.hosts == 1 and Sessions.hosts[1].port == 2222)
  Sessions.loadHosts()
  check("hosts.json persisted", Sessions.hosts[1] and Sessions.hosts[1].host == "example.hk")
  for i = 1, 14 do
    local added = Sessions.open({ host = "favorite-" .. i .. ".example", user = "u", port = 22 })
    check(
      "connection automatically favorites server " .. i,
      added and Sessions.findHost("u@favorite-" .. i .. ".example:22") ~= nil
    )
    if added then
      Core.close(added.id)
      Core.update(1)
      Sessions.remove(added.id)
    end
  end
  Sessions.loadHosts()
  check(
    "favorites retain every server beyond the old twelve-host cap",
    #Sessions.hosts == 15 and Sessions.findHost("lee@example.hk:2222") ~= nil
  )
  check(
    "QA fixtures are identifiable without excluding real hosts",
    Sessions.isDemoHost({ host = "mock-06.lan" })
      and not Sessions.isDemoHost({ host = "myserver.lan" })
  )

  -- config masking
  check("mask long key", Config.mask("sk-1234567890abcdef") == "sk-********cdef")
  check("mask hides middle", not Config.mask("sk-1234567890abcdef"):find("567890"))
  check("mask short key", Config.mask("abc") == "***")
  check("mask empty", Config.mask("") == "(not set)")
  check("default models", Config.model("openai") == "gpt-5" and Config.model("xai") == "grok-4.6")
  check("provider cycle", Config.nextProvider("xai") == "openai")

  -- term_view width handling on a hand-built snapshot
  local cols3, rows3 = 6, 1
  local hand = ffi.new("CboCell[?]", cols3 * rows3)
  local function set(i, cp, w, attr)
    hand[i].cp, hand[i].fg, hand[i].bg, hand[i].attr, hand[i].width =
      cp, 0xFFFFFF, 0x101830, attr or 0, w
  end
  set(0, string.byte("a"), 1)
  set(1, 0x4F60, 2) -- 你
  set(2, 0, 0) -- continuation
  set(3, string.byte("b"), 1, 1) -- bold
  set(4, 0x0159, 1, 4) -- ř underline
  set(5, 0, 1)
  local tv = TermView.new(nil, nil)
  local ok, e = pcall(function()
    tv:renderCells(hand, cols3, rows3)
  end)
  check("term_view renders hand-built snapshot", ok, e)
  check(
    "term_view canvas size",
    tv.canvas and tv.canvas:getWidth() == 48 and tv.canvas:getHeight() == 16
  )
  check("term_view rowText skips continuation", tv:rowText(0, 0, 5) == "a你bř")
  tv.sel = { x0 = 0, y0 = 0, x1 = 3, y1 = 0 }
  check("selection text", tv:selectedText() == "a你b")
  -- font metrics: Unifont wide glyph is exactly 2 cells
  check("unifont ascii advance 8", G.fontTerm:getWidth("a") == 8, G.fontTerm:getWidth("a"))
  check("unifont CJK advance 16", G.fontTerm:getWidth("你") == 16, G.fontTerm:getWidth("你"))
  check("unifont hangul advance 16", G.fontTerm:getWidth("안") == 16, G.fontTerm:getWidth("안"))
  check("unifont czech advance 8", G.fontTerm:getWidth("ř") == 8, G.fontTerm:getWidth("ř"))
  check("unifont height 16", G.fontTerm:getHeight() == 16, G.fontTerm:getHeight())
  check("ui font 8px", G.fontUI:getHeight() == 8, G.fontUI:getHeight())
  -- render glyphs onto a canvas and confirm the wide glyph paints pixels in both cells
  local data = tv.canvas:newImageData()
  local function lit(x0, x1)
    for x = x0, x1 do
      for y = 0, 15 do
        local r, g, b = data:getPixel(x, y)
        if r + g + b > 1.5 then
          return true
        end
      end
    end
    return false
  end
  check("wide glyph paints left cell", lit(8, 15))
  check("wide glyph paints right cell", lit(16, 23))
  check("bold b painted", lit(24, 31))
  check("blank cell empty", not lit(40, 47))

  -- kitty graphics: the mock `icat` places a 64x32 sprite at the cursor and
  -- term_view decodes + paints it into the canvas
  do
    local kid = Core.open({ host = "localhost", port = 22, user = "kitty", cols = 40, rows = 10 })
    Core.update(0.7)
    Core.update(0.1)
    local ktv = TermView.new(Core, kid)
    ktv:update(0.016)
    local before = #ktv.placements
    Core.write(kid, "icat\r")
    ktv:update(0.016)
    local pl = ktv.placements
    check("kitty: no placement before icat", before == 0)
    check("kitty: one placement after icat", #pl == 1, #pl)
    local p = pl[1]
    check(
      "kitty: placement 8x2 cells",
      p and p.cols == 8 and p.rows == 2,
      p and (p.cols .. "x" .. p.rows)
    )
    check("kitty: anchored at column 0 of the output line", p and p.col == 0 and p.row >= 0)
    local info = Core.imageInfo(kid, p.key)
    check(
      "kitty: image info rgba 64x32",
      info and info.width == 64 and info.height == 32 and info.format == 32 and not info.compressed
    )
    check("kitty: payload size", info and #Core.imageData(kid, p.key, info.bytes) == 64 * 32 * 4)
    check("kitty: texture cached", ktv.images[p.key] ~= nil and ktv:imageCount() == 1)
    -- the canvas shows the sprite's rust body inside the placement
    local kd = ktv.canvas:newImageData()
    local px = p.col * TermView.CW + 30
    local py = p.row * TermView.CH + 6
    local r, g, b = kd:getPixel(px, py)
    check(
      "kitty: sprite painted (rust body)",
      math.abs(r - 0xB7 / 255) < 0.05
        and math.abs(g - 0x41 / 255) < 0.05
        and math.abs(b - 0x0E / 255) < 0.05,
      ("%.2f %.2f %.2f"):format(r, g, b)
    )
    local fr, fg2, fb = kd:getPixel(p.col * TermView.CW, p.row * TermView.CH)
    check("kitty: sprite frame (yellow) at the corner", fr > 0.8 and fg2 > 0.7 and fb < 0.4)
    local cx, cy = Core.cursor(kid)
    check("kitty: prompt is two rows below the image top", cy == p.row + 2, cx .. "," .. cy)
    -- scrolling: 9 more lines push the image off the top
    for _ = 1, 9 do
      Core.write(kid, "echo x\r")
    end
    ktv:update(0.016)
    check("kitty: placement scrolled off", #ktv.placements == 0, #ktv.placements)
    Core.scroll(kid, 10)
    ktv:update(0.016)
    check("kitty: visible again in scrollback", #ktv.placements == 1)
    Core.scroll(kid, 0)

    -- decode paths: raw RGB expansion and PNG through love.image
    local rgb = string.rep(string.char(255, 0, 0), 4)
    local img, err, w, h =
      TermView.decodeImage({ width = 2, height = 2, format = 24, compressed = false }, rgb)
    check("kitty: rgb decode", img ~= nil and w == 2 and h == 2, err)
    local idata = love.image.newImageData(3, 5)
    idata:setPixel(1, 2, 0, 1, 0, 1)
    local pngBytes = idata:encode("png"):getString()
    local pimg, perr, pw, ph =
      TermView.decodeImage({ width = 0, height = 0, format = 100, compressed = false }, pngBytes)
    check("kitty: png decode", pimg ~= nil and pw == 3 and ph == 5, perr)
    local zipped = love.data.compress("string", "zlib", rgb)
    local zimg, zerr =
      TermView.decodeImage({ width = 2, height = 2, format = 24, compressed = true }, zipped)
    check("kitty: zlib decode", zimg ~= nil, zerr)
    local bad, baderr =
      TermView.decodeImage({ width = 0, height = 0, format = 100, compressed = false }, "not a png")
    check("kitty: bad png rejected", bad == nil and baderr ~= nil)
    Core.close(kid)
    Core.update(0.1)
    Core.free(kid)
  end

  -- every asset in docs/STYLE.md's catalogue exists and loads (not a placeholder)
  local CATALOGUE = {
    "logo_hero",
    "bg_causeway_far",
    "bg_causeway_mid",
    "bg_causeway_near",
    "bezel",
    "card_frame",
    "led_strip",
    "particle_spark",
    "hero_idle",
    "icon_session",
    "icon_search",
    "icon_settings",
    "icon_ai",
    "icon_link",
    "icon_key",
    "agent_claude",
    "agent_grok",
    "agent_openai",
    "prop_dimsum",
    "prop_milktea",
    "prop_tram",
  }
  local missing = {}
  for _, name in ipairs(CATALOGUE) do
    if not G.exists(name) or G.isPlaceholder(G.sprite(name, 16, 16)) then
      missing[#missing + 1] = name
    end
  end
  check("all 21 catalogue assets exist and load", #missing == 0, table.concat(missing, ","))
  local leds = G.ledStrip(8)
  check("led strip has 4 frames", not leds.placeholder and #leds.quads == 4)
  local hero = require("src.scenes.lobby").heroStrip(G)
  check("hero strip: two most similar frames picked", not hero.placeholder and hero.n == 2, hero.n)
  check(
    "hero strip content-shaped",
    hero.img:getWidth() == 112 and hero.fh > 40 and hero.fh < 90,
    hero.fh
  )
  local ax1, ay1 = G.frameAnchor(hero, 1)
  local ax2, ay2 = G.frameAnchor(hero, 2)
  check(
    "hero frames' feet anchors coincide within 1 px",
    ax1 and ax2 and math.abs(ax1 - ax2) <= 1 and math.abs(ay1 - ay2) <= 1,
    string.format("%s,%s vs %s,%s", tostring(ax1), tostring(ay1), tostring(ax2), tostring(ay2))
  )
  check("hero anchor sits on the cell bottom", ay1 and math.abs(ay1 - hero.fh) <= 1, ay1)
  local ox, oy = G.drawAnchored(hero, 1, 16.4, 100.6)
  check(
    "anchored draw snaps to integer px",
    ox == math.floor(ox) and oy == math.floor(oy),
    ox .. "," .. oy
  )
  local feet = G.frameDiff(
    hero,
    1,
    2,
    0,
    math.floor(hero.fh * 0.7),
    hero.fw,
    hero.fh - math.floor(hero.fh * 0.7)
  )
  check("hero legs/chair (bottom 30%) identical between frames", feet < 0.001, feet)
  local hands = G.frameDiff(hero, 1, 2, 0, 0, hero.fw, math.floor(hero.fh * 0.66))
  check("hero hands/keyboard region animates", hands > 0.005, hands)
  local head = G.frameDiff(hero, 1, 2, 0, 0, hero.fw, math.floor(hero.fh * 0.45))
  check("hero head/torso (top 45%) identical between frames (lockAbove)", head < 0.001, head)
  local walk = G.strip("hero_walk", 4, 40, nil, { mode = "anchor" })
  check("hero_walk strip loads or falls back", walk ~= nil and walk.n >= 1)
  -- a real sprite keyed mid-frame (scaled + scissored) must still come out right
  love.graphics.push("all")
  love.graphics.scale(2, 2)
  love.graphics.translate(15, 14)
  love.graphics.setScissor(30, 28, 200, 200)
  local ic = G.sprite("icon_ai", 32, 32)
  love.graphics.pop()
  local scratch = love.graphics.newCanvas(32, 32)
  love.graphics.push("all")
  love.graphics.setCanvas(scratch)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(ic, 0, 0)
  love.graphics.setCanvas()
  love.graphics.pop()
  local icd = scratch:newImageData()
  local lit2 = 0
  for yy = 0, 31 do
    for xx = 0, 31 do
      local _, _, _, aa = icd:getPixel(xx, yy)
      if aa > 0.5 then
        lit2 = lit2 + 1
      end
    end
  end
  check("keyed icon has opaque pixels", lit2 > 100 and lit2 < 1024, lit2)
  check("card frame 9-slice ready", G.nineSlice().ok == true)
  check("bezel image loads", G.bezelImage() ~= nil)
  check(
    "parallax layers load",
    G.parallaxLayers(180)[1].img ~= nil and G.parallaxLayers(180)[3].img ~= nil
  )
  check("ctrl+esc chord = lobby", Keys.appChord("escape", ctrl) == "lobby")
  check(
    "plain esc goes to terminal",
    Keys.appChord("escape", none) == nil and Keys.translate("escape", none) == "\x1b"
  )

  -- placeholder sprite never crashes
  local img = G.sprite("definitely_missing_asset", 32, 32)
  check("missing asset -> placeholder", img ~= nil and G.isPlaceholder(img))
  check("missing layer -> nil", G.layer("definitely_missing_layer", 8, 8) == nil)

  -- mock llm streaming
  local req = Core.llmStart({
    provider = "openai",
    apiKey = "x",
    model = nil,
    system = "s",
    messages = { { role = "user", content = "hello" } },
  })
  check("llm start", req ~= nil)
  Core.update(0.5)
  check("llm streaming", Core.llmState(req) == Core.LLM.STREAMING)
  local acc = ""
  for _ = 1, 400 do
    Core.update(0.05)
    acc = acc .. Core.llmTakeDelta(req)
    if Core.llmState(req) == Core.LLM.DONE then
      break
    end
  end
  check("llm done", Core.llmState(req) == Core.LLM.DONE)
  check(
    "llm text streamed",
    acc:find("ps aux", 1, true) ~= nil and acc:find("香港", 1, true) ~= nil
  )
  check("llm utf8 intact", require("utf8").len(acc) ~= nil)
  Core.llmFree(req)

  -- typewriter
  local tw = fx.typewriter("你好ab", 10)
  tw:update(0.25)
  check("typewriter partial utf8", tw.text == "你好" and not tw.done)
  tw:update(1)
  check("typewriter done", tw.done and tw.text == "你好ab")

  -- Unicode (phase 2): the eight strings from docs/QA_CHECKLIST.md ----------
  local U = require("src.shots").UNICODE
  local HEX = {
    "e4bda0e5a5bde4b896e7958c",
    "e9a699e6b8afe98a85e991bce781a3",
    "ec9588eb8595ed9598ec84b8ec9a94",
    "ec84b8ec859820ec9db4eba684",
    "e38193e38293e381abe381a1e381af",
    "e69db1e4baace382bfe383afe383bc",
    "efbdb6efbe80efbdb6efbe85",
    "50c599c3ad6c69c5a120c5be6c75c5a56f75c48d6bc3bd206bc5afc58820c3ba70c49b6c20c48fc3a162656c736bc3a920c3b36479",
  }
  local function hex(str)
    return (str:gsub(".", function(c)
      return string.format("%02x", c:byte())
    end))
  end
  -- East Asian wide for these strings: CJK / Hangul / kana / fullwidth forms;
  -- halfwidth katakana (U+FF61..U+FFDC) and every Latin letter are narrow.
  local function isWide(cp)
    if cp >= 0xFF61 and cp <= 0xFFDC then
      return false
    end
    return cp >= 0x1100
  end
  local function glyphs(str)
    local out = {}
    for _, cp in utf8.codes(str) do
      out[#out + 1] = { cp = cp, ch = utf8.char(cp), w = isWide(cp) and 2 or 1 }
    end
    return out
  end
  -- (a) advance: 16 px per wide glyph, 8 px per Czech letter / halfwidth kana
  local badAdv = {}
  for _, str in ipairs(U) do
    for _, g in ipairs(glyphs(str)) do
      if G.fontTerm:getWidth(g.ch) ~= g.w * 8 then
        badAdv[#badAdv + 1] = g.ch .. "=" .. G.fontTerm:getWidth(g.ch)
      end
    end
  end
  check("unicode: unifont advance 16/8 for every glyph", #badAdv == 0, table.concat(badAdv, " "))
  check(
    "unicode: halfwidth katakana are 4 cells",
    G.fontTerm:getWidth("ｶﾀｶﾅ") == 32,
    G.fontTerm:getWidth("ｶﾀｶﾅ")
  )
  check("unicode: 東京タワー is 10 cells", G.fontTerm:getWidth("東京タワー") == 80)
  -- (b) term_view paints every string with no overlap and no gaps
  local function litCols(canvas)
    local d = canvas:newImageData()
    local cols = {}
    for x = 0, d:getWidth() - 1 do
      local on = false
      for y = 0, d:getHeight() - 1 do
        local r, g, b = d:getPixel(x, y)
        if r + g + b > 1.5 then
          on = true
          break
        end
      end
      cols[x] = on
    end
    return cols
  end
  local function rowCells(gs, spaced)
    local n = 0
    for _, g in ipairs(gs) do
      n = n + g.w + (spaced and 1 or 0)
    end
    local cells = ffi.new("CboCell[?]", n)
    local i = 0
    for _, g in ipairs(gs) do
      cells[i].cp, cells[i].fg, cells[i].bg, cells[i].attr, cells[i].width =
        g.cp, 0xFFFFFF, 0x101830, 0, g.w
      if g.w == 2 then
        cells[i + 1].cp, cells[i + 1].fg, cells[i + 1].bg, cells[i + 1].width =
          0, 0xFFFFFF, 0x101830, 0
      end
      i = i + g.w
      if spaced then
        cells[i].cp, cells[i].fg, cells[i].bg, cells[i].width = 0, 0xFFFFFF, 0x101830, 1
        i = i + 1
      end
    end
    return cells, n
  end
  local tvU = TermView.new(nil, nil)
  -- signature of the .notdef box so a tofu glyph is caught
  local notdef = rowCells({ { cp = 0x10FFFE, w = 1 } }, true)
  tvU:renderCells(notdef, 2, 1)
  local tofuCols = litCols(tvU.canvas)
  local problems = {}
  for si, str in ipairs(U) do
    local gs = glyphs(str)
    -- spaced row: the column right after each glyph must be background,
    -- and each glyph must have ink of its own
    local cells, n = rowCells(gs, true)
    tvU:renderCells(cells, n, 1)
    local cols = litCols(tvU.canvas)
    local c = 0
    for _, g in ipairs(gs) do
      local x0, x1 = c * 8, (c + g.w) * 8 - 1
      local ink = false
      for x = x0, x1 do
        ink = ink or cols[x]
      end
      if g.cp ~= 32 and not ink then
        problems[#problems + 1] = str .. ":" .. g.ch .. " blank"
      end
      for x = x1 + 1, x1 + 8 do
        if cols[x] then
          problems[#problems + 1] = str .. ":" .. g.ch .. " bleeds right"
          break
        end
      end
      if g.w == 2 then
        -- both halves carry ink for a wide glyph (not squeezed into one cell)
        local left, right = false, false
        for x = x0, x0 + 7 do
          left = left or cols[x]
        end
        for x = x0 + 8, x1 do
          right = right or cols[x]
        end
        if not (left and right) then
          problems[#problems + 1] = str .. ":" .. g.ch .. " not 2 cells wide"
        end
        -- not the .notdef box
        local same = true
        for x = 0, 15 do
          if cols[x0 + x] ~= tofuCols[x] then
            same = false
          end
        end
        if same then
          problems[#problems + 1] = str .. ":" .. g.ch .. " tofu"
        end
      end
      c = c + g.w + 1
    end
    -- contiguous row: canvas is exactly cells*8 wide and rowText round-trips
    local cells2, n2 = rowCells(gs, false)
    tvU:renderCells(cells2, n2, 1)
    if tvU.canvas:getWidth() ~= n2 * 8 or tvU:rowText(0, 0, n2 - 1) ~= str then
      problems[#problems + 1] = str .. " rowText/canvas mismatch"
    end
    check(
      string.format("unicode[%d] %s: %d cells, painted, no bleed, no tofu", si, str, n2),
      #problems == 0,
      table.concat(problems, "; ")
    )
    problems = {}
  end
  check("unicode: mock utf8Width 你好世界 = 8", Core.utf8Width("你好世界") == 8)
  check(
    "unicode: mock utf8Width ｶﾀｶﾅ = 4",
    Core.utf8Width("ｶﾀｶﾅ") == 4,
    Core.utf8Width("ｶﾀｶﾅ")
  )
  check("unicode: mock utf8Width czech = 38", Core.utf8Width(U[8]) == 38, Core.utf8Width(U[8]))
  check(
    "unicode: mock utf8Width 세션 이름 = 9",
    Core.utf8Width("세션 이름") == 9,
    Core.utf8Width("세션 이름")
  )
  -- (c) textinput path: App.textinput -> terminal scene -> Core.write, byte-exact
  lib.reset()
  Sessions.init(Core)
  local trec =
    Sessions.open({ host = "h", port = 22, user = "u", cols = 80, rows = 24, noRemember = true })
  Core.update(1)
  local Term = require("src.scenes.terminal")
  local savedScene, savedName = App.scene, App.sceneName
  App.scene = Term.new(App, { id = trec.id })
  App.sceneName = "terminal"
  App.scene:enter()
  local origWrite = Core.write
  local captured = ""
  Core.write = function(_, bytes)
    captured = captured .. bytes
  end
  local badBytes = {}
  for i, str in ipairs(U) do
    captured = ""
    App.textinput(str) -- IME delivers a composed string at once
    if hex(captured) ~= HEX[i] then
      badBytes[#badBytes + 1] = str .. "=" .. hex(captured)
    end
    captured = ""
    for _, cp in utf8.codes(str) do
      App.textinput(utf8.char(cp)) -- key-by-key
    end
    if hex(captured) ~= HEX[i] then
      badBytes[#badBytes + 1] = str .. " (per char)"
    end
  end
  Core.write = origWrite
  App.scene, App.sceneName = savedScene, savedName
  check(
    "unicode: textinput -> Core.write bytes exact (8 strings x 2 paths)",
    #badBytes == 0,
    table.concat(badBytes, " ")
  )
  -- (d) rename + search in Korean
  check(
    "unicode: rename to 세션 이름",
    Sessions.rename(trec.id, "세션 이름") and Core.getName(trec.id) == "세션 이름"
  )
  local kh = Core.search("세션")
  check("unicode: search 세션 finds it", #kh >= 1 and kh[1] == trec.id, kh[1])
  check(
    "unicode: rename to 香港銅鑼灣",
    Sessions.rename(trec.id, "香港銅鑼灣") and #Core.search("銅鑼") == 1
  )
  -- (e) config + hosts JSON round-trip byte-exact
  local cfg = Config.get()
  local savedModel = cfg.models.openai
  cfg.models.openai = table.concat(U, "|")
  Config.save()
  Config.load()
  check(
    "unicode: config.json round-trips all strings",
    Config.get().models.openai == table.concat(U, "|")
  )
  Config.get().models.openai = savedModel
  Config.save()
  Sessions.hosts = {}
  Sessions.rememberHost({ host = U[2], port = 22, user = U[4], keypath = U[8] })
  Sessions.loadHosts()
  local h1 = Sessions.hosts[1]
  check(
    "unicode: hosts.json round-trips host/user/keypath",
    h1 and h1.host == U[2] and h1.user == U[4] and h1.keypath == U[8],
    h1 and (h1.host .. " " .. h1.user)
  )

  -- Terminal grid at native scale (phase 2) ---------------------------------
  local D = App.D
  local savedW, savedH = D.w, D.h
  local savedZoom = D.termZoom
  App.setBezel(true, true)
  D.setTermZoom(1)
  D.resize(1080, 800)
  local gc, gr = Term.grid(D, false)
  check("grid: 1080x800 + bezel >= 80x24 at 1x", gc >= 80 and gr >= 24, gc .. "x" .. gr)
  check("grid: 1080x800 ui scale 2", D.s == 2, D.s)
  D.resize(800, 1400)
  check("portrait 800x1400 keeps ui scale 2 (same pixels as landscape)", D.s == 2, D.s)
  check(
    "portrait backdrop fits the width (16:9 strip on the floor)",
    G.parallaxHeight(D.vw, D.vh) == math.floor(D.vw * 9 / 16 + 0.5)
      and G.parallaxLayers(D.vw, D.vh)[3].h < D.vh
  )
  check("landscape backdrop fills the height", G.parallaxHeight(540, 376) == 376)
  D.resize(1080, 800)
  local ac, ar = Term.grid(D, true)
  check("grid: 1080x800 with AI panel still >= 80 cols", ac >= 80 and ar == gr, ac .. "x" .. ar)
  D.resize(1280, 800)
  gc, gr = Term.grid(D, false)
  check("grid: 1280x800 >= 100x24", gc >= 100 and gr >= 24, gc .. "x" .. gr)
  D.resize(1920, 1080)
  gc, gr = Term.grid(D, false)
  check("grid: 1920x1080 >= 120x40", gc >= 120 and gr >= 40, gc .. "x" .. gr)
  D.setTermZoom(2)
  local zc, zr = Term.grid(D, false)
  check(
    "grid: 2x zoom halves the grid",
    zc <= gc / 2 + 1 and zr <= gr / 2 + 1 and zc >= 80,
    zc .. "x" .. zr
  )
  check("zoom clamps to 1..2", D.setTermZoom(3) == 2 and D.setTermZoom(0) == 1)
  D.setTermZoom(savedZoom)
  D.resize(savedW, savedH)
  check("chord ctrl+= zoom in", Keys.appChord("=", ctrl) == "zoomIn")
  check("chord ctrl+- zoom out", Keys.appChord("-", ctrl) == "zoomOut")
  -- layout resizes the core only when the grid changed
  App.scene = Term.new(App, { id = trec.id })
  App.scene:enter()
  local n0 = App.scene.resizes
  App.scene:layout()
  check("terminal layout: no resize when the grid is unchanged", App.scene.resizes == n0)
  check("terminal layout: core grid == scene grid", Core.info(trec.id).cols == App.scene.cols)
  local sceneCols = App.scene.cols
  App.scene:toggleAI()
  check(
    "AI toggle: no resize before the slide ends",
    App.scene.resizes == n0 and App.scene.cols == sceneCols
  )
  fx.update(0.4) -- the 0.32 s slide finishes -> one resize
  check(
    "AI toggle: one resize after the slide",
    App.scene.resizes == n0 + 1 and App.scene.cols < sceneCols,
    App.scene.cols
  )
  check("AI toggle: core follows", Core.info(trec.id).cols == App.scene.cols)
  App.scene:toggleAI()
  fx.update(0.4)
  check(
    "AI close: grid restored",
    App.scene.cols == sceneCols and Core.info(trec.id).cols == sceneCols
  )
  App.scene:leave()
  App.scene, App.sceneName = savedScene, savedName
  -- Ctrl+Enter insert text
  local AI = require("src.scenes.ai")
  check("ai insert: plain text goes whole", AI.insertText("ls -la") == "ls -la")
  check(
    "ai insert: only the fenced blocks",
    AI.insertText("Use this:\n```bash\nlsof -i :22\n```\nthen\n```\nnetstat -an\n```\n")
      == "lsof -i :22\nnetstat -an\n"
  )
  check("ai insert: empty -> empty", AI.insertText(nil) == "" and AI.insertText("") == "")
  -- Model output must open a review before it reaches the remote shell.
  local reviewPanel = AI.new(App, trec.id)
  reviewPanel.messages = { { role = "assistant", content = "```sh\necho review\n```" } }
  local originalPush, originalWrite = App.push, Core.write
  local pushed, writes = nil, 0
  App.push = function(name, params)
    pushed = { name = name, params = params }
  end
  Core.write = function()
    writes = writes + 1
  end
  reviewPanel:keypressed("return", ctrl)
  check("AI code opens review without writing", pushed and pushed.name == "paste" and writes == 0)
  local Paste = require("src.scenes.paste")
  local preview = Paste.new(App, { id = trec.id, text = "echo ok\27[201~\3\n" })
  check("paste preview removes escape and control bytes", not preview.text:find("[\27\3]"))
  App.push, Core.write = originalPush, originalWrite

  local UI = require("src.ui")
  local field = UI.field("", "", { maxLen = 3 })
  field:textinput("한글日本")
  check("field enforces UTF-8 length on whole pasted chunks", field.value == "한글日")
  local numeric = UI.field("", "", { numeric = true, maxLen = 5 })
  numeric:textinput("12ab")
  check("numeric fields reject nonnumeric chunks", numeric.value == "")
  check(
    "fields reject invalid UTF-8 and controls",
    not numeric:textinput("\255") and not numeric:textinput("\27")
  )

  -- Renderer consumes the already-resolved Rust colours, including inverse.
  local cv = TermView.new(Core, trec.id)
  local inverseCell = ffi.new("CboCell[1]")
  inverseCell[0].cp, inverseCell[0].width = 32, 1
  inverseCell[0].fg, inverseCell[0].bg, inverseCell[0].attr = 0x000000, 0xFFFFFF, 8
  cv:renderCells(inverseCell, 1, 1)
  local pixels = cv.canvas:newImageData()
  local ir, ig, ib = pixels:getPixel(4, 8)
  check("inverse background is not swapped twice", ir > 0.99 and ig > 0.99 and ib > 0.99)

  local Search = require("src.scenes.search")
  local search = Search.new(App)
  search.sel = 10
  local _, _, _, _, first, visible = search:layout()
  check(
    "search scrolls to selected rows beyond the first six",
    first <= 10 and first + visible > 10 and first > 1
  )
  local Settings = require("src.scenes.settings")
  local settings = Settings.new(App)
  settings.sel = #settings.rows
  local _, _, _, _, count = settings:layout()
  check(
    "privacy settings stay in the visible rows",
    settings.scroll > 0 and settings.scroll + count >= settings.sel
  )
  settings:draw()
  local History = require("src.scenes.history")
  local history = History.new(App, { id = trec.id })
  history:draw()
  history:keypressed("tab", none)
  check("history panel exposes completion mode", history.mode == 2)
  check(
    "history shortcut keeps normal session search",
    Keys.appChord("k", { ctrl = true, shift = true }) == "history"
      and Keys.appChord("k", ctrl) == "search"
  )

  -- thinking state: STREAMING with no text yet
  local panel = AI.new(App, trec.id)
  panel.provider = "openai"
  panel.input.value = "hi"
  panel:send()
  check("ai thinking: request started", panel.req ~= nil, panel.error)
  check("ai thinking while no delta", panel:thinking())
  for _ = 1, 40 do
    Core.update(0.05)
    panel:update(0.05)
  end
  check("ai thinking ends once text streams", not panel:thinking() and panel.streamText ~= "")
  panel:close()
  check("ai close frees the request", panel.req == nil)

  -- session limit
  lib.reset()
  Sessions.init(Core)
  local opened = 0
  for _ = 1, 130 do
    if Core.open({ host = "x", user = "u", cols = 4, rows = 2 }) then
      opened = opened + 1
    end
  end
  check("max 128 sessions", opened == 128, opened)
  lib.reset()

  -- world map graph + walk maths
  do
    local MG = require("src.mapgraph")
    local nodes = MG.load("assets/definitely_missing_nodes.json")
    check(
      "map json fallback when missing",
      nodes.fallback == true and #nodes.platforms == 8 and #nodes.paths == 7
    )
    local p18 = MG.bfs(nodes, 1, 8)
    check("bfs 1->8 walks the chain", p18 and #p18 == 8 and p18[1] == 1 and p18[8] == 8)
    local p31 = MG.bfs(nodes, 3, 1)
    check("bfs 3->1", p31 and #p31 == 3 and p31[2] == 2)
    check("bfs same node", #MG.bfs(nodes, 4, 4) == 1)
    check("bfs unknown node", MG.bfs(nodes, 1, 99) == nil)
    love.filesystem.write(
      "map_nodes_test.json",
      '{"image":"x","platforms":[{"x":0.1,"y":0.2},{"x":0.5,"y":0.5},{"x":0.9,"y":0.3}],"paths":[[0,1],[1,2]]}'
    )
    local loaded = MG.load("map_nodes_test.json")
    check(
      "map json loads platforms + paths",
      not loaded.fallback and #loaded.platforms == 3 and #loaded.adj[2] == 2
    )
    check(
      "segment duration formula",
      math.abs(MG.segmentDuration(100) - 0.38) < 1e-9
        and math.abs(MG.segmentDuration(10) - 0.22) < 1e-9
        and math.abs(MG.segmentDuration(250) - 0.95) < 1e-9
    )
    local poly = { { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 100, y = 50 } }
    check("walk duration sums segments", math.abs(MG.walkDuration(poly) - (0.38 + 0.22)) < 1e-9)
    local mono, prev = true, -1
    for i = 0, 100 do
      local v = fx.ease.expoInOut(i / 100)
      if v < prev then
        mono = false
      end
      prev = v
    end
    check(
      "walk easing expoInOut endpoints + monotonic",
      fx.ease.expoInOut(0) == 0 and fx.ease.expoInOut(1) == 1 and mono
    )
    check("facing from dx", MG.facing(-3) == -1 and MG.facing(5) == 1 and MG.facing(0) == 1)
    check(
      "bob is zero at segment ends",
      math.abs(MG.bob(0, 5)) < 1e-9 and math.abs(MG.bob(1, 5)) < 1e-6
    )
    -- platform assignment stability across save/load
    local hosts = {
      { host = "b", user = "u", port = 22, firstSeen = 200 },
      { host = "a", user = "u", port = 22, firstSeen = 100 },
    }
    MG.assignPlatforms(hosts)
    check("first seen gets platform 0", hosts[2].platform == 0 and hosts[1].platform == 1)
    local again = json.decode(json.encode({ hosts = hosts })).hosts
    again[#again + 1] = { host = "c", user = "u", port = 22, firstSeen = 300 }
    MG.assignPlatforms(again)
    check(
      "platforms stable after save/load; new host takes the next slot",
      again[1].platform == 1 and again[2].platform == 0 and again[3].platform == 2
    )
    table.remove(again, 2)
    again[#again + 1] = { host = "d", user = "u", port = 22, firstSeen = 400 }
    MG.assignPlatforms(again)
    check(
      "freed slot is reused, others never move",
      again[1].platform == 1 and again[2].platform == 2 and again[3].platform == 0
    )
    check(
      "page / slot includes all ten map stages",
      MG.page(9) == 0 and MG.slot(9) == 9 and MG.page(10) == 1
    )
    -- particles
    fx.reset()
    fx.confettiBurst(10, 10, 24, G.strip("particle_confetti", 4, 8, 8, { mode = "each" }), 100)
    check("confetti burst = 24 pieces", fx.particleCount("confetti") == 24)
    fx.dustPuff(10, 10, G.strip("particle_dust", 4, 8, 8, { mode = "each" }), 1)
    check("dust puff = 1 particle", fx.particleCount("dust") == 1)
    fx.reset()
    -- layout maths for both orientations
    local D = App.D
    local Lobby = require("src.scenes.lobby")
    local Term = require("src.scenes.terminal")
    local Map = require("src.scenes.map")
    check(
      "auto orientation follows aspect",
      D.isPortrait(510, 366, "auto") == false and D.isPortrait(770, 1370, "auto") == true
    )
    check(
      "forced orientation",
      D.isPortrait(510, 366, "portrait") == true and D.isPortrait(770, 1370, "landscape") == false
    )
    check(
      "lobby columns: landscape 2 at 510, 3 at 640",
      Lobby.columnsFor(510, false) == 2 and Lobby.columnsFor(640, false) == 3
    )
    check(
      "lobby columns: portrait capped at 2, 1 when narrow",
      Lobby.columnsFor(770, true) == 2 and Lobby.columnsFor(300, true) == 1
    )
    local saveVW, saveVH, savePortrait = D.vw, D.vh, D.portrait
    D.vw, D.vh, D.portrait = 770, 1370, true
    check("AI panel docks below in portrait", Term.aiDock(D) == "bottom")
    do
      local rec = { name = "mary-1", user = "alice", host = "box.example.net" }
      D.vw = 400
      check(
        "narrow terminal prints the session name on its own title row",
        Term.titleRows(D, rec, G) == 2
      )
      D.vw = 770
      check("wide terminal keeps name beside the buttons", Term.titleRows(D, rec, G) == 1)
      check("no record: single tab row", Term.titleRows(D, nil, G) == 1)
      local top = 32 + Term.CWD_H
      local _, r2 = Term.availFor(D, 0, top)
      local _, r1 = Term.availFor(D, 0)
      check("title row takes its height from the grid", r1 - r2 == 16)
    end
    local c1, r1 = Term.grid(D, true)
    local c0, r0 = Term.grid(D, false)
    check(
      "portrait AI open: full width kept, >= 24 rows",
      c1 == c0 and r1 >= 24 and r1 < r0,
      c1 .. "x" .. r1 .. " vs " .. c0 .. "x" .. r0
    )
    D.vw, D.vh, D.portrait = 510, 366, false
    check("AI panel docks right in landscape", Term.aiDock(D) == "right")
    local c2, r2 = Term.grid(D, true)
    check(
      "landscape AI open: rows kept, columns yield",
      r2 == select(2, Term.grid(D, false)) and c2 < c0
    )
    D.vw, D.vh, D.portrait = saveVW, saveVH, savePortrait
    -- A forced orientation belongs to the window shape it was chosen for.
    local sw, sh = D.w, D.h
    local saveMode, saveFor = D.orientationMode, D.overrideFor
    D.orientationMode, D.overrideFor = "landscape", "portrait"
    D.resize(800, 1400)
    check(
      "forced landscape sticks in the tall window it was made for",
      D.orientationMode == "landscape" and D.portrait == false
    )
    D.resize(1080, 800)
    check(
      "forced orientation drops to auto when the window shape flips",
      D.orientationMode == "auto" and D.overrideFor == nil and D.portrait == false
    )
    D.orientationMode, D.overrideFor = "landscape", nil
    D.resize(800, 1400)
    check(
      "forced orientation without a remembered shape is not trusted",
      D.orientationMode == "auto" and D.portrait == true
    )
    D.orientationMode, D.overrideFor = saveMode, saveFor
    D.resize(sw, sh)
    local fl = Map.fit(510, 366, false)
    check(
      "map landscape covers the view (16:9 wider than the content)",
      fl.mapW >= 510 and fl.mapH >= fl.viewH and fl.viewH == 366 - fl.infoH and fl.infoH >= 64
    )
    local fp = Map.fit(770, 1370, true)
    check(
      "map portrait keeps the horizontal map, fitted to the width",
      fp.mapW == 770
        and fp.mapH == math.ceil(770 * 9 / 16)
        and fp.mapH < fp.viewH
        and fp.infoY == fp.viewH
        and fp.infoH == 112
    )
    do
      local invalid = {
        { host = "a", platform = 0 },
        { host = "b", platform = 0 },
        {
          host = "c",
          platform = -1,
        },
      }
      local _, changed = MG.assignPlatforms(invalid)
      check(
        "map repairs duplicate and invalid saved stage positions",
        changed
          and invalid[1].platform == 0
          and invalid[2].platform ~= invalid[3].platform
          and invalid[2].platform > 0
          and invalid[3].platform > 0
      )
    end
    local fp2 = Map.fit(400, 300, true)
    check(
      "map portrait on a short window fits the height instead",
      fp2.mapH <= fp2.viewH and fp2.mapW <= 400 and fp2.infoH == 112
    )
    check("ctrl+o chord = orientation", Keys.appChord("o", ctrl) == "orientation")
    check("orientation cycle", D.ORIENTATIONS[1] == "auto" and #D.ORIENTATIONS == 3)
    check(
      "config display/orientation defaults",
      Config.get().display == "window" and Config.get().orientation == "auto"
    )
  end

  -- phase 3: large sprites must survive love.window.setMode / F11 (canvas
  -- contents are not preserved across a mode change)
  do
    local big = G.sprite("map_causeway", 510, 287, { noChroma = true })
    local probe = love.graphics.newCanvas(4, 4)
    local function sample()
      love.graphics.push("all")
      love.graphics.setCanvas(probe)
      love.graphics.clear(0, 0, 0, 0)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(big, -250, -140)
      love.graphics.setCanvas()
      love.graphics.pop()
      local _, _, _, a = probe:newImageData():getPixel(1, 1)
      return a
    end
    local before = sample()
    local w, h, flags = love.window.getMode()
    love.window.setMode(w, h, flags)
    local after = sample()
    check("large sprite is an Image (not a Canvas)", big:type() == "Image", big:type())
    check(
      "map sprite survives love.window.setMode",
      before > 0.5 and after > 0.5,
      before .. " -> " .. after
    )
  end

  -- phase 3: map hero anchoring, designer graph, timers, particles, layout
  do
    local Map = require("src.scenes.map")
    local MG = require("src.mapgraph")
    local Term = require("src.scenes.terminal")
    -- (A) map hero strips: every kept frame's feet anchor coincides
    for _, spec in ipairs({
      { "hero_walk", 4, { mode = "anchor", deviant = 0.06 } },
      { "hero_map_idle", 2, { mode = "anchor", pick = 2 } },
    }) do
      local st = G.strip(spec[1], spec[2], 22, nil, spec[3])
      local ax0, ay0 = G.frameAnchor(st, 1)
      local worst = 0
      for i = 2, st.n do
        local ax, ay = G.frameAnchor(st, i)
        worst = math.max(worst, math.abs(ax - ax0), math.abs(ay - ay0))
      end
      check(
        spec[1] .. ": " .. st.n .. " frames, feet anchors coincide within 1 px",
        not st.placeholder and st.n >= 2 and worst <= 1,
        worst
      )
      check(spec[1] .. ": anchor on the cell bottom", ay0 and math.abs(ay0 - st.fh) <= 1, ay0)
    end
    -- (C) designer graph: BFS is shortest for every pair (Floyd-Warshall)
    local nodes = MG.load()
    local n = #nodes.platforms
    check(
      "map_nodes.json: 10 platforms, 12 edges",
      not nodes.fallback and n == 10 and #nodes.paths == 12
    )
    local dist = {}
    for i = 1, n do
      dist[i] = {}
      for j = 1, n do
        dist[i][j] = (i == j) and 0 or math.huge
      end
    end
    for a, nbs in pairs(nodes.adj) do
      for _, b in ipairs(nbs) do
        dist[a][b] = 1
      end
    end
    for k = 1, n do
      for i = 1, n do
        for j = 1, n do
          if dist[i][k] + dist[k][j] < dist[i][j] then
            dist[i][j] = dist[i][k] + dist[k][j]
          end
        end
      end
    end
    local bad, unreachable = 0, 0
    for i = 1, n do
      for j = 1, n do
        local path = MG.bfs(nodes, i, j)
        if dist[i][j] == math.huge then
          unreachable = unreachable + 1
        elseif not path or #path - 1 ~= dist[i][j] then
          bad = bad + 1
        end
      end
    end
    check(
      "bfs shortest for all pairs on the designer graph",
      bad == 0 and unreachable == 0,
      bad .. "/" .. unreachable
    )
    local p = MG.bfs(nodes, 2, 8) -- 1 -> 7 branch: two hops, not the long way round
    check("bfs uses the 1-7 branch (2 -> 8 in 1 hop)", p and #p == 2)
    -- (F) fx.after handles are cancellable
    local fired = 0
    local h = fx.after(0.1, function()
      fired = fired + 1
    end)
    fx.cancel(h)
    fx.update(0.2)
    local h2 = fx.after(0.1, function()
      fired = fired + 10
    end)
    fx.update(0.2)
    check("fx.after: cancelled timer never fires, live one does", fired == 10 and h2.alive == false)
    -- (F) particle pool is bounded on a long walk
    fx.reset()
    local dust = G.strip("particle_dust", 4, 8, 8, { mode = "each" })
    for _ = 1, 5000 do -- 10 minutes of walking: a puff every 120 ms
      fx.dustPuff(1, 1, dust, 1)
      fx.update(0.12)
    end
    check("dust on a 10-minute walk stays bounded", fx.particleCount() <= 4, fx.particleCount())
    for _ = 1, 100 do
      fx.confettiBurst(1, 1, 24, G.strip("particle_confetti", 4, 8, 8, { mode = "each" }), 100)
    end
    check(
      "particle pool capped at MAX_PARTICLES",
      fx.particleCount() == fx.MAX_PARTICLES,
      fx.particleCount()
    )
    fx.reset()
    -- (F) map scene: leaving cancels the hop -> connect timer; no hosts.json per frame
    lib.reset()
    Sessions.init(Core)
    Sessions.hosts = { { host = "stage", user = "u", port = 22, firstSeen = 1 } }
    local saves = 0
    local origSave = Sessions.saveHosts
    Sessions.saveHosts = function()
      saves = saves + 1
      return true
    end
    local sc = Map.new(App, {})
    sc:enter()
    check(
      "map assigns the platform once (one hosts.json write)",
      saves == 1 and Sessions.hosts[1].platform == 0,
      saves
    )
    saves = 0
    for _ = 1, 120 do
      sc:update(1 / 60)
    end
    for _ = 1, 5 do
      sc:draw()
    end
    check("map update/draw never writes hosts.json", saves == 0, saves)
    check(
      "map: Ctrl+N chord handled",
      (function()
        App.scene, App.sceneName = sc, "map"
        App.overlays = {}
        sc:keypressed("n", ctrl)
        local ok = App.hasOverlay("connect")
        App.overlays = {}
        App.scene, App.sceneName = nil, nil
        return ok
      end)()
    )
    do
      -- Duplicate connections must remain independently selectable on the map.
      local first = Sessions.open({ host = "stage", user = "u", port = 22 })
      local second = Sessions.open({ host = "stage", user = "u", port = 22, platform = 2 })
      Core.update(1)
      Sessions.update(0.1)
      local duplicateMap = Map.new(App)
      duplicateMap:enter()
      check(
        "map gives two sessions on one server separate stages",
        #duplicateMap.hosts == 2
          and first.mapPlatform ~= second.mapPlatform
          and #Sessions.hosts == 1
      )
      local switched, originalSwitch = nil, App.switch
      App.switch = function(name, params)
        switched = name == "terminal" and params.id
      end
      for _, rec in ipairs({ first, second }) do
        duplicateMap.page = MG.page(rec.mapPlatform)
        duplicateMap:connect(MG.slot(rec.mapPlatform) + 1)
        check("map stage selects exact session " .. rec.id, switched == rec.id)
      end
      App.switch = originalSwitch
      duplicateMap:leave()
      for _, rec in ipairs({ first, second }) do
        Core.close(rec.id)
        Core.update(1)
        Sessions.remove(rec.id)
      end
      sc:update(0.3)
      -- Global buttons remain clickable above both base pages and dialogs.
      local oldFullscreen, oldOrientation = App.setFullscreen, App.setOrientation
      local actions, leaked = {}, 0
      App.setFullscreen = function(on)
        actions[#actions + 1] = on and "full" or "window"
      end
      App.setOrientation = function(mode)
        actions[#actions + 1] = mode
      end
      local sink = {
        mousepressed = function()
          leaked = leaked + 1
        end,
      }
      for _, modal in ipairs({ false, true }) do
        App.scene = sink
        App.overlays = modal and { sink } or {}
        for _, button in ipairs(App.displayButtons()) do
          App.mousepressed((button.x + 1) * App.D.s, (button.y + 1) * App.D.s, 1)
        end
      end
      local wantFlip = App.D.portrait and "landscape" or "portrait"
      local expectedFlip = wantFlip == App.D.natural() and "auto" or wantFlip
      check(
        "display controls work on pages and overlays without leaking clicks",
        #App.displayButtons() == 2
          and #actions == 4
          and actions[1] == (App.D.fullscreen and "window" or "full")
          and actions[2] == expectedFlip
          and actions[3] == actions[1]
          and actions[4] == actions[2]
          and leaked == 0
      )
      check("display toolbar reserves space above scene content", App.D.oy >= App.D.toolbarH)
      App.scene, App.overlays = nil, {}
      App.setFullscreen, App.setOrientation = oldFullscreen, oldOrientation
      local ui = require("src.ui")
      local originalSaveInput, originalSearchInput, originalKV =
        Core.inputSave, Core.inputSearch, Core.kvGet
      local writes, searches = {}, {}
      Core.kvGet = function(key)
        return key == "input.draft.connect.host" and "last.example" or ""
      end
      Core.inputSave = function(key, value, commit)
        writes[#writes + 1] = { key, value, commit }
        return true
      end
      Core.inputSearch = function(key, q)
        searches[#searches + 1] = q
        return q == "last" and { "last.example" } or {}
      end
      local learned = ui.field("host", "", { historyKey = "connect.host", restore = true })
      check("editbox restores last SQLite draft", learned.value == "last.example")
      learned.value = "last"
      ui.update(0.01)
      check("editbox searches as input changes", searches[#searches] == "last")
      check(
        "one chord accepts learned entry",
        learned:keypressed("space", ctrl) and learned.value == "last.example"
      )
      local secret = ui.field(
        "password",
        "hidden",
        { masked = true, historyKey = "connect.password", restore = true }
      )
      local before = #writes
      secret:remember()
      check(
        "masked fields never learn, restore, or suggest",
        secret.historyKey == nil and #writes == before and secret.value == "hidden"
      )
      Core.inputSave, Core.inputSearch, Core.kvGet =
        originalSaveInput, originalSearchInput, originalKV
    end
    do
      local savedLayout = sc.L
      -- a landscape view narrower than the 16:9 map: the world pans sideways
      sc.L = Map.fit(400, 600, false)
      sc.cam.x, sc.cam.y = 0, 0
      sc:keypressed("right", { shift = true })
      check("Shift+arrows pans map without moving selected stage", sc.cam.x == 40 and sc.sel == 1)
      sc:update(0.1)
      check("manual map pan does not snap back to hero", sc.cam.x == 40)
      sc:mousepressed(100, 100, 2)
      sc:mousemoved(50, 100)
      sc:mousereleased(50, 100, 2)
      check("mouse drag pans and release stops dragging", sc.cam.x == 90 and sc.drag == nil)
      sc:pan(99999, 99999)
      check("map panning is bounded", sc.cam.x == sc.L.mapW - sc.L.viewW)
      sc.sel = 1
      sc:keypressed("home", {})
      local hx = sc:cameraTarget()
      check("Home recenters selected stage", not sc.manualPan and sc.cam.x == hx)
      -- portrait: the fitted map never needs panning
      sc.L = Map.fit(400, 600, true)
      sc.cam.x, sc.cam.y = 0, 0
      sc:pan(99999, 99999)
      local page = sc:mapRectOnScreen()
      check(
        "portrait map page is letterboxed inside the view",
        page.w == sc.L.mapW
          and page.h == sc.L.mapH
          and page.y0 > 0
          and page.y0 + page.h < sc.L.viewH
      )
      check(
        "portrait fitted map stays letterboxed (centred, no panning)",
        sc.cam.x == math.floor((sc.L.mapW - sc.L.viewW) / 2)
          and sc.cam.y == math.floor((sc.L.mapH - sc.L.viewH) / 2)
      )
      sc.L = savedLayout
      sc:placeHero(true)
    end
    -- Empty stage opens the real connection form and pins its new favorite.
    App.overlays = {}
    sc:activate(4)
    local form = App.overlays[#App.overlays]
    check("empty map stage opens connection form", form and form.name == "connect")
    form.fields[1].value, form.fields[3].value = "new-stage.example", "map-user"
    form:connect()
    local favorite = Sessions.findHost("map-user@new-stage.example:22")
    check(
      "clicked stage is retained in the automatic favorite",
      favorite and favorite.platform == 3 and favorite.favorite
    )
    check(
      "new map connection tracks the actual session",
      sc.pending and Sessions.get(sc.pending.id) ~= nil
    )
    if sc.pending then
      Core.close(sc.pending.id)
      Core.update(1)
      Sessions.remove(sc.pending.id)
      sc.pending = nil
    end
    App.overlays = {}
    local Map2 = require("src.scenes.map2")
    local grid = Map2.new(App)
    check("map2 includes offline favorites", #grid.shown == #Sessions.hosts)
    local online =
      Sessions.open({ host = "live-grid.example", user = "grid-user", noRemember = true })
    Core.update(1)
    Sessions.update(0.1)
    grid:refresh()
    check("map2 includes every live session and saved favorite", #grid.shown == #Sessions.hosts + 1)
    grid:setFilter(2)
    check(
      "map2 online filter excludes offline favorites",
      #grid.shown == 1 and grid.shown[1].rec == online
    )
    grid.field.value = "grid-user live-grid"
    grid:refresh()
    check("map2 search matches multiple address fields", #grid.shown == 1)
    grid.field.value = "does-not-exist"
    grid:refresh()
    check("map2 shows no invented search results", #grid.shown == 0)
    grid.field.value = ""
    grid:setFilter(6)
    check("map2 Favorites filter excludes unsaved sessions", #grid.shown == #Sessions.hosts)
    grid:draw()
    local cardsFit = true
    for _, card in ipairs(grid.cards) do
      cardsFit = cardsFit
        and card.x >= 0
        and card.x + card.w <= App.D.vw
        and card.y + card.h < App.D.vh
    end
    check("map2 grid stays within the content area", cardsFit)
    Core.close(online.id)
    Core.update(1)
    Sessions.remove(online.id)
    sc.hero.slot = 1
    sc.sel = 1
    check(
      "walk to the current stage arrives at once (hop)",
      sc:startWalk(1) == false and sc.hero.state == "hop"
    )
    sc:leave()
    fx.update(1) -- the hop timer would connect now
    check(
      "leave(): hop -> connect timer cancelled, no session opened",
      Sessions.count() == 0,
      Sessions.count()
    )
    check("leave(): hero idle, no path", sc.hero.state == "idle" and sc.hero.path == nil)
    -- camera follows the feet line, not the bob
    sc.L = Map.fit(200, 150, true)
    sc.hero.x, sc.hero.by, sc.hero.y = 100, 60, 58
    local _, cy1 = sc:cameraTarget()
    sc.hero.y = 62
    local _, cy2 = sc:cameraTarget()
    check("camera target ignores the cosine bob", cy1 == cy2)
    Sessions.saveHosts = origSave
    -- keepalive pulse decays in Sessions.update (every scene shares it)
    local rec = Sessions.open({ host = "h", user = "u", cols = 20, rows = 5, noRemember = true })
    rec.pulse = 1
    Sessions.update(0.1)
    check(
      "Sessions.update(dt) decays the keepalive pulse",
      math.abs(rec.pulse - 0.6) < 1e-6,
      rec.pulse
    )
    Sessions.update()
    check("Sessions.update() without dt leaves it", math.abs(rec.pulse - 0.6) < 1e-6)
    -- Landscape grids reserve the folder bar; status bar keeps the way back.
    local D = App.D
    local savedW, savedH = D.w, D.h
    App.setBezel(true, true)
    D.setTermZoom(1)
    D.setOrientation("auto")
    D.resize(1080, 800)
    local c, r = Term.grid(D, false)
    check("1080x800 grid fits below toolbar and folder bar", c == 125 and r == 35, c .. "x" .. r)
    D.resize(1920, 1080)
    c, r = Term.grid(D, false)
    check("1920x1080 grid fits below toolbar and folder bar", c == 225 and r == 46, c .. "x" .. r)
    Core.update(2)
    Sessions.update(0.1)
    local term = Term.new(App, { id = rec.id })
    for _, w in ipairs({ { 1080, 800 }, { 800, 500 }, { 640, 400 } }) do
      D.resize(w[1], w[2])
      term:layout()
      term:drawStatus(rec)
      check(
        string.format("status bar at %dx%d shows F2 lobby, clear of the left text", w[1], w[2]),
        term.statusRight:find("F2 lobby", 1, true) ~= nil and term.statusRightX > term.statusLeftEnd,
        term.statusRight .. " @" .. term.statusRightX .. " left " .. term.statusLeftEnd
      )
    end
    D.resize(savedW, savedH)
    lib.reset()
  end

  -- terminal key routing: F2 / Esc / Esc Esc / overlay-first
  do
    lib.reset()
    Sessions.init(Core)
    local rec = Sessions.open({ host = "h", user = "u", cols = 20, rows = 5, noRemember = true })
    Core.update(1)
    Sessions.update()
    local Term = require("src.scenes.terminal")
    local term = Term.new(App, { id = rec.id })
    term:enter()
    local switched = nil
    local origSwitch = App.switch
    App.switch = function(name)
      switched = name
      return true
    end
    local written = {}
    local origWrite = Core.write
    Core.write = function(id, s)
      written[#written + 1] = s
      origWrite(id, s)
    end
    term:keypressed("f2", none)
    check("F2 -> lobby", switched == "lobby")
    switched = nil
    term.lastEsc = -1
    term:keypressed("escape", none)
    check(
      "single Esc -> raw \\27 to the core, no scene change",
      written[#written] == "\27" and switched == nil
    )
    term:keypressed("escape", none)
    check("Esc Esc within 300 ms -> lobby", switched == "lobby")
    check(
      "Ctrl+Esc chord -> lobby",
      Keys.appChord("escape", ctrl) == "lobby" and Keys.appChord("f2", none) == "lobby"
    )
    -- an open overlay takes the Esc first
    switched = nil
    App.scene, App.sceneName = term, "terminal"
    App.overlays = {}
    App.push("help")
    local before = #written
    App.keypressed("escape")
    check(
      "Esc closes the overlay first",
      App.overlays[1] and App.overlays[1].closing == true and #written == before and switched == nil
    )
    -- AI panel: single Esc closes it
    App.overlays = {}
    term:toggleAI()
    do
      local clip = love.system.getClipboardText
      love.system.getClipboardText = function()
        return "echo chat-only"
      end
      term.ai.input.value = ""
      term.ai.input.selectAll = false
      term:keypressed("v", { gui = true })
      term:keypressed("left", none)
      term:keypressed("up", none)
      check(
        "AI paste and arrows never write to SSH",
        #written == before and term.ai.input.value == "echo chat-only"
      )
      term:keypressed("a", { gui = true })
      term:textinput("replacement prompt")
      check(
        "AI select-all replaces the prompt",
        term.ai.input.value == "replacement prompt" and #written == before
      )
      love.system.getClipboardText = clip
    end
    term:keypressed("escape", none)
    check("Esc closes the AI panel", term.aiOpen == false and #written == before)
    App.overlays = {}
    App.scene, App.sceneName = nil, nil
    App.switch, Core.write = origSwitch, origWrite
    lib.reset()
  end

  do
    -- 100 sessions, including duplicates, survive JSONL snapshot/restore with names.
    local Sessions = App.sessions
    local Core = App.core
    local mock = Core.lib
    mock.reset()
    Sessions.init(Core)
    Sessions.hosts = {}
    Sessions.nameCounter = 0
    local saved, saveHosts = nil, Sessions.saveHosts
    local saveSnapshot, loadSnapshot = Core.sessionsSave, Core.sessionsLoad
    Sessions.saveHosts = function()
      return true
    end
    Core.sessionsSave = function(text)
      saved = text
      return true
    end
    Core.sessionsLoad = function()
      return saved or ""
    end
    Sessions.persistSessions = true
    -- Remembered directory: a restored session types `cd` back to where it
    -- was once the prompt has settled, then keeps following the shell.
    saved = require("src.json").encode({
      hosts = { { host = "localhost", user = "test", name = "dir-1", cwd = "/srv/app" } },
    })
    Sessions.restore(80, 24)
    local dirRec = Sessions.list[1]
    check(
      "restore carries the saved directory",
      dirRec and dirRec.wantCwd == "/srv/app" and dirRec.cwd == "/srv/app"
    )
    Core.update(2)
    Sessions.update(0.1)
    check("cd waits for the screen to settle", dirRec.wantCwd == "/srv/app")
    Sessions.update(0.5)
    check(
      "cd typed once the prompt is quiet",
      dirRec.wantCwd == nil and Core.cwd(dirRec.id) == "/srv/app"
    )
    Core.write(dirRec.id, "cd logs\n")
    Sessions.update(0.1)
    check(
      "new directory saved for the next start",
      dirRec.cwd == "/srv/app/logs" and saved:find("/srv/app/logs", 1, true) ~= nil
    )
    check(
      "cd quoting keeps spaces, quotes and a leading tilde",
      Sessions.cdCommand("/a b's") == " cd '/a b'\\''s'\n"
        and Sessions.cdCommand("~/x y") == " cd ~/'x y'\n"
        and Sessions.cdCommand("~") == " cd ~\n"
        and Sessions.cdCommand("") == nil
    )
    mock.reset()
    Sessions.list, Sessions.byId, saved = {}, {}, nil
    for _ = 1, 100 do
      Sessions.open({ host = "localhost", user = "test", noRemember = true })
    end
    check(
      "100 sessions receive simple memorable names",
      #Sessions.list == 100
        and Sessions.list[1].name == "mary-1"
        and Sessions.list[2].name == "john-2"
    )
    check("unconnected attempts are not saved for restore", saved == nil)
    Core.update(2)
    Sessions.update(0.1)
    Sessions.rename(Sessions.list[2].id, "work-2")
    local entries = require("src.json").decode(saved).hosts
    check(
      "100 connected sessions saved separately with custom names",
      #entries == 100 and entries[2].name == "work-2"
    )
    check("session snapshots exclude passwords", not saved:find("password", 1, true))
    local grid = require("src.scenes.map2").new(App)
    check("Map2 includes all 100 sessions", #grid.shown == 100)
    local map = require("src.scenes.map").new(App)
    check("Mario Map allocates all 100 session stages", #map.hosts == 100 and map.pages >= 10)
    mock.reset()
    Sessions.list, Sessions.byId = {}, {}
    Sessions.restore(80, 24)
    check(
      "startup restore recreates 100 distinct sessions and names",
      #Sessions.list == 100
        and Sessions.list[1].name == "mary-1"
        and Sessions.list[2].name == "work-2"
    )
    Sessions.close(Sessions.list[1].id)
    check(
      "explicit close removes session from next startup",
      #require("src.json").decode(saved).hosts == 99
    )
    -- Completion appends only a suffix and never a newline; hidden prompts cannot accept.
    local term = require("src.scenes.terminal").new(App, { id = Sessions.list[2].id })
    local can, typing, complete, write = Core.canComplete, Core.typing, Core.complete, Core.write
    local sent
    Core.canComplete = function()
      return true
    end
    Core.typing = function()
      return "git st"
    end
    Core.complete = function()
      return { { cmd = "git status" } }
    end
    Core.write = function(_, bytes)
      sent = bytes
    end
    term:acceptCompletion()
    check("terminal completion inserts suffix without execution", sent == "atus")
    sent = nil
    Core.canComplete = function()
      return false
    end
    term:acceptCompletion()
    check("terminal completion refuses hidden or ambiguous prompts", sent == nil)
    Core.canComplete = function()
      return true
    end
    sent = nil
    term.suggestion, term.completionPrefix = "git status", "git st"
    check("ghost text is the untyped suffix", term:ghostText() == "atus")
    term:keypressed("right", { ctrl = false, shift = false, alt = false, gui = false })
    check("Right arrow accepts the ghost completion", sent == "atus")
    sent = nil
    term.suggestion = nil
    term:keypressed("right", { ctrl = false, shift = false, alt = false, gui = false })
    check("Right arrow without a suggestion is not swallowed", sent ~= "atus")
    term.suggestion, term.completionPrefix = "git status", "git st"
    term.aiOpen = true
    check("no ghost text while the AI panel owns the keyboard", term:ghostText() == nil)
    term.aiOpen = false
    Core.canComplete, Core.typing, Core.complete, Core.write = can, typing, complete, write
    Core.update(2)
    Sessions.update(0.1)
    local oldScene, oldName, oldTransition = App.scene, App.sceneName, fx.transitioning
    App.scene, App.sceneName, fx.transitioning = { refresh = function() end }, "map2", false
    local victim = Sessions.list[2]
    check("explicit disconnect begins circular animation", App.disconnectSession(victim))
    check(
      "disconnect intent persists before animation ends",
      victim.closing and #json.decode(saved).hosts == 98
    )
    check("disconnect cannot be triggered twice", not App.disconnectSession(victim))
    check("navigation is held during disconnect", not App.switch("lobby"))
    App.updateIris(0.2)
    check("iris keeps transport alive before midpoint", Core.state(victim.id) == Core.ST.CONNECTED)
    App.updateIris(0.3)
    Core.update(1)
    Sessions.update(0.1)
    check(
      "iris closes only chosen session at midpoint",
      Sessions.get(victim.id) == nil and Sessions.count() == 98
    )
    App.updateIris(0.6)
    check(
      "iris releases navigation and refuses stale record",
      App.iris == nil and not App.disconnectSession(victim)
    )
    App.scene, App.sceneName, fx.transitioning = oldScene, oldName, oldTransition
    Sessions.persistSessions = false
    Sessions.saveHosts, Core.sessionsSave, Core.sessionsLoad = saveHosts, saveSnapshot, loadSnapshot
    mock.reset()
    Sessions.list, Sessions.byId, Sessions.hosts = {}, {}, {}
  end

  do
    local P = require("src.terminal_files")
    check(
      "terminal filename resolves against reported cwd",
      P.resolve("/srv/work", "report.txt") == "/srv/work/report.txt"
    )
    check(
      "terminal absolute and home paths stay absolute",
      P.resolve("/srv", "/tmp/a") == "/tmp/a" and P.resolve("/srv", "~/a") == "~/a"
    )
    check(
      "terminal download rejects multiline and URL text",
      P.resolve("/srv", "a\nb") == nil and P.resolve("/srv", "https://example.com/a") == nil
    )
    check(
      "terminal file links strip compiler line numbers",
      P.resolve("/srv", "main.rs:12:4") == "/srv/main.rs"
    )
    local function token(line, col)
      local cells, x = {}, 0
      for _, cp in utf8.codes(line) do
        local width = Core.utf8Width(utf8.char(cp))
        cells[x] = { cp = cp, width = width }
        if width == 2 then
          cells[x + 1] = { cp = 0, width = 0 }
        end
        x = x + width
      end
      return P.at({ cells = cells, cols = x, rows = 1 }, col, 0)
    end
    check(
      "terminal file links parse quoted spaces",
      token("a.txt 'my report.txt' b.txt", 12).name == "my report.txt"
    )
    check(
      "terminal file links parse escaped spaces",
      token("my\\ report.txt", 4).name == "my report.txt"
    )
    check("terminal file links preserve Unicode", token("한글.txt", 2).name == "한글.txt")
    check("terminal whitespace is not a file link", token("a.txt    b.txt", 7) == nil)
  end

  do
    local Sessions = require("src.sessions")
    local original = Sessions.core
    local reported, wrote = "/home/test", false
    Sessions.core = {
      mock = false,
      typing = function()
        return ""
      end,
      cwd = function()
        return reported
      end,
      write = function()
        wrote = true
      end,
      kvSet = function()
        return true
      end,
    }
    local rec = { id = 0, wantCwd = "/srv/project", cwd = "/srv/project", lastGen = 7, quiet = 0.5 }
    Sessions.trackCwd(rec, 7, 0.5)
    Sessions.trackCwd(rec, 7, 0.1)
    check(
      "queued restore does not overwrite saved cwd with login folder",
      wrote and rec.cwd == "/srv/project" and rec.restoreGen == 7
    )
    reported = "/srv/project"
    Sessions.trackCwd(rec, 8, 0.1)
    check(
      "restore learns only after the new folder report",
      rec.restoreGen == nil and rec.cwd == "/srv/project"
    )
    Sessions.core = original
  end

  do
    local Transfer = require("src.scenes.transfer")
    local rec, request, popped = {}, nil, false
    local state = { state = "running", done = 12, total = 24 }
    local app = {
      time = 5,
      sessions = {
        get = function()
          return rec
        end,
      },
      pop = function()
        popped = true
      end,
      toast = function() end,
      core = {
        cwd = function()
          return "/srv/work"
        end,
        filesStart = function(_, req)
          request = req
          return true
        end,
        filesStatus = function()
          return state
        end,
      },
    }
    local sheet =
      Transfer.new(app, { id = 0, op = "upload", path = "/tmp/my file.txt", auto = true })
    sheet:update(0.1)
    check(
      "terminal drop starts transfer with no extra confirmation",
      request
        and request["local"] == "/tmp/my file.txt"
        and request.remote == "/srv/work/my file.txt"
        and popped
    )
    check(
      "background transfer retains paths for details and retry",
      rec.quickTransfer.source == "/tmp/my file.txt"
        and rec.quickTransfer.destination == "/srv/work/my file.txt"
    )
    state = { state = "done", done = 24, total = 24 }
    sheet:update(0.1)
    local details = Transfer.new(app, { id = 0, details = true })
    check(
      "completed transfer reopens with exact paths",
      details.done
        and details.source == "/tmp/my file.txt"
        and details.field.value == "/srv/work/my file.txt"
    )
    rec = {}
    app.core.cwd = function()
      return ""
    end
    request = nil
    sheet = Transfer.new(app, { id = 0, op = "upload", path = "/tmp/my file.txt", auto = true })
    sheet:update(0.1)
    check(
      "unknown terminal folder asks for destination instead of guessing",
      request == nil and not sheet.auto and sheet.field.value == ""
    )
    sheet = Transfer.new(app, { id = 0, op = "download", path = "report.txt", auto = true })
    sheet:update(0.1)
    check(
      "unknown folder never guesses a download source",
      request == nil and sheet.remote and sheet.source == ""
    )
  end

  do
    local Term = require("src.scenes.terminal")
    local pushed, writes = nil, 0
    local app = {
      D = { vh = 200 },
      audio = { play = function() end },
      toast = function() end,
      core = {
        write = function()
          writes = writes + 1
        end,
      },
      push = function(name, params)
        pushed = { name = name, params = params }
      end,
    }
    local sc = Term.new(app, { id = 7 })
    local tv = { cols = 14, rows = 1, cells = {}, sel = {} }
    for i = 1, 14 do
      tv.cells[i - 1] = { cp = ("report.txt    "):byte(i), width = 1 }
    end
    function tv:selectedText()
      return self.sel and "stale.txt" or nil
    end
    sc.view = function()
      return tv
    end
    sc.cellAt = function(_, x)
      return math.floor(x / 8), 0
    end
    sc.ox, sc.oy, sc.gw, sc.gh, sc.top = 0, 16, 112, 16, 16
    sc:toggleDownloadPick()
    check(
      "DOWNLOAD arms picking without opening a dialog",
      sc.downloadPicking and not pushed and tv.sel == nil
    )
    sc:mousepressed(100, 20, 1)
    check(
      "download picking ignores whitespace and stays active",
      sc.downloadPicking and not pushed and not sc.dragging
    )
    sc:mousepressed(12, 20, 1)
    check(
      "plain filename click starts the automatic download",
      pushed
        and pushed.name == "transfer"
        and pushed.params.path == "report.txt"
        and pushed.params.auto
        and not sc.downloadPicking
    )
    pushed = nil
    sc:toggleDownloadPick()
    sc:keypressed("escape", { ctrl = false, shift = false })
    check(
      "Esc cancels download picking without reaching the shell",
      not sc.downloadPicking and writes == 0 and not pushed
    )
    sc:toggleDownloadPick()
    sc:toggleDownloadPick()
    check("DOWNLOAD toggles picking off again", not sc.downloadPicking)
  end

  if fails == 0 then
    print("OK " .. n .. " tests")
    return true
  end
  print(string.format("FAIL %d of %d tests", fails, n))
  return false
end

return M
