# CAUSEWAYBAY OFFICE — visual style guide

A retro terminal that feels like a 1989 MSX2 / Genesis / Amiga game booted in a
Causeway Bay flat: chunky pixels, hot neon over deep night navy, rust-orange
hero, beige CRT plastic. Same universe and asset conventions as CAUSEWAYBAY
RAIDEN. Everything is drawn into a low-res virtual canvas and scaled up with
**nearest** filtering; nothing is anti-aliased.

Sources: `python/gen_art.py` (prompts + generator), `love2d/assets/` (output).

---

## 1. Palette

### 1.1 MSX base (from Raiden `gfx.lua`, floats -> hex)

| name     | hex       | use |
|----------|-----------|-----|
| black    | `#000000` | outlines, terminal bg (ANSI 0) |
| navy     | `#1A1A59` | panel fills, ANSI blue-ish |
| dblue    | `#5954E0` | ANSI blue |
| lblue    | `#8075F2` | ANSI bright blue |
| cyan     | `#66DBF0` | ANSI cyan, link icon highlight |
| dgreen   | `#3BA340` | ANSI green |
| green    | `#3DB84A` | LED "connected" |
| lgreen   | `#73D17D` | ANSI bright green |
| dred     | `#BA5E52` | ANSI red |
| rust     | `#DB6644` | **hero / primary accent** (ANSI bright red slot) |
| lred     | `#FF8A7D` | hover on rust |
| dyellow  | `#CCC25E` | ANSI yellow |
| yellow   | `#DED187` | ANSI bright yellow, key icon |
| magenta  | `#B866B5` | ANSI magenta (note: NOT the chroma key) |
| gray     | `#CCCCCC` | ANSI white, disabled text |
| white    | `#FFFFFF` | ANSI bright white, highlights |

### 1.2 App accents (added for OFFICE)

| name           | hex       | use |
|----------------|-----------|-----|
| rust           | `#DB6644` | primary: focused card border, cursor block, buttons, hero hair/hoodie |
| rust_dark      | `#9E4630` | rust shadow line (card border inner shadow) |
| neon_pink      | `#FF4FA3` | secondary accent: search highlight, selected list row, rename caret |
| neon_cyan      | `#3DF2F2` | tertiary: links, hostnames, AI streaming text glow |
| night_navy     | `#0E1030` | **app background** behind everything (lobby, overlays) |
| panel_navy     | `#1A1F4F` | card / panel fill (matches `card_frame.png` interior) |
| phosphor_amber | `#FFB000` | terminal default fg, `icon_session` cursor, LED "connecting" |
| phosphor_green | `#33FF66` | alt terminal fg (settings toggle), LED "connected" glow |
| alarm_red      | `#FF3B30` | disconnected flicker, LED "error" |
| led_off        | `#3A3A44` | LED off / idle |
| bezel_beige    | `#C9BFA0` | CRT plastic (from `bezel.png`) |
| bezel_shadow   | `#8C8468` | CRT plastic shadow |
| chroma_key     | `#FF00FF` | **never draw this** — sprite backdrop keyed out by the shader |

Rules of thumb
* Background is `night_navy`, panels are `panel_navy`, text is `gray`/`white`,
  one accent at a time: rust for focus/primary, neon_pink for selection,
  neon_cyan for data. Do not put pink and rust on the same element.
* Terminal colors come from Rust already resolved (16 ANSI mapped onto the MSX
  base above, plus 256/truecolor pass-through). Default fg = phosphor_amber on
  black.
* Glow = draw the shape a second time at 2px offset with alpha 0.25, same hue.
  No blur shaders.

### 1.3 Chroma key convention (identical to Raiden)

Sprites are generated on a flat `#FF00FF` backdrop. `gfx.lua`'s shader drops a
pixel when `g < 0.46 && r > 0.70 && b > 0.70 && ((r+b)/2 - g) > 0.42`.
`gen_art.py` post-processes every sprite so the backdrop is *exactly* `#FF00FF`
(the model tends to drift toward deep pink `#F713A1`, which would fail the
`b > 0.70` test). `python3 python/gen_art.py --check` reports the backdrop of
every file; `--fix` re-normalises existing files.

