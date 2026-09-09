#!/usr/bin/env python3
"""Kitty graphics protocol test tool for CAUSEWAYBAY OFFICE.

Run it *inside* a terminal session (the app, kitty, wezterm, ghostty...):

    python3 tools/kitty_test.py            # show a test picture (PNG, chunked)
    python3 tools/kitty_test.py --all      # PNG, raw RGB, zlib RGBA, put-by-id, z<0
    python3 tools/kitty_test.py --query    # does this terminal speak the protocol?
    python3 tools/kitty_test.py FILE.png   # show your own PNG

Or drive the core end to end through localhost SSH (no app needed):

    python3 tools/kitty_test.py --selftest [--lib rust/target/release/libcbo_core.dylib]

The self test opens an SSH session to localhost with the current user (agent or
~/.ssh/id_* key, like the app), runs this script remotely with --all, then
checks through the C ABI that the sequences were stripped from the text, that
the placements, image bytes and cursor are what the protocol says, and that
the query was answered. Stdlib only: no Pillow, no numpy.
"""
import argparse
import base64
import ctypes
import os
import random
import select
import struct
import sys
import termios
import time
import tty
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ESC = "\x1b"
# Image ids for this run. Fresh per process (like kitten icat) so running the
# tool again does not reuse the ids of pictures already on screen.
BASE_ID = random.randint(1, 2**24) * 16
CHUNK = 4096  # base64 bytes per APC chunk (multiple of 4, as the spec asks)

# --------------------------------------------------------------- test images

RUST = (0xB7, 0x41, 0x0E)
YELLOW = (0xE8, 0xC5, 0x47)
CYAN = (0x3F, 0xC1, 0xC9)
NIGHT = (0x0A, 0x0A, 0x1E)


def sprite(w=64, h=32, alpha=False):
    """A rust square with a yellow frame and a cyan diagonal, row-major bytes."""
    out = bytearray()
    for y in range(h):
        for x in range(w):
            if x < 2 or y < 2 or x >= w - 2 or y >= h - 2:
                c = YELLOW
            elif abs(x - y * 2) < 3:
                c = CYAN
            else:
                c = RUST
            out += bytes(c)
            if alpha:
                out.append(255)
    return bytes(out)


