#!/usr/bin/env python3
"""Run every test layer with isolated data directories and a machine-readable report."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

# Scripted walkthroughs, cheapest first. Adding a phase to love2d/src/shots*.lua
# without adding it here (or to UNWIRED in tools/check_consistency.py) is a CI
# failure: an unrun phase rots silently, which is how ten `App.sceneName ==
# "lobby"` assertions stayed dead for sixteen commits.
PHASES = [
    # phase           group          --mock
    ("display",       "display",     False),
    ("files",         "files",       False),
    ("folders",       "folders",     False),
    ("limit",         "limit",       False),
    ("commander",     "commander",   False),
    ("map",           "map",         False),
    ("portrait",      "portrait",    False),
    ("mock",          "mock",        True),
    ("polish",        "polish",      True),
    ("monitors",      "monitors",    True),
    ("maps",          "maps",        False),
    ("aichat",        "aichat",      False),
    ("assist",        "assist",      False),
    ("kitty",         "kitty",       False),
    ("notes",         "notes",       False),
    ("hotnote",       "hotnote",     False),
    # restart pairs: same group, so the second half sees the first half's state
    ("nav",           "nav",         False),
    ("nav2",          "nav",         False),
    ("restorewrite",  "restore",     False),
    ("restoreread",   "restore",     False),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cargo", default="cargo")
    parser.add_argument("--love", required=True)
    parser.add_argument("--luajit", required=True)
    parser.add_argument("--suite", choices=("all", "integration", "ui-integration"), default="all")
    args = parser.parse_args()
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}"
    report_dir = ROOT / "love2d" / "build" / "test-results" / stamp
    report_dir.mkdir(parents=True)
    stages = []
    cargo = [args.cargo, "test", "--manifest-path", "rust/Cargo.toml", "--release"]
    if args.suite == "all":
        stages.append(("rust-unit", cargo + ["--lib", "--", "--nocapture"], "rust-unit"))
        stages.append(("rust-doc", cargo + ["--doc", "--", "--nocapture"], "rust-doc"))
    if args.suite in ("all", "integration"):
        # Discover integration targets: adding a new Rust test file automatically includes it.
        for path in sorted((ROOT / "rust" / "tests").glob("*.rs")):
            stages.append((f"rust-{path.stem}", cargo + ["--test", path.stem, "--", "--nocapture"], path.stem))
        stages.append(("ffi", [args.luajit, "rust/examples/ffi_smoke.lua"], "ffi"))
    if args.suite == "all":
        stages.append(("love-unit", [args.love, "love2d", "--", "--test"], "love-unit"))
    if args.suite in ("all", "integration"):
        # Kitty graphics through the C ABI over real localhost SSH (tools/kitty_test.py).
        stages.append(("kitty", ["python3", "tools/kitty_test.py", "--selftest",
                                 "--lib", "rust/target/release/libcbo_core.dylib"], "kitty"))
    # (phase, group, needs_mock). The group is both the CBO_HOME directory and
    # CBO_QA_GROUP, which scopes the LOVE save-dir config.json (love2d/main.lua):
    # two phases in one group share persisted settings on purpose, and two
    # phases in different groups cannot leak into each other. A restart pair is
    # exactly that — the second half reads what the first one stored.
    for phase, group, mock in PHASES:
        command = [args.love, "love2d"]
        if mock:
            command.append("--mock")
        command.append(f"--shots={phase}")
        stages.append((f"love-{phase}", command, group))
    results = []
    print(f"Test reports: {report_dir}", flush=True)
    print("Local SSH integration is required. Provider tests run with available environment keys.", flush=True)
    with tempfile.TemporaryDirectory(prefix="cbo-test-all-") as temp:
        for name, command, group in stages:
            env = os.environ.copy()
            env.update(CBO_HOME=str(Path(temp) / group), CBO_IT="1", CBO_LIVE="1",
                       CBO_QA_GROUP=group)
            log_path = report_dir / f"{name}.log"
            started = time.monotonic()
            print(f"RUN  {name}", flush=True)
            try:
                with log_path.open("w", encoding="utf-8") as output:
                    result = subprocess.run(command, cwd=ROOT, env=env, stdout=output,
                                            stderr=subprocess.STDOUT, timeout=600, check=False)
                code = result.returncode
            except (OSError, subprocess.TimeoutExpired) as exc:
                with log_path.open("a", encoding="utf-8") as output:
                    output.write(f"\nRunner error: {exc}\n")
                code = 1
            text = log_path.read_text(encoding="utf-8", errors="replace")
            skipped = [line.strip() for line in text.splitlines() if "skipped:" in line.lower()]
            counts = re.findall(r"test result: ok\. (\d+) passed", text)
            ui = re.search(r"OK (\d+) tests", text)
            count = sum(map(int, counts)) + (int(ui[1]) if ui else 0)
            item = dict(stage=name, status="passed" if code == 0 else "failed", exit_code=code,
                        seconds=round(time.monotonic() - started, 2), reported_tests=count,
                        skips=skipped, log=str(log_path.relative_to(ROOT)))
            results.append(item)
            print(f"{'PASS' if code == 0 else 'FAIL'} {name} ({item['seconds']}s; {len(skipped)} skipped checks)", flush=True)
            for skip in skipped:
                print(f"  {skip}", flush=True)
            if code:
                print("\n".join(text.splitlines()[-30:]), flush=True)
            report = dict(suite=args.suite, results=results,
                          passed=all(r["exit_code"] == 0 for r in results),
                          complete=len(results) == len(stages))
            (report_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    failed = [r["stage"] for r in results if r["exit_code"]]
    print(f"{'FAILED: ' + ', '.join(failed) if failed else 'ALL TEST STAGES PASSED'}", flush=True)
    print(f"Report: {report_dir / 'report.json'}", flush=True)
    return int(bool(failed))


if __name__ == "__main__":
    raise SystemExit(main())