Files are real PNG (the xAI API returns JPEG; the script converts with macOS
`sips`). If `sips` is unavailable the script writes `<name>.jpg` instead —
LÖVE loads both, so the loader should try `.png` then `.jpg`.

---

## 2. Typography

| role | font | size (virtual px) | notes |
|------|------|------|-------|
| headings, logo caption, card names, menu labels, key hints | `assets/fonts/PressStart2P.ttf` | 8 / 16 | uppercase; 8px for hints and badges, 16px for scene titles |
| terminal grid, body, AI chat, search results, any user text | `assets/fonts/unifont.otf` | 16 | covers CJK / Hangul / Kana / Czech; wide glyphs take 2 cells (16px) |
| numbers in LED/HUD | PressStart2P | 8 | monospace already |

* Terminal cell = **8 x 16 px** (Unifont advance). Wide CJK cell = 16 x 16.
* Never scale fonts fractionally; only integer multiples of the virtual scale.
* Line height: PressStart2P 8px -> 12px leading; Unifont 16px -> 16px (no
  extra leading in the grid, 4px extra in chat bubbles).
* Text shadow: 1px down-right in `black` at alpha 0.6 on anything drawn over
  a background image.

---

## 3. Spacing and grid

* Base unit **8 px** (virtual). All paddings, gaps and panel positions are
  multiples of 8; icon boxes are 32 or 16.
* Virtual resolution: 640 x 360 (16:9) scaled by the largest integer that fits
  the window (display.lua). Assets are 1024/1280-class and drawn scaled down
  with nearest filtering, so pick draw sizes that are integer divisors of the
  source where possible (1280 -> 320 / 160 / 80; 1024 -> 128 / 64 / 32).
* Safe area: 16px inset from the bezel hole on every side.
* Card grid in lobby: 3 columns x 2 rows of 176 x 96 cards, 16px gutters.

---

## 4. Motion

Easing: **expo** only (`easeOutExpo` for things arriving/appearing,
`easeInExpo` for things leaving, `easeInOutExpo` for moves). Nothing cuts.

| event | duration | easing | notes |
|-------|----------|--------|-------|
| micro: hover, focus ring, button press, LED change | 180 ms | out-expo | color/alpha tween only |
| panel open / close, overlay slide, card slide-in / pop-out | 320 ms | out-expo in / in-expo out | slide 24px + alpha |
| scene fade (boot -> lobby -> terminal) | 600 ms | in-out-expo | fade through `night_navy`, not black |
| heartbeat pulse (each keepalive `last_ping` change) | 240 ms | out-expo up, in-expo back | scale 1.00 -> 1.08 -> 1.00 around card centre; also brightens the green LED |
| cursor breathe | 1200 ms loop | sine | alpha 0.55 -> 1.0 on the rust block |
| disconnected flicker | 90 ms on / 120 ms off, x3 then 1.4 s pause | step | border + LED go `alarm_red` |
| bell | 120 ms | out-expo | screen shake 3px, white flash alpha 0.35 -> 0 |
| connect success | 600 ms | — | 24 `particle_spark` bursts from the card, gravity 0, drag 0.9, plus jingle |
| boot CRT power-on | 400 ms | out-expo | horizontal white line expands to full canvas, then logo fades 600 ms |

Parallax (boot + lobby background): far layer scrolls at 0.05 px/frame,
mid at 0.15, near at 0.35, all looping horizontally. Mouse / cursor x adds a
+/- 8px offset to near, +/- 3px to mid.

---

## 5. Layouts (640 x 360 virtual)

### 5.1 Lobby

