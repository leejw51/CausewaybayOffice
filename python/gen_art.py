#!/usr/bin/env python3
"""
CAUSEWAYBAY OFFICE - asset generator (xAI grok-imagine-image).

Stdlib only (urllib + json + base64). No PIL.

Usage:
    python3 python/gen_art.py               # generate every missing asset
    python3 python/gen_art.py --only bezel  # one asset (name without extension)
    python3 python/gen_art.py --force       # regenerate even if the file exists
    python3 python/gen_art.py --list        # print the asset table
    python3 python/gen_art.py --dry-run     # print prompts, no API calls
    python3 python/gen_art.py --check       # backdrop report of existing PNGs
    python3 python/gen_art.py --measure     # per-cell content bbox of strips
    python3 python/gen_art.py --variants 2 --only map_causeway  # candidates _v1/_v2

Env: GROK_API_KEY (or XAI_API_KEY).

Convention (same as CausewaybayRaiden): sprites are generated on a flat hot
magenta #FF00FF backdrop; the game's chroma-key shader drops pixels where
g < 0.46, r > 0.70, b > 0.70.  Backgrounds / key art are full illustrations.

The API returns JPEG bytes.  On macOS we convert to real PNG with `sips` so
the files match the names the Lua side codes against; if sips is missing the
bytes are written as <name>.jpg instead (LOVE loads both; see docs/STYLE.md).
"""

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "love2d", "assets")
ENDPOINT = "https://api.x.ai/v1/images/generations"
MODELS = ["grok-imagine-image", "grok-imagine-image-2.0"]

STYLE = (
    "16-bit pixel art, MSX2 / Sega Genesis / Amiga era, chunky pixels, "
    "limited palette, crisp, no anti-aliasing, no text, no watermark"
)
SPRITE = (
    "isolated on a flat solid hot magenta #FF00FF background (pure magenta, "
    "RGB 255 0 255, electric fuchsia, not pink, not purple), nothing else in "
    "frame, no shadow on the background, no gradient, no vignette"
)
HERO = (
    "the rust coder hero: young programmer with spiky rust-orange hair, "
    "rust-orange hoodie with a small crab logo, dark jeans, sneakers, "
    "Wonder Boy / MSX2 chunky pixel sprite style"
)
CWB = (
    "Causeway Bay Hong Kong at night: dense tong lau apartment blocks, Times "
    "Square tower, Sogo department store, glowing Chinese neon signs in pink "
    "cyan and orange (abstract glyph shapes, not readable text), double-decker "
    "trams, wet market awnings, dim sum steam, wet reflective street"
)