def png_encode(rgb, w, h):
    """Minimal PNG writer (8-bit RGB, no filter)."""
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def png_decode_rgb(data):
    """Decode the PNGs this tool writes (8-bit RGB, filter 0 rows). (w, h, rgb)."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a png"
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(data):
        n, = struct.unpack(">I", data[pos:pos + 4])
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            w, h = struct.unpack(">II", body[:8])
        elif tag == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    rows = [raw[y * (w * 3 + 1) + 1:(y + 1) * (w * 3 + 1)] for y in range(h)]
    assert all(raw[y * (w * 3 + 1)] == 0 for y in range(h)), "filtered rows not supported"
    return w, h, b"".join(rows)


# ---------------------------------------------------------------- protocol

def apc(ctrl, payload=b""):
    return f"{ESC}_G{ctrl};{payload.decode('ascii')}{ESC}\\" if payload else f"{ESC}_G{ctrl}{ESC}\\"


def transmit(data, ctrl, out=sys.stdout):
    """Send `data` with control keys `ctrl` (dict), chunked per the spec."""
    b64 = base64.b64encode(data)
    keys = ",".join(f"{k}={v}" for k, v in ctrl.items())
    first = True
    while b64:
        piece, b64 = b64[:CHUNK], b64[CHUNK:]
        more = 1 if b64 else 0
        head = f"{keys},m={more}" if first else f"m={more}"
        out.write(apc(head, piece))
        first = False
    out.flush()


def show_png(path_or_bytes, image_id=None, extra=None):
    image_id = BASE_ID + 1 if image_id is None else image_id
    data = path_or_bytes if isinstance(path_or_bytes, bytes) else open(path_or_bytes, "rb").read()
    # q=2: we do not read the terminal's answer, so it must not send one
    # (it would land in the shell's input, on every terminal).
    ctrl = {"a": "T", "f": 100, "i": image_id, "q": 2}
    ctrl.update(extra or {})
    transmit(data, ctrl)


def emit_all():
    """Every code path the core supports, each followed by a newline."""
    w, h = 64, 32
    rgb = sprite(w, h)
    sys.stdout.write("png:\n")
    show_png(png_encode(rgb, w, h), image_id=BASE_ID + 1)
    sys.stdout.write("\nrgb:\n")
    transmit(rgb, {"a": "T", "f": 24, "s": w, "v": h, "i": BASE_ID + 2, "q": 2})
    sys.stdout.write("\nrgba+zlib:\n")
    transmit(zlib.compress(sprite(w, h, alpha=True)), {"a": "T", "f": 32, "s": w, "v": h, "o": "z", "i": BASE_ID + 3, "q": 2})
    sys.stdout.write("\nput the png again as 4x2 cells, z=-1, cursor stays:\n")
    sys.stdout.write(apc(f"a=p,i={BASE_ID + 1},p=7,c=4,r=2,z=-1,C=1,q=2"))
    sys.stdout.write("over\n\n")
    sys.stdout.flush()


def read_reply(timeout=2.0):
    """Read one APC response from the tty (raw mode), '' on timeout."""
    fd = sys.stdin.fileno()
    if not os.isatty(fd):
        return ""
    old = termios.tcgetattr(fd)
    buf = b""
    try:
        tty.setraw(fd)
        deadline = time.time() + timeout
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                buf += os.read(fd, 4096)
                if buf.endswith(b"\x1b\\"):
                    break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    return buf.decode("latin-1")


def query():
    sys.stdout.write(apc("a=q,i=31,s=1,v=1,f=24,t=d", b"AAAA"))
    sys.stdout.flush()
    reply = read_reply()
    ok = "OK" in reply
    print("kitty graphics:", "supported" if ok else "no answer", repr(reply))
    if ok:
        sys.stdout.write(apc("a=q,i=32,s=1,v=1,f=24,t=f", base64.b64encode(b"/tmp/x")))
        sys.stdout.flush()
        print("file medium:", repr(read_reply()))
    return 0 if ok else 1


# ---------------------------------------------------------------- self test

class Placement(ctypes.Structure):
    _fields_ = [("image_key", ctypes.c_uint64), ("image_id", ctypes.c_uint32),
                ("placement_id", ctypes.c_uint32), ("col", ctypes.c_int32), ("row", ctypes.c_int32),
                ("cols", ctypes.c_uint16), ("rows", ctypes.c_uint16), ("z", ctypes.c_int32),
                ("src_x", ctypes.c_uint32), ("src_y", ctypes.c_uint32),
                ("src_w", ctypes.c_uint32), ("src_h", ctypes.c_uint32)]


class ImageInfo(ctypes.Structure):
    _fields_ = [("key", ctypes.c_uint64), ("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
                ("bytes", ctypes.c_uint32), ("format", ctypes.c_uint32),
                ("compressed", ctypes.c_uint32), ("_pad", ctypes.c_uint32)]


class Cell(ctypes.Structure):
    _fields_ = [("cp", ctypes.c_uint32), ("fg", ctypes.c_uint32), ("bg", ctypes.c_uint32),
                ("attr", ctypes.c_uint8), ("width", ctypes.c_uint8), ("_pad", ctypes.c_uint8 * 2)]


def load_core(path):
    lib = ctypes.CDLL(path)
    P = ctypes.POINTER
    sig = {
        "cbo_init": (None, []),
        "cbo_shutdown": (None, []),
        "cbo_version": (ctypes.c_char_p, []),
        "cbo_last_error": (ctypes.c_char_p, []),
        "cbo_session_open": (ctypes.c_int32, [ctypes.c_char_p, ctypes.c_uint16, ctypes.c_char_p,
                                              ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint16, ctypes.c_uint16]),
        "cbo_session_state": (ctypes.c_int32, [ctypes.c_int32]),
        "cbo_session_error": (ctypes.c_char_p, [ctypes.c_int32]),
        "cbo_session_write": (None, [ctypes.c_int32, ctypes.c_char_p, ctypes.c_uint32]),
        "cbo_session_close": (None, [ctypes.c_int32]),
        "cbo_session_free": (None, [ctypes.c_int32]),
        "cbo_term_snapshot": (ctypes.c_int32, [ctypes.c_int32, P(Cell), ctypes.c_int32]),
        "cbo_term_generation": (ctypes.c_uint64, [ctypes.c_int32]),
        "cbo_term_cursor": (None, [ctypes.c_int32, P(ctypes.c_uint16), P(ctypes.c_uint16), P(ctypes.c_uint8)]),
        "cbo_term_set_cell_px": (None, [ctypes.c_int32, ctypes.c_uint16, ctypes.c_uint16]),
        "cbo_term_placements": (ctypes.c_int32, [ctypes.c_int32, P(Placement), ctypes.c_int32]),
        "cbo_term_image_info": (ctypes.c_int32, [ctypes.c_int32, ctypes.c_uint64, P(ImageInfo)]),
        "cbo_term_image_data": (ctypes.c_int32, [ctypes.c_int32, ctypes.c_uint64, P(ctypes.c_uint8), ctypes.c_int32]),
    }
    for name, (res, args) in sig.items():
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = res, args
    return lib


def screen_text(lib, sid, cols, rows):
    cells = (Cell * (cols * rows))()
    n = lib.cbo_term_snapshot(sid, cells, cols * rows)
    lines = []
    for r in range(rows):
        line = "".join(chr(cells[r * cols + c].cp) if cells[r * cols + c].cp else " "
                       for c in range(cols) if cells[r * cols + c].width)
        lines.append(line.rstrip())
    return "\n".join(lines[:n // cols])


def placements(lib, sid):
    buf = (Placement * 64)()
    n = lib.cbo_term_placements(sid, buf, 64)
    return [buf[i] for i in range(n)]


def image(lib, sid, key):
    info = ImageInfo()
    if lib.cbo_term_image_info(sid, key, ctypes.byref(info)) != 0:
        return None, b""
    buf = (ctypes.c_uint8 * info.bytes)()
    n = lib.cbo_term_image_data(sid, key, buf, info.bytes)
    return info, bytes(buf[:n])


def wait_for(pred, timeout, what):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(0.05)
    raise SystemExit(f"timeout waiting for {what}")


def selftest(lib_path, host, user, port, cols=80, rows=24):
    lib = load_core(lib_path)
    lib.cbo_init()
    print(f"core v{lib.cbo_version().decode()} from {lib_path}")
    failures = []

    def check(name, cond, detail=""):
        print(("ok   " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))
        if not cond:
            failures.append(name)

    sid = lib.cbo_session_open(host.encode(), port, user.encode(), None, None, cols, rows)
    if sid < 0:
        raise SystemExit("open failed: " + lib.cbo_last_error().decode())
    lib.cbo_term_set_cell_px(sid, 8, 16)

    def connected():
        st = lib.cbo_session_state(sid)
        if st == 4:
            raise SystemExit("ssh error: " + lib.cbo_session_error(sid).decode())
        return st == 2

    wait_for(connected, 20, "ssh connect")
    wait_for(lambda: screen_text(lib, sid, cols, rows).strip(), 10, "a prompt")
    script = os.path.abspath(__file__)
    # The remote answers the query itself and prints what it got, so the
    # response path (core -> ssh channel -> remote tty) is tested too.
    # The marker is split in the command so its echo does not match early.
    cmd = f"stty -echo; PYTHONIOENCODING=utf-8 python3 {script} --all --query-inline; echo KITTY-DO''NE; stty echo\n"
    lib.cbo_session_write(sid, cmd.encode(), len(cmd))
    wait_for(lambda: "KITTY-DONE" in screen_text(lib, sid, cols, rows), 20, "remote script")
    text = screen_text(lib, sid, cols, rows)
    check("no escape sequence leaked into the grid", "_G" not in text and "AAAA" not in text, text)
    check("query answered on the remote side", "QUERY OK" in text, text)
    check("file medium refused", "FILE EBADF" in text, text)

    pl = placements(lib, sid)
    check("four placements visible", len(pl) == 4, str(len(pl)))
    base = min(p.image_id for p in pl) - 1 if pl else 0
    by_id = {p.image_id - base: p for p in pl}
    for iid in (1, 2, 3):
        p = by_id.get(iid)
        check(f"image {iid} placed 8x2 cells at col 0", p is not None and (p.cols, p.rows, p.col) == (8, 2, 0),
              p and f"{p.cols}x{p.rows}@{p.col}")
    rows_of = sorted(p.row for p in pl)
    check("placements stacked down the screen", rows_of == sorted(set(rows_of)) and rows_of[-1] > rows_of[0], str(rows_of))
    put = [p for p in pl if p.placement_id == 7]
    check("put-by-id placement 4x2 z=-1", len(put) == 1 and (put[0].cols, put[0].rows, put[0].z) == (4, 2, -1),
          put and f"{put[0].cols}x{put[0].rows} z{put[0].z}")
    check("z order: negative first", pl and pl[0].z <= pl[-1].z)
    if put:
        check("put-by-id shares image 1's key", put[0].image_key == by_id[1].image_key)

    expect = sprite(64, 32)
    p1 = by_id.get(1)
    if p1:
        info, data = image(lib, sid, p1.image_key)
        check("png info 64x32 f=100", info and (info.width, info.height, info.format, info.compressed) == (64, 32, 100, 0))
        w, h, rgb = png_decode_rgb(data)
        check("png pixels intact", (w, h) == (64, 32) and rgb == expect)
    p2 = by_id.get(2)
    if p2:
        info, data = image(lib, sid, p2.image_key)
        check("rgb info 64x32 f=24", info and (info.width, info.height, info.format, info.compressed) == (64, 32, 24, 0))
        check("rgb bytes intact", data == expect)
    p3 = by_id.get(3)
    if p3:
        info, data = image(lib, sid, p3.image_key)
        check("rgba zlib info f=32 o=z", info and (info.format, info.compressed) == (32, 1))
        check("rgba zlib bytes intact", zlib.decompress(data) == sprite(64, 32, alpha=True))

    # "over" was printed with C=1 right after the put: same line as the put's cursor
    if put:
        over_row = next((i for i, line in enumerate(text.split("\n")) if line.startswith("over")), None)
        check("C=1 left the cursor in place", over_row == put[0].row, f"over@{over_row} put@{put[0].row}")

    # a second run must not take the first run's pictures away
    cmd = f"PYTHONIOENCODING=utf-8 python3 {script}; echo SECOND-DO''NE\n"
    lib.cbo_session_write(sid, cmd.encode(), len(cmd))
    wait_for(lambda: "SECOND-DONE" in screen_text(lib, sid, cols, rows), 20, "second run")
    pl2 = placements(lib, sid)
    check("second run adds a picture and keeps the first four", len(pl2) == 5, str(len(pl2)))
    check("second run uses fresh image ids", len({p.image_id for p in pl2}) == 4, str(sorted(p.image_id for p in pl2)))

    # scroll it away and back
    for _ in range(rows):
        lib.cbo_session_write(sid, b"echo x\n", 7)
    wait_for(lambda: not placements(lib, sid), 10, "placements to scroll off")
    check("placements scroll off the top", not placements(lib, sid))
    lib.cbo_session_write(sid, b"clear\n", 6)
    time.sleep(0.5)
    lib.cbo_session_close(sid)
    time.sleep(0.3)
    lib.cbo_session_free(sid)
    lib.cbo_shutdown()
    print(("FAIL %d" % len(failures)) if failures else "OK kitty self test")
    return 1 if failures else 0


# ------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("png", nargs="?", help="PNG file to display")
    ap.add_argument("--all", action="store_true", help="emit every supported variant")
    ap.add_argument("--query", action="store_true", help="probe the terminal and print its answers")
    ap.add_argument("--query-inline", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--selftest", action="store_true", help="drive the core through localhost ssh")
    ap.add_argument("--lib", default=os.path.join(ROOT, "rust", "target", "release", "libcbo_core.dylib"))
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--user", default=os.environ.get("USER", ""))
    ap.add_argument("--port", type=int, default=22)
    a = ap.parse_args()
    if a.selftest:
        return selftest(a.lib, a.host, a.user, a.port)
    if a.query:
        return query()
    if a.all:
        emit_all()
    elif a.png:
        show_png(a.png)
        sys.stdout.write("\n")
    elif not a.query_inline:
        rgb = sprite(96, 48)
        show_png(png_encode(rgb, 96, 48))
        sys.stdout.write("\n")
    if a.query_inline:
        sys.stdout.write(apc("a=q,i=31,s=1,v=1,f=24,t=d", b"AAAA"))
        sys.stdout.flush()
        r = read_reply()
        sys.stdout.write("QUERY OK\n" if "OK" in r else f"QUERY NONE {r!r}\n")
        sys.stdout.write(apc("a=q,i=32,s=1,v=1,f=24,t=f", base64.b64encode(b"/tmp/x")))
        sys.stdout.flush()
        r = read_reply()
        sys.stdout.write("FILE EBADF\n" if "EBADF" in r else f"FILE {r!r}\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