```
+------------------------------------------------------------------+
| [bezel frame around everything; content below is inside the hole] |
| CAUSEWAYBAY OFFICE            [o][o][o] LEDs   [search][gear][ai] |  y=16  8px font, icons 16px
|------------------------------------------------------------------|
|  bg_causeway_far / mid / near parallax, dimmed 60%, behind cards  |
|                                                                  |
|  +----------------+  +----------------+  +----------------+      |  y=56
|  | o neon-tram-07 |  | o jade-junk-42 |  | o dimsum-ferry |      |  card_frame 176x96
|  | leejw@hk-box   |  | root@10.0.0.7  |  | dev@build      |      |  LED 8px, name 8px font
|  | [terminal icon]|  | [terminal icon]|  | [terminal icon]|      |  icon_session 32px
|  +----------------+  +----------------+  +----------------+      |
|  +----------------+  +----------------+  +- - - - - - - - +      |  y=168
|  | ...            |  | ...            |  |  + new (Ctrl+N)|      |  dashed ghost card
|  +----------------+  +----------------+  +- - - - - - - - +      |
|                                                                  |
|  ____[shelf]__________________________________________________  |  y=296 shelf line
|   [hero_idle 96x54]   [dimsum 32] [milktea 32] [tram 48]         |  y=280..336 props sit on shelf
|  F1 help  ^N new  ^K search  ^R rename  ^, settings  ^Space ai   |  y=344 8px hints, gray
+------------------------------------------------------------------+
```

* Focused card: rust border glow + LED pulse; others at 85% brightness.
* Card states: `connecting` amber LED blinking 500 ms; `connected` green;
  `disconnected` red flicker; `closed` LED off, card pops out (in-expo 320 ms).
* New card slides in from the right (out-expo 320 ms) and its LED runs the
  connect animation.

### 5.2 Terminal

```
+------------------------------------------------------------------+
| o neon-tram-07  leejw@hk-box:~        [2/3]  ^Tab  [ai] [search] |  y=0..16 tab strip, panel_navy
|------------------------------------------------------------------|
| $ ls                                                             |  grid 8x16 cells
| Cargo.toml  src  target                                          |  80 x 21 cells at 640x336
| $ echo 你好 안녕 こんにちは Příliš žluťoučký kůň                  |  wide glyphs = 2 cells
| 你好 안녕 こんにちは Příliš žluťoučký kůň                          |
| $ █                                                              |  rust block cursor, breathing
|                                                                  |
|                                        (scanline + barrel overlay)|
|------------------------------------------------------------------|
| [green LED] 15s keepalive   ping 12ms      UTF-8  80x21   F1 help |  y=344 status, 8px
+------------------------------------------------------------------+
```

* Scanlines: 1px black lines every 2px at alpha 0.12; barrel: the CRT canvas
  from Raiden's display.lua with strength 0.04.
* The bezel is drawn last, over the whole window, with its hole covering the
  virtual canvas.

### 5.3 AI panel (Ctrl+Space, slides in from the right, 320 ms)

```
                              +---------------------------------+
                              | [agent_claude 32] claude-opus-5 |  provider row, 8px
                              | (claude) (grok) (openai)   [x]  |  three mascots, selected one bright
                              |---------------------------------|
                              | you> why does vim show ^M ?     |  Unifont 16
                              |                                 |
                              | ai>  Those are CRLF line ...    |  streaming; neon_cyan glow
                              |      ...                        |  on the last 2 chars while streaming
                              |                                 |
                              |---------------------------------|
                              | > ask about this terminal_      |  input, pink caret
                              | Enter send  ^L attach screen    |  8px hints
                              +---------------------------------+
                                width 256, full height, card_frame 9-slice
```

* Panel background `panel_navy` at alpha 0.96 over the terminal; terminal
  keeps rendering underneath.
* Mascot of the active provider bobs 2px on a 1.6 s sine while streaming.

---

## 6. Asset catalogue