# name -> dict(prompt=..., aspect="16:9"|"1:1"|..., sprite=bool)
ASSETS = {
    # ---- full illustrations (NOT magenta) ---------------------------------
    "logo_hero": dict(
        aspect="16:9",
        sprite=False,
        prompt=(
            "title key art, wide cinematic composition, " + HERO + " (hair "
            "and hoodie clearly bright rust orange #DB6644) standing in the "
            "middle of a rain-slick Causeway Bay street at night, laptop with "
            "a red crab sticker tucked under one arm, looking up at the neon, "
            + CWB + ", a red double-decker tram passing behind him, night "
            "navy sky, dramatic neon rim light, Wonder Boy in Monster World "
            "title screen mood, detailed pixel illustration, leave the upper "
            "third of the sky fairly clear for a title, absolutely no Latin "
            "letters, no brand names, no logos, no readable words anywhere: "
            "all signs are abstract neon glyph shapes only"
        ),
    ),
    "bg_causeway_far": dict(
        aspect="16:9",
        sprite=False,
        prompt=(
            "distant parallax background layer, wide, Hong Kong Causeway Bay "
            "and Victoria Harbour skyline silhouette at dusk turning to night, "
            "night navy and deep purple gradient sky, a few stars, tiny "
            "distant window lights, Lion Rock hills in the far back, calm, "
            "low detail, seamless horizontally tileable, left and right edges "
            "match perfectly, no foreground objects"
        ),
    ),
    "bg_causeway_mid": dict(
        aspect="16:9",
        sprite=True,
        fix="flood",
        prompt=(
            "mid-distance parallax layer, wide, a continuous unbroken row of "
            "Causeway Bay Hong Kong tong lau apartment buildings and shopping "
            "towers at night filling the full width and the lower two thirds "
            "of the frame, glowing neon signboards in pink, cyan, orange and "
            "green (abstract glyph shapes only, not readable text), lit "
            "windows, air conditioners, bamboo scaffolding, rooftop water "
            "tanks, buildings of varied heights, seamless horizontally "
            "tileable, left and right edges match perfectly, no street, no "
            "ground, no people, the sky above the rooftops is " + SPRITE
        ),
    ),
    "bg_causeway_near": dict(
        aspect="16:9",
        sprite=True,
        fix="flood",
        prompt=(
            "near foreground parallax layer, wide, Causeway Bay Hong Kong "
            "street level at night filling the lower half of the frame: a "
            "green and cream Hong Kong double-decker tram on rails, tram stop "
            "shelter, street lamps, shop awnings, wet market stall with "
            "fruit, dim sum bamboo steamers steaming, wet reflective asphalt "
            "along the bottom edge, no people, no readable text, everything "
            "above the shop fronts and lamp posts is " + SPRITE
        ),
    ),
    # ---- UI chrome on magenta --------------------------------------------
    "bezel": dict(
        aspect="16:9",
        sprite=True,
        fix="global",
        prompt=(
            "a retro 1980s MSX home computer CRT monitor bezel frame seen "
            "straight on, beige and warm grey plastic with subtle pixel "
            "shading, rounded corners, a thin dark inner rim, a tiny green "
            "power LED and two small dials at the bottom right of the frame, "
            "the entire rectangular screen area in the centre is a flat solid "
            "hot magenta #FF00FF (it will be made transparent), the frame is "
            "wide 16:9 and fills the image edge to edge, " + SPRITE
        ),
    ),
    "card_frame": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a chunky retro video game UI panel frame, square, dark navy "
            "#1A1F4F fill, thick rust-orange #DB6644 pixel border with a "
            "lighter orange highlight line and a darker inner shadow line, "
            "small metal rivets at the four corners, empty plain interior, "
            "designed as a 9-slice frame, flat, " + SPRITE
        ),
    ),
    "led_strip": dict(
        aspect="16:9",
        sprite=True,
        prompt=(
            "four small round retro indicator LED lamps in a horizontal row, "
            "evenly spaced, each one a beveled dark grey bezel around a "
            "glowing dome: bright green, amber yellow, red, and unlit dark "
            "grey, chunky pixel shading with a white specular dot, " + SPRITE
        ),
    ),
    "particle_spark": dict(
        aspect="16:9",
        sprite=True,
        prompt=(
            "sprite sheet strip of four frames in a horizontal row, evenly "
            "spaced, of a small four-pointed star spark bursting: frame one a "
            "tiny white dot, frame two a small yellow-white star, frame three "
            "a large orange and yellow four-pointed star burst, frame four "
            "fading orange rays only, " + SPRITE
        ),
    ),
    # ---- hero mascot ------------------------------------------------------
    "hero_idle": dict(
        aspect="16:9",
        sprite=True,
        prompt=(
            "sprite sheet strip of four idle animation frames in a horizontal "
            "row, evenly spaced, side view of " + HERO + " sitting on a stool "
            "at a small wooden desk typing on a laptop that has a crab "
            "sticker, a mug of Hong Kong milk tea on the desk, in each frame "
            "the hands and head are in a slightly different typing pose, "
            "same size and position in every frame, " + SPRITE
        ),
    ),
    # ---- icons --------------------------------------------------------------
    "icon_session": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred 8-bit icon of a small beige CRT computer "
            "terminal with a dark screen showing a glowing amber block "
            "cursor, thick dark outline, bold simple shapes, large in frame, "
            + SPRITE
        ),
    ),
    "icon_search": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred 8-bit icon of a magnifying glass, cyan lens "
            "with a white glint, rust-orange handle, thick dark outline, bold "
            "simple shapes, large in frame, " + SPRITE
        ),
    ),
    "icon_settings": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred 8-bit icon of a mechanical gear cog, grey "
            "steel with a rust-orange centre, thick dark outline, bold simple "
            "shapes, large in frame, " + SPRITE
        ),
    ),
    "icon_ai": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred 8-bit icon of a cute little robot sidekick "
            "face, rounded cream head, two glowing cyan eyes, small antenna, "
            "rust-orange cheeks, thick dark outline, bold simple shapes, "
            "large in frame, " + SPRITE
        ),
    ),
    "icon_link": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred 8-bit icon of two interlocked chain links, "
            "steel grey with cyan highlights, thick dark outline, bold simple "
            "shapes, large in frame, " + SPRITE
        ),
    ),
    "icon_key": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred 8-bit icon of an old-fashioned brass skeleton "
            "key, golden yellow with a rust-orange shadow, thick dark outline, "
            "bold simple shapes, large in frame, " + SPRITE
        ),
    ),
    # ---- AI sidekick mascots ------------------------------------------------
    "agent_claude": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred tiny cute mascot creature: a warm orange "
            "starburst / sun shaped blob with soft rounded rays, two friendly "
            "black dot eyes and a small smile, cream belly, chunky pixel "
            "shading, thick dark outline, " + SPRITE
        ),
    ),
    "agent_grok": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred tiny cute mascot robot shaped like a bold "
            "letter X, black body with red glowing edges and a red visor eye "
            "strip in the centre, little jet feet, chunky pixel shading, "
            "thick dark outline, " + SPRITE
        ),
    ),
    "agent_openai": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred tiny cute mascot robot with a hexagonal white "
            "body, a green hexagonal knot pattern on its chest, small green "
            "glowing eyes, stubby arms, chunky pixel shading, thick dark "
            "outline, " + SPRITE
        ),
    ),
    # ---- shelf props ----------------------------------------------------------
    "prop_dimsum": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred prop: a stack of two round bamboo dim sum "
            "steamer baskets, the top lid slightly open showing three white "
            "har gow dumplings with a curl of steam, chunky pixel shading, "
            "thick dark outline, " + SPRITE
        ),
    ),
    "prop_milktea": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred prop: a Hong Kong style milk tea in a classic "
            "white ceramic cup on a saucer, tea-brown liquid, a curl of "
            "steam, a small teaspoon, chunky pixel shading, thick dark "
            "outline, " + SPRITE
        ),
    ),
    "prop_tram": dict(
        aspect="1:1",
        sprite=True,
        prompt=(
            "a single centred prop: a toy-like Hong Kong double-decker tram, "
            "side view, green and cream livery, yellow lit windows, small "
            "wheels, chunky pixel shading, thick dark outline, " + SPRITE
        ),
    ),
    # ---- world map (SSH hosts as overworld stages) --------------------------
    "map_causeway": dict(
        aspect="16:9",
        sprite=False,
        prompt=(
            "Super Mario World / Wonder Boy style overworld map, overhead view "
            "with a slight isometric tilt, wide 16:9, a whole-map illustration "
            "of Causeway Bay Hong Kong as a cute game world: Victoria Harbour "
            "deep blue water with pixel wave marks along the entire top edge, a "
            "typhoon shelter with tiny junks and sampans near the top right, "
            "Victoria Park as a big green lawn with pixel trees in the top "
            "left, a tall square Times Square tower and a boxy Sogo department "
            "store in the middle, rows of small tong lau apartment blocks with "
            "little rooftop water tanks, a green and cream double-decker tram "
            "on tram rails running left to right across the middle, tiny dim "
            "sum shops with red awnings and bamboo steamers, the oval Happy "
            "Valley racecourse with a green infield in the bottom right, warm "
            "tan and terracotta ground, night navy shadows, neon pink and cyan "
            "accent lights, EXACTLY EIGHT empty round flat stone plateau "
            "platforms (plain pale beige circular discs with a thin dark rim, "
            "like level markers, nothing standing on them, each about one "
            "twelfth of the image width) spread evenly over the whole map, "
            "far from every edge, joined by winding dotted footpath trails "
            "of cream dots forming one long route with a couple of side "
            "branches, no characters, no people, absolutely no text, no "
            "letters, no numbers, no signs with writing, no labels, no UI, "
            "no border, no frame"
        ),
    ),
    "map_node": dict(
        aspect="1:1",
        sprite=True,
        cells=4,
        prompt=(
            "sprite sheet strip of four frames in a horizontal row, evenly "
            "spaced, same size and centred in every frame, each frame a small "
            "round flat overworld level platform disc seen from slightly "
            "above (a squat cylinder like a Super Mario World map node): frame "
            "one plain grey stone disc, unlit, frame two the same disc glowing "
            "bright green with a soft green light halo, frame three the same "
            "disc cracked and glowing alarm red with a red flicker, frame four "
            "the same grey disc with a thick gold ring around its rim and "
            "small gold sparkles, thick dark outline, chunky pixel shading, "
            + SPRITE
        ),
    ),
    "hero_walk": dict(
        aspect="16:9",
        sprite=True,
        cells=4,
        prompt=(
            "sprite sheet strip of four walk cycle animation frames in a "
            "horizontal row, evenly spaced, full body side view facing right "
            "of " + HERO + " walking: frame one right leg forward, frame two "
            "legs passing, frame three left leg forward, frame four legs "
            "passing, arms swinging, small laptop bag over the shoulder, same "
            "size and same position in every frame, feet on the same "
            "baseline, no desk, no props, " + SPRITE
        ),
    ),
    "hero_map_idle": dict(
        aspect="16:9",
        sprite=True,
        cells=2,
        prompt=(
            "sprite sheet strip of two frames in a horizontal row, evenly "
            "spaced, full body front view facing the camera of " + HERO + " "
            "standing still with arms relaxed at his sides, frame one eyes "
            "open, frame two identical but eyes closed in a blink, same size "
            "and same position in both frames, no desk, no props, " + SPRITE
        ),
    ),
    "map_flag": dict(
        aspect="16:9",
        sprite=True,
        cells=2,
        prompt=(
            "sprite sheet strip of two frames in a horizontal row, evenly "
            "spaced, a small pixel art triangular pennant flag on a thin "
            "wooden pole with a gold ball on top, rust orange flag with a "
            "small white crab emblem, frame one the flag waving to the right, "
            "frame two the flag rippling in a different wave shape, same pole "
            "position in both frames, thick dark outline, " + SPRITE
        ),
    ),
    "particle_dust": dict(
        aspect="16:9",
        sprite=True,
        cells=4,
        prompt=(
            "sprite sheet strip of four frames in a horizontal row, evenly "
            "spaced, animation of a small footstep dust puff, every frame "
            "clearly visible and roughly the same size: frame one a small "
            "round tan puff with a dark tan underside, frame two a bigger "
            "pale cream cloud puff with three lumps, frame three the puff "
            "breaking into two separate cream blobs drifting apart, frame "
            "four three small faint cream wisps fading out, simple flat pixel "
            "shading, no outline, " + SPRITE
        ),
    ),
    "particle_confetti": dict(
        aspect="16:9",
        sprite=True,
        cells=4,
        fix="flood",
        prompt=(
            "sprite sheet strip of four frames in a horizontal row, evenly "
            "spaced, each frame one single tiny flat pixel confetti piece "
            "centred: frame one a rust orange square, frame two a cyan blue "
            "diamond, frame three a pale pastel baby pink #FFB6C1 square "
            "(light pink, clearly lighter than the backdrop, not magenta), "
            "frame four a gold yellow thin strip, each piece solid filled "
            "with a thick black outline, large and bold in each cell, "
            + SPRITE
        ),
    ),
    "map_cloud": dict(
        aspect="16:9",
        sprite=True,
        cells=2,
        prompt=(
            "sprite sheet of EXACTLY TWO different small fluffy white pixel "
            "art clouds, one cloud centred in the left half of the image and "
            "one cloud centred in the right half, nothing else, the left "
            "cloud wide and flat with three bumps, the right cloud taller and "
            "lumpier with two bumps, soft lavender underside shading, Super "
            "Mario World overworld cloud style, thick dark outline, " + SPRITE
        ),
    ),
}


