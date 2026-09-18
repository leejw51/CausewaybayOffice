#!/usr/bin/env python3
"""Cross-file consistency checks that need no window server, so CI can run them.

The in-engine suite and the scripted walkthroughs both need a display and a
local sshd, which a GitHub runner has neither of. What a runner *can* do is
read the sources and check that the places which have to agree still do. Every
rule here exists because it silently stopped being true at some point:

  lobby-scene       ten `App.sceneName == "lobby"` assertions stayed dead for
                    sixteen commits after the lobby became Map 1 / 2 / 3
  phase-wired       `commander` and `monitors` shipped with the Map 3 feature
                    and were never added to the runner, so they never ran
  phase-exists      the runner naming a phase that shots.lua does not define
  phase-mock        a phase that asserts the mock core, wired without --mock
  session-name      the `4.1 auto name` check could not match any real name
  lobby-help        Help listed "MAP 1 / MAP 2" after Map 3 shipped
  lobby-chords      Map 3 silently dropped Ctrl+R / Cmd+Q
  lobby-only-api    phases called Lobby:closeSelected/shelfY/columns on whatever
                    scene the lobby had become, and crashed
  store-not-file    checks read config.json / hosts.json, which the real core
                    stopped writing, so one failed and one passed vacuously

Failures print `file:line: message` so a red CI is actionable without a laptop.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / "love2d" / "src"
SHOTS = [GAME / "shots.lua", GAME / "shots_p3.lua"]

# Phases that exist on purpose without being part of `make test`, and why. A
# phase not listed here and not in run_tests.py's PHASES fails the check: the
# point is that skipping one is a decision somebody wrote down, not an
# oversight.
UNWIRED = {
    "art": "README/manual art capture; no checks, needs a human to look",
    "perf": "fps sampling under load; timings are machine-specific",
    "monitors100": "the 100-screen variant of `monitors`, for art only",
    "codeagent": "make test-codeagent; spends API credit and needs manual ALLOW",
    "codeagentgo": "the Go variant of `codeagent`; same cost and approval",
    # Their drift is fixed and they pass on a quiet machine, but not reliably:
    # `at()` schedules on fixed delays, and a step that presses a key 1.4 s after
    # a 1.2 s lobby <-> terminal camera transition loses the race under load
    # (App.switch refuses and App.textinput drops input while one runs). `qa`
    # also depends on real SSH round-trip timing for the bell, the OSC title and
    # scrollback. Wiring a flaky phase into `make check` is worse than not
    # wiring it; they need a condition-based wait first.
    "qa": "timing-fragile against real SSH; needs a wait-for-condition scheduler",
    "verify": "restart partner of `qa`; cannot run without it",
    "map3": "timing-fragile: races the 1.2 s lobby <-> terminal transition",
    "map3verify": "restart partner of `map3`; reads the platforms.txt it writes",
    "display3": "timing-fragile: same transition race after the overlay sweep",
}

failures = []


def fail(path, line, message):
    rel = Path(path).relative_to(ROOT) if Path(path).is_absolute() else path
    failures.append(f"{rel}:{line}: {message}")


def read(path):
    return Path(path).read_text(encoding="utf-8")


def lines(path):
    return read(path).splitlines()


def find_line(path, needle, start=0):
    for i, text in enumerate(lines(path)[start:], start=start + 1):
        if needle in text:
            return i
    return 1


# --------------------------------------------------------------- lobby-scene

def check_lobby_scene():
    """`App.sceneName` is never "lobby": App.switch rewrites it to the layout."""
    pattern = re.compile(r'sceneName\s*==\s*"lobby"')
    for path in sorted(GAME.rglob("*.lua")):
        for i, text in enumerate(lines(path), start=1):
            if pattern.search(text):
                fail(path, i, 'App.sceneName is never "lobby" (App.switch maps it to '
                              "map/map2/map3) — use App.isLobby(App.sceneName)")


# ---------------------------------------------------------------- phase-*

def phase_blocks():
    """{phase: (file, first line, block text)} for every `phase == "x"` branch."""
    blocks = {}
    for path in SHOTS:
        text = lines(path)
        marks = [(i, name)
                 for i, line in enumerate(text)
                 for name in re.findall(r'phase == "([a-z0-9]+)"', line)]
        for idx, (i, name) in enumerate(marks):
            # `if phase == "a" or phase == "b" then` puts two marks on one line:
            # the block runs to the next branch, not to the twin beside it.
            end = next((j for j, _ in marks[idx + 1:] if j > i), len(text))
            body = "\n".join(text[i:end])
            # a branch that delegates carries the other module's rules too
            for other in re.findall(r'require\("src\.(shots_\w+)"\)', body):
                helper = GAME / f"{other}.lua"
                if helper.exists():
                    body += "\n" + read(helper)
            if name in blocks:  # `phase == "a" or phase == "b"` on one line
                blocks[name] = (blocks[name][0], blocks[name][1], blocks[name][2] + body)
            else:
                blocks[name] = (path, i + 1, body)
    return blocks


def runner_phases():
    """[(phase, group, mock)] as tools/run_tests.py declares them."""
    text = read(ROOT / "tools" / "run_tests.py")
    body = text.split("PHASES = [", 1)[1].split("\n]", 1)[0]
    found = []
    for m in re.finditer(r'\(\s*"([a-z0-9]+)"\s*,\s*"([a-z0-9]+)"\s*,\s*(True|False)\s*\)', body):
        found.append((m.group(1), m.group(2), m.group(3) == "True"))
    return found


def check_phases(blocks, wired):
    runner = ROOT / "tools" / "run_tests.py"
    names = {p for p, _, _ in wired}

    for name, (path, line, _) in sorted(blocks.items()):
        if name not in names and name not in UNWIRED:
            fail(path, line, f'--shots={name} is not in run_tests.py PHASES and not in '
                             f"UNWIRED in {Path(__file__).name}: an unrun phase rots")
        if name in names and name in UNWIRED:
            fail(path, line, f"--shots={name} is both wired into the runner and listed "
                             "as UNWIRED; remove one")

    for name, _, mock in wired:
        if name not in blocks:
            fail(runner, find_line(runner, f'"{name}"'),
                 f'run_tests.py runs --shots={name}, which no shots file defines')
            continue
        path, line, body = blocks[name]
        # `assert(App.core.mock, ...)` / `App.core.mock == true` means the phase
        # only works against the mock core, so the runner has to pass --mock.
        needs_mock = re.search(r"assert\(\s*App\.core\.mock|App\.core\.mock == true", body)
        if needs_mock and not mock:
            fail(path, line, f'--shots={name} asserts the mock core, so its PHASES row '
                             "in run_tests.py needs --mock (True)")

    for name, reason in UNWIRED.items():
        if name not in blocks:
            fail(Path(__file__), find_line(Path(__file__), f'"{name}":'),
                 f"UNWIRED lists --shots={name}, which no shots file defines "
                 f"({reason})")


# ------------------------------------------------------------- lobby-only-api

def check_lobby_only_api():
    """No walkthrough may drive the active lobby through a retired scene's API.

    `scenes/lobby.lua` still defines a scene's worth of methods, but it is not a
    scene any more. Calling one of them on `App.scene` is a crash the moment the
    phase runs, which is how `closeSelected`, `shelfY` and `columns` survived.
    """
    def methods(path):
        return set(re.findall(r"^function \w+[:.](\w+)\(", read(path), re.M))

    lobby = GAME / "scenes" / "lobby.lua"
    if not lobby.exists():
        return
    live = set()
    for view in lobby_views():
        path = GAME / "scenes" / f"{view}.lua"
        if path.exists():
            live |= methods(path)
    retired = methods(lobby) - live
    if not retired:
        return
    for path in sorted(GAME.glob("shots*.lua")) + sorted(GAME.glob("test*.lua")):
        for i, text in enumerate(lines(path), start=1):
            for m in re.finditer(r"App\.scene[:.](\w+)", text):
                if m.group(1) in retired:
                    fail(path, i, f"App.scene:{m.group(1)}() exists only on the retired "
                                  "scenes/lobby.lua; the active lobby is Map 1 / 2 / 3")


# ------------------------------------------------------------- store-not-file

def check_store_not_file():
    """Settings and favorites live in SQLite; only the mock core writes the files.

    Reading them directly returns "" against the real core, so a "holds X"
    assertion fails and — worse — a "no longer holds X" assertion passes for
    the wrong reason. Only config.lua and sessions.lua may name their own file.
    """
    owners = {"config.lua": read(GAME / "config.lua"), "sessions.lua": read(GAME / "sessions.lua")}
    files = []
    for m in re.finditer(r'^[CS]\.FILE = "([^"]+)"', owners["config.lua"] + owners["sessions.lua"],
                         re.M):
        files.append(m.group(1))
    if not files:
        return
    for path in sorted(GAME.rglob("*.lua")):
        if path.name in owners:
            continue
        for i, text in enumerate(lines(path), start=1):
            for name in files:
                if f'love.filesystem.read("{name}")' in text:
                    fail(path, i, f'reads "{name}" directly; under the real core that file is '
                                  "only a legacy import — ask the core's kv store instead")


# -------------------------------------------------------------- session-name

LUA_CLASS = {"%a": "[A-Za-z]", "%d": "[0-9]", "%w": "[A-Za-z0-9]", "%-": "-", "%.": r"\."}


def lua_pattern_to_regex(pattern):
    out, i = "", 0
    while i < len(pattern):
        two = pattern[i:i + 2]
        if two in LUA_CLASS:
            out += LUA_CLASS[two]
            i += 2
        else:
            out += pattern[i]
            i += 1
    return out


def check_session_name():
    """The name shots.lua asserts must be the name sessions.lua builds."""
    sessions = GAME / "sessions.lua"
    text = read(sessions)
    names = re.search(r"local firstNames = \{(.*?)\}", text, re.S)
    build = re.search(r'name = firstNames\[[^\]]+\] \.\. "(.*?)" \.\. seq', text)
    if not names or not build:
        fail(sessions, find_line(sessions, "firstNames"),
             "cannot read the auto-name scheme; check_consistency needs updating")
        return
    sample = re.findall(r'"([a-z]+)"', names.group(1))[0] + build.group(1) + "1"
    for path in SHOTS:
        for i, line in enumerate(lines(path), start=1):
            m = re.search(r'firstName:match\("(.*?)"\)', line)
            if not m:
                continue
            if not re.match(lua_pattern_to_regex(m.group(1)), sample):
                fail(path, i, f'the auto-name check cannot match a real name '
                              f'({sample!r} from sessions.lua) — pattern {m.group(1)!r}')


# ---------------------------------------------------- lobby-help / -chords

def lobby_views():
    """The lobbyView values config.lua accepts, and the scene file for each."""
    text = read(GAME / "config.lua")
    accepted = set(re.findall(r'd\.lobbyView ~= "([a-z0-9]+)"', text))
    default = re.search(r'd\.lobbyView = "([a-z0-9]+)"', text)
    if default:
        accepted.add(default.group(1))
    return sorted(accepted)


def check_lobby_help():
    """Help has to name every layout the lobby can actually be."""
    help_path = GAME / "scenes" / "help.lua"
    text = read(help_path)
    for index, _ in enumerate(lobby_views(), start=1):
        if f"MAP {index}" not in text:
            fail(help_path, find_line(help_path, "MAP 1"),
                 f"config.lua accepts {len(lobby_views())} lobby layouts but Help "
                 f"never mentions MAP {index}")


def check_lobby_chords():
    """Every lobby layout answers the same app chords, or a key dies in one."""
    sets = {}
    for view in lobby_views():
        path = GAME / "scenes" / f"{view}.lua"
        if not path.exists():
            fail(GAME / "config.lua", find_line(GAME / "config.lua", "lobbyView"),
                 f'lobbyView accepts "{view}" but scenes/{view}.lua does not exist')
            continue
        sets[view] = set(re.findall(r'chord == "([a-zA-Z]+)"', read(path)))
    if len(sets) < 2:
        return
    union = set().union(*sets.values())
    for view, handled in sorted(sets.items()):
        missing = union - handled
        if missing:
            path = GAME / "scenes" / f"{view}.lua"
            fail(path, find_line(path, "appChord"),
                 f"lobby {view} ignores app chord(s) the other lobbies handle: "
                 + ", ".join(sorted(missing)))


def main():
    blocks = phase_blocks()
    check_lobby_scene()
    check_phases(blocks, runner_phases())
    check_lobby_only_api()
    check_store_not_file()
    check_session_name()
    check_lobby_help()
    check_lobby_chords()
    if failures:
        print("source consistency: %d problem(s)" % len(failures), file=sys.stderr)
        for line in failures:
            print("  " + line, file=sys.stderr)
        return 1
    print(f"  sources agree ({len(blocks)} shots phases, {len(lobby_views())} lobby layouts)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