All sprites are on `#FF00FF` and must be drawn through `gfx.chroma`. Sizes
below are the source size, then the intended on-screen size in the 640x360
virtual canvas (draw with nearest filter, `scale = target / source`).

| file | src px | type | draw at | purpose / notes |
|------|--------|------|---------|-----------------|
| `logo_hero.png` | 1280x720 | opaque | 640x360 full screen | boot / title key art: rust coder in a rainy Causeway Bay street, no lettering (neon glyphs are abstract). Fade in 600 ms after CRT flash; draw title text in PressStart2P 16px in the clear sky band (top third, centre). |
| `bg_causeway_far.png` | 1280x720 | opaque | 640x360, loop x | far parallax: harbour skyline + purple-navy sky, tileable. Bottom edge is black hills — sits fine under mid. |
| `bg_causeway_mid.png` | 1280x720 | **chroma** | 640x360, loop x | mid parallax: tong lau + neon signs, sky is keyed. Building strip occupies the lower ~65%. |
| `bg_causeway_near.png` | 1280x720 | **chroma** | 640x360, loop x | near parallax: tram, stop, stalls, steamers, wet road; sky keyed. Content in the lower ~50%. Not seamless — hide the seam by scrolling faster than mid and overlapping the shelf. |
| `bezel.png` | 1280x720 | chroma | window-sized overlay | MSX-beige CRT frame. Outer frame bbox x310..970 y74..648; **screen hole x384..895 y144..546 (512x403)**. Scale so the hole covers the virtual canvas (hole is ~4:3; stretch x and y independently, that is fine for plastic). Tiny green power LED bottom-right. |
| `card_frame.png` | 1024x1024 | chroma | 176x96 via 9-slice | navy `#1A1F4F` panel with rust border + corner rivets. Frame bbox x86..938 y90..932. **9-slice insets: 64 px** on every side (source px), i.e. slice at 150 / 874. Corner rivets live inside the corner slices. |
| `led_strip.png` | 1280x720 | chroma | 8x8 per lamp (16 for status bar) | four lamps, cut as **4 cells of 320x720**: cell 0 green, 1 amber, 2 red, 3 off. Lamp bbox in each cell ~x85..330 y245..479 (centre the cell, not the lamp). |
| `particle_spark.png` | 1280x720 | chroma | 8x8 .. 16x16 | 4-frame burst, **4 cells of 320x720** (dot, small star, big burst, fading rays). Play 4 frames over 240 ms. |
| `hero_idle.png` | 1280x720 | chroma | 96x54 per frame on the shelf | rust coder typing at a desk, side view, **4 cells of 320x720**, ~8 fps loop. Frame content is ~x60..296 y214..500 of cell 0, drifting up to 18 src px per cell (<=1 virtual px at 96 wide). |
| `icon_session.png` | 1024x1024 | chroma | 32 (card), 16 (tab strip) | beige CRT with amber cursor; content bbox x284..740 y284..738 |
| `icon_search.png` | 1024x1024 | chroma | 16 (toolbar), 32 (search overlay title) | cyan magnifier, rust handle |
| `icon_settings.png` | 1024x1024 | chroma | 16 / 32 | grey gear, rust hub |
| `icon_ai.png` | 1024x1024 | chroma | 16 / 32 | cream robot face, cyan eyes — the AI panel toggle |
| `icon_link.png` | 1024x1024 | chroma | 16 | chain link — "connected"/host row prefix |
| `icon_key.png` | 1024x1024 | chroma | 16 / 32 | gold key — auth method / API-key fields in settings |
| `agent_claude.png` | 1024x1024 | chroma | 32 (provider row), 16 (chat prefix) | orange starburst creature; content ~x308..716 |
| `agent_grok.png` | 1024x1024 | chroma | 32 / 16 | black X bot with red edges |
| `agent_openai.png` | 1024x1024 | chroma | 32 / 16 | white hex bot, green knot |
| `prop_dimsum.png` | 1024x1024 | chroma | 32 | bamboo steamer, steam curl (steam is light pink: keep) |
| `prop_milktea.png` | 1024x1024 | chroma | 32 | HK milk tea cup + spoon |
| `prop_tram.png` | 1024x1024 | chroma | 48 wide | green/cream double-decker tram; content x174..840 y316..706 (wide, use 48x30) |
| `map_causeway.png` | 1280x720 | opaque | 640x360 full screen | world map overworld; see section 7 for platform centres and path adjacency (`assets/map_nodes.json`). |
| `map_node.png` | 1024x1024 | chroma | 40x24 per frame | stage platform states, **4 cells of 256x1024**: 0 grey unvisited, 1 green online, 2 red cracked error, 3 gold ring selected. Use the per-cell bboxes in section 7 (the discs drift left cell by cell). |
| `hero_walk.png` | 1280x720 | chroma | 32x48 per frame | rust coder walk cycle facing right, **4 cells of 320x720**, ~8 fps; flip x to walk left. |
| `hero_map_idle.png` | 1280x720 | chroma | 32x48 | hero facing camera, **2 cells of 640x720**: 0 eyes open, 1 blink (show 1 for 120 ms every 3-4 s). |
| `map_flag.png` | 1280x720 | chroma | 16x18 | rust pennant with crab, **2 cells of 640x720**, alternate every 250 ms; plant with the pole base on the platform centre. |
| `particle_dust.png` | 1280x720 | chroma | 8x6 .. 12x8 | footstep puff, **4 cells of 320x720** (small tan puff, big cream puff, split, wisps); play over 300 ms behind the hero's heel. |
| `particle_confetti.png` | 1280x720 | chroma | 3x3 .. 4x2 | **4 cells of 320x720**, one colour each: 0 rust, 1 cyan diamond, 2 pale pink, 3 gold strip. |
| `map_cloud.png` | 1280x720 | chroma | 48x22 / 44x28 | two clouds, **2 cells of 640x720**, drift 0.1-0.2 px/frame over the map at alpha 0.85. |