# ---------------------------------------------------------------------------
# --check: sample the backdrop of generated PNGs against the chroma rule
# (stdlib PNG decoder: 8-bit RGB/RGBA, non-interlaced, which is what sips writes)
# ---------------------------------------------------------------------------
import struct
import zlib


def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, w, h, ctype, bitd = 8, [], 0, 0, 0, 0
    while pos < len(data):
        ln, = struct.unpack(">I", data[pos:pos + 4])
        typ = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, bitd, ctype, _, _, il = struct.unpack(">IIBBBBB", body)
            if bitd != 8 or ctype not in (2, 6) or il:
                raise ValueError("unsupported PNG (bitdepth %d ctype %d)" % (bitd, ctype))
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
        pos += 12 + ln
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(b"".join(idat))
    stride = w * bpp
    out = bytearray(w * h * bpp)
    prev = bytearray(stride)
    i = 0
    for y in range(h):
        ft = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        if ft == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 255
        elif ft == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif ft == 3:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif ft == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, bpp, bytes(out)


def is_chroma(r, g, b):
    r, g, b = r / 255.0, g / 255.0, b / 255.0
    return g < 0.46 and r > 0.70 and b > 0.70 and ((r + b) * 0.5 - g) > 0.42


def check(name):
    path = existing(name)
    if not path or not path.endswith(".png"):
        return "%-18s missing/non-png" % name
    w, h, bpp, px = read_png(path)
    # sample a 1-pixel border ring, every 4th pixel
    ring = []
    for x in range(0, w, 4):
        ring.append((x, 0)); ring.append((x, h - 1))
    for y in range(0, h, 4):
        ring.append((0, y)); ring.append((w - 1, y))
    hit = 0
    sr = sg = sb = 0
    for x, y in ring:
        o = (y * w + x) * bpp
        r, g, b = px[o], px[o + 1], px[o + 2]
        sr += r; sg += g; sb += b
        hit += is_chroma(r, g, b)
    n = len(ring)
    avg = (sr // n, sg // n, sb // n)
    # whole-image chroma coverage (every 8th pixel)
    tot = cov = 0
    for y in range(0, h, 8):
        for x in range(0, w, 8):
            o = (y * w + x) * bpp
            tot += 1
            cov += is_chroma(px[o], px[o + 1], px[o + 2])
    return "%-18s %4dx%-4d edge-chroma %3d%%  avg-edge #%02X%02X%02X  chroma-area %3d%%" % (
        name, w, h, 100 * hit // n, avg[0], avg[1], avg[2], 100 * cov // max(1, tot))


def measure(name):
    """Per-cell content bounding boxes of a sprite strip (non-chroma pixels)."""
    path = existing(name)
    spec = ASSETS[name]
    if not path or not path.endswith(".png"):
        return "%-18s missing/non-png" % name
    w, h, bpp, px = read_png(path)
    cells = spec.get("cells", 1)
    cw = w // cells
    out = ["%-18s %dx%d  %d cell(s) of %dx%d" % (name, w, h, cells, cw, h)]
    for c in range(cells):
        x0 = y0 = 10 ** 9
        x1 = y1 = -1
        for y in range(0, h, 2):
            row = y * w
            for x in range(c * cw, (c + 1) * cw, 2):
                o = (row + x) * bpp
                if spec["sprite"] and is_chroma(px[o], px[o + 1], px[o + 2]):
                    continue
                if x < x0: x0 = x
                if x > x1: x1 = x
                if y < y0: y0 = y
                if y > y1: y1 = y
        if x1 < 0:
            out.append("  cell %d: empty" % c)
        else:
            out.append("  cell %d: content x%d..%d y%d..%d (local x%d..%d, %dx%d, centre %d,%d)" % (
                c, x0, x1, y0, y1, x0 - c * cw, x1 - c * cw, x1 - x0, y1 - y0,
                (x0 + x1) // 2 - c * cw, (y0 + y1) // 2))
    return "\n".join(out)


def write_png(path, w, h, bpp, px):
    """Minimal PNG writer (8-bit RGB/RGBA, filter 0)."""
    ctype = 2 if bpp == 3 else 6
    stride = w * bpp
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += px[y * stride:(y + 1) * stride]

    def chunk(t, b):
        c = struct.pack(">I", len(b)) + t + b
        return c + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    out += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)


def is_backdrop(r, g, b):
    """Loose 'pinkish magenta' test used to find backdrop pixels before
    normalising them to exact #FF00FF (the model drifts toward deep pink)."""
    return r > 150 and g < 120 and b > 90 and (r + b) - 2 * g > 200


def fix_chroma(path, mode="flood"):
    """Normalise the magenta backdrop to exact #FF00FF so the chroma shader
    (g<0.46, r>0.70, b>0.70) always keys it out.
    mode='flood'  : only backdrop connected to the image border (safe for
                    sprites with pink details inside)
    mode='global' : every pinkish pixel (bezel: screen hole is not connected)
    Returns the number of pixels changed."""
    w, h, bpp, px = read_png(path)
    px = bytearray(px)
    n = w * h
    mask = bytearray(n)
    for i in range(n):
        o = i * bpp
        if is_backdrop(px[o], px[o + 1], px[o + 2]):
            mask[i] = 1
    if mode == "flood":
        seen = bytearray(n)
        stack = []
        for x in range(w):
            stack.append(x); stack.append((h - 1) * w + x)
        for y in range(h):
            stack.append(y * w); stack.append(y * w + w - 1)
        while stack:
            i = stack.pop()
            if seen[i] or not mask[i]:
                continue
            seen[i] = 1
            x = i % w
            if x > 0: stack.append(i - 1)
            if x < w - 1: stack.append(i + 1)
            if i >= w: stack.append(i - w)
            if i + w < n: stack.append(i + w)
        mask = seen
    changed = 0
    for i in range(n):
        if mask[i]:
            o = i * bpp
            if px[o] != 255 or px[o + 1] != 0 or px[o + 2] != 255:
                px[o], px[o + 1], px[o + 2] = 255, 0, 255
                changed += 1
    if changed:
        write_png(path, w, h, bpp, bytes(px))
    return changed


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def api_key():
    k = os.environ.get("GROK_API_KEY") or os.environ.get("XAI_API_KEY")
    if not k:
        sys.exit("GROK_API_KEY / XAI_API_KEY not set")
    return k


def build_prompt(spec):
    parts = [STYLE, spec["prompt"]]
    return ", ".join(parts)


def post(body, key, timeout=240):
    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def fetch_image(spec, key, retries=5):
    """Return (bytes, mime). Tries models in order, retries on 429/5xx."""
    prompt = build_prompt(spec)
    last = None
    for model in MODELS:
        body = {
            "model": model,
            "prompt": prompt,
            "n": 1,
            "response_format": "b64_json",
        }
        if spec.get("aspect"):
            body["aspect_ratio"] = spec["aspect"]
        attempt = 0
        while attempt < retries:
            attempt += 1
            try:
                d = post(body, key)
                item = d["data"][0]
                if item.get("b64_json"):
                    raw = base64.b64decode(item["b64_json"])
                elif item.get("url"):
                    with urllib.request.urlopen(item["url"], timeout=120) as r:
                        raw = r.read()
                else:
                    raise RuntimeError("no b64_json or url in response")
                return raw, item.get("mime_type") or sniff(raw)
            except urllib.error.HTTPError as e:
                text = e.read().decode("utf-8", "replace")[:400]
                last = "%s HTTP %d: %s" % (model, e.code, text)
                if e.code == 400 and "aspect_ratio" in body and "aspect" in text:
                    log("  aspect_ratio rejected, retrying without it")
                    body.pop("aspect_ratio", None)
                    attempt -= 1
                    continue
                if e.code == 429 or e.code >= 500:
                    wait = min(60, 3 * 2 ** (attempt - 1))
                    log("  %s -> retry in %ds" % (last, wait))
                    time.sleep(wait)
                    continue
                if e.code in (400, 404) and "model" in text.lower():
                    log("  %s -> trying next model" % last)
                    break
                raise RuntimeError(last)
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                last = "%s: %s" % (model, e)
                wait = min(60, 3 * 2 ** (attempt - 1))
                log("  %s -> retry in %ds" % (last, wait))
                time.sleep(wait)
    raise RuntimeError("all models failed: %s" % last)


def sniff(raw):
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if raw[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    return "application/octet-stream"


def save(name, raw, mime):
    """Write love2d/assets/<name>.png (PNG), converting JPEG via sips if possible."""
    os.makedirs(OUT_DIR, exist_ok=True)
    png_path = os.path.join(OUT_DIR, name + ".png")
    jpg_path = os.path.join(OUT_DIR, name + ".jpg")
    if mime == "image/png":
        with open(png_path, "wb") as f:
            f.write(raw)
        _rm(jpg_path)
        return png_path
    # JPEG (or unknown): try sips (macOS, no deps) to make a real PNG
    if shutil.which("sips"):
        fd, tmp = tempfile.mkstemp(suffix=".jpg")
        os.close(fd)
        try:
            with open(tmp, "wb") as f:
                f.write(raw)
            r = subprocess.run(
                ["sips", "-s", "format", "png", tmp, "--out", png_path],
                capture_output=True,
            )
            if r.returncode == 0 and os.path.getsize(png_path) > 0:
                _rm(jpg_path)
                return png_path
            log("  sips failed: %s" % r.stderr.decode("utf-8", "replace")[:200])
        finally:
            _rm(tmp)
    with open(jpg_path, "wb") as f:
        f.write(raw)
    _rm(png_path)
    return jpg_path


def _rm(p):
    try:
        os.remove(p)
    except OSError:
        pass


def existing(name):
    for ext in (".png", ".jpg"):
        p = os.path.join(OUT_DIR, name + ext)
        if os.path.exists(p) and os.path.getsize(p) > 0:
            return p
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--only", action="append", help="asset name (repeatable)")
    ap.add_argument("--force", action="store_true", help="overwrite existing")
    ap.add_argument("--list", action="store_true", help="list assets and exit")
    ap.add_argument("--dry-run", action="store_true", help="print prompts only")
    ap.add_argument("--check", action="store_true", help="measure magenta backdrop of existing PNGs")
    ap.add_argument("--fix", action="store_true", help="normalise backdrop of existing sprite PNGs to #FF00FF")
    ap.add_argument("--measure", action="store_true", help="print per-cell content bbox of existing strips")
    ap.add_argument("--variants", type=int, default=0, metavar="N",
                    help="generate N candidates as <name>_v1..N instead of <name> (pick one and rename)")
    args = ap.parse_args()

    names = list(ASSETS)
    if args.only:
        bad = [n for n in args.only if n not in ASSETS]
        if bad:
            sys.exit("unknown asset(s): %s\nknown: %s" % (bad, ", ".join(ASSETS)))
        names = args.only

    if args.list:
        for n in ASSETS:
            print("%-18s %-5s %s" % (n, ASSETS[n]["aspect"], "sprite" if ASSETS[n]["sprite"] else "illustration"))
        return

    if args.fix:
        for n in names:
            p = existing(n)
            if p and p.endswith(".png") and ASSETS[n]["sprite"]:
                print("%-18s normalised %d px" % (n, fix_chroma(p, ASSETS[n].get("fix", "global"))))
        return

    if args.check or args.measure:
        for n in names:
            try:
                print(measure(n) if args.measure else check(n))
            except Exception as e:  # noqa: BLE001
                print("%-18s check failed: %s" % (n, e))
        return

    key = None if args.dry_run else api_key()
    ok, failed, skipped = [], [], []
    jobs = [(n, n) for n in names]
    if args.variants > 0:
        jobs = [(n, "%s_v%d" % (n, i + 1)) for n in names for i in range(args.variants)]
    for name, out_name in jobs:
        spec = ASSETS[name]
        have = existing(out_name)
        if have and not args.force and not args.dry_run:
            log("skip  %s (exists)" % os.path.relpath(have, ROOT))
            skipped.append(out_name)
            continue
        if args.dry_run:
            print("== %s [%s]\n%s\n" % (out_name, spec["aspect"], build_prompt(spec)))
            continue
        log("gen   %s ..." % out_name)
        try:
            raw, mime = fetch_image(spec, key)
            path = save(out_name, raw, mime)
            if spec["sprite"] and path.endswith(".png"):
                ch = fix_chroma(path, spec.get("fix", "global"))
                log("  chroma-normalised %d px" % ch)
            log("  ok  %s (%d KB, %s)" % (os.path.relpath(path, ROOT), os.path.getsize(path) // 1024, mime))
            ok.append(out_name)
        except Exception as e:  # noqa: BLE001
            log("  FAIL %s: %s" % (out_name, e))
            failed.append(out_name)

    if not args.dry_run:
        log("\ndone: %d generated, %d skipped, %d failed" % (len(ok), len(skipped), len(failed)))
        if failed:
            log("failed: " + ", ".join(failed))
            sys.exit(1)


if __name__ == "__main__":
    main()