Icons are centred in their 1024 box with roughly 200-280 px of margin, so
drawing the whole image at 32x32 gives a ~20 px glyph with breathing room;
draw at 40 if you want them to fill a 32 box.

Sizes on disk: ~9.4 MB of PNG + 5.4 MB fonts (well under the 40 MB budget).

---

## 7. World map

Every SSH host the user has connected to is a "stage" on an overhead
Super-Mario-World-style map of Causeway Bay (`map_causeway.png`, 1280x720,
opaque, drawn at 640x360). The rust coder walks the dotted paths between
platforms; clicking a platform walks him there and connects. Victoria Park is
top-left, Victoria Harbour and the typhoon shelter junks run along the top,
the tram line crosses the middle, Happy Valley racecourse is bottom-right.

### 7.1 Platform centres (`assets/map_nodes.json`)

Ten empty beige discs, ~94x77 src px each (radius ~0.037 of the width), in
reading order. Coordinates are fractions of the image (multiply by 640x360):

| # | x | y | where |
|---|-------|-------|-------|
| 0 | 0.122 | 0.189 | Victoria Park lawn |
| 1 | 0.358 | 0.189 | harbourfront promenade |
| 2 | 0.733 | 0.244 | typhoon shelter |
| 3 | 0.890 | 0.213 | north-east pier |
| 4 | 0.078 | 0.470 | west edge (2 px inside the 8% margin at 640 wide; fine for a 40 px node) |
| 5 | 0.900 | 0.547 | east tong lau block |
| 6 | 0.116 | 0.820 | south-west |
| 7 | 0.357 | 0.847 | south, below the tram line |
| 8 | 0.506 | 0.859 | south centre |
| 9 | 0.680 | 0.856 | racecourse gate |

`paths` is the adjacency of the drawn dotted trails: a spanning chain
0-1-2-3-5-9-8-7-6-4 plus branches 4-0, 1-7 (the vertical trail at x~0.40) and
2-9 (the vertical trail at x~0.70). Hosts beyond ten reuse platforms in
order (offset the extra node 12 px down-right). Draw nodes with their disc
centre on the platform centre; the hero stands with his feet 6 px above it.

### 7.2 Strip cells

The model does not centre every frame identically, so `map_nodes.json`
carries per-cell content bboxes (`strips.<name>.bbox[cell] = [x0,y0,x1,y1]`
in source px, x relative to the cell). Build quads from those bboxes and
anchor on the bbox bottom-centre so frames do not wobble.
`python3 python/gen_art.py --measure` reprints them.

| file | cells | cell size | content bbox per cell (local x0..x1, y0..y1) |
|------|-------|-----------|-----------------------------------------------|
| `map_node.png` | 4 | 256x1024 | 46..228 / 22..232 / 26..210 / 6..216, y 430..590 |
| `hero_walk.png` | 4 | 320x720 | 96..270 / 80..248 / 62..236 / 48..216, y 168..548 |
| `hero_map_idle.png` | 2 | 640x720 | 218..434 / 174..392, y 148..572 |
| `map_flag.png` | 2 | 640x720 | 204..542 / 108..446, y 182..542 (pole base at bbox bottom-left) |
| `particle_dust.png` | 4 | 320x720 | 134..270 / 58..266 / 42..238 / 16..206, y 282..436 |
| `particle_confetti.png` | 4 | 320x720 | 138..250 / 98..236 / 86..198 / 52..180, y 290..428 |
| `map_cloud.png` | 2 | 640x720 | 246..564 y300..446 / 96..392 y266..456 |

### 7.3 Motion on the map

* Walk: 8 fps `hero_walk`, 48 px/s along the path polyline, `particle_dust`
  every 4th frame at the heel. Arriving at a platform: switch to
  `hero_map_idle`, node flips to cell 1 (green) with 24 `particle_confetti`
  pieces (gravity 60 px/s^2, drag 0.95, 900 ms), flag plants with a 320 ms
  out-expo drop from 12 px above.
* Node states map to LED states: unvisited -> cell 0, connecting -> cell 0
  pulsing alpha 0.6..1.0, connected -> cell 1, disconnected -> cell 2 with the
  90/120 ms flicker, focused -> cell 3 drawn over the state cell.
* Clouds: two `map_cloud` sprites drift left at 0.1 and 0.2 px/frame, wrap.
* Camera: whole map fits in 640x360; no scrolling. Hover a node: scale
  1.0 -> 1.12 over 180 ms out-expo.

---

## 8. Regenerating

```
export GROK_API_KEY=...            # same key as XAI_API_KEY
python3 python/gen_art.py          # only missing files
python3 python/gen_art.py --force --only icon_ai   # redo one (tweak its prompt first)
python3 python/gen_art.py --check  # backdrop report (edge-chroma should be 100% for sprites)
python3 python/gen_art.py --fix    # re-normalise backdrops of existing sprites
python3 python/gen_art.py --dry-run --only bezel   # print the prompt
```

Prompt recipe: shared prefix (`16-bit pixel art, MSX2 / Sega Genesis / Amiga
era, chunky pixels, limited palette, crisp, no anti-aliasing, no text, no
watermark`) + subject + for sprites the backdrop clause (`isolated on a flat
solid hot magenta #FF00FF background (pure magenta, RGB 255 0 255 ...)`).
Say "abstract glyph shapes, not readable text" whenever signage is wanted;
the model otherwise writes real brand names. Strips: ask for "four frames in a
horizontal row, evenly spaced, same size and position in every frame" and use
a 16:9 canvas so each cell is 320 px. Pink details near magenta (confetti)
must be asked for as "pale pastel pink #FFB6C1" with a black outline and
`fix="flood"`, or the normaliser keys them out. `--variants N` writes
`<name>_v1..N` candidates for a subjective pick (used for the world map).
