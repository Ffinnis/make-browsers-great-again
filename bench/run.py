#!/usr/bin/env python3
"""MBGA against plain Chromium (and optionally Google Chrome).

Every browser runs alone from a throwaway data directory under /tmp and is
measured over its whole process tree. Scenarios (see each module):

  heavy, heavy-sleep                    heavy.py    3 profiles, 50 real sites
  battery-static, battery-busy,         battery.py  local test pages
  battery-video, battery-background,
  battery-pinned
  startup, speedometer                  speed.py

Groups: heavy, battery, speed, all (the default).

Usage:
  bench/run.py [--label TEXT] [--browsers chromium,mbga] [scenario|group ...]

Each run writes bench/results/<timestamp>.json, labelled with the change it
measures (the current commit's subject unless --label is given), and
regenerates bench/results/trend.html. --append FILE adds scenarios to an
earlier results file instead, for a scenario that run missed.
"""

import argparse
import json
import os
import shutil
import subprocess
import time

import battery
import heavy
import speed
import trend
from browsers import BROWSERS, MBGA
from common import DEVTOOLS_PORT, PAGE_PORT, ROOT, WORK, build_tools, listening_pid, log, machine

GROUPS = {
    "heavy": ["heavy", "heavy-sleep"],
    "battery": ["battery-static", "battery-busy", "battery-video", "battery-background", "battery-pinned"],
    "speed": ["startup", "speedometer"],
}
GROUPS["all"] = GROUPS["heavy"] + GROUPS["battery"] + GROUPS["speed"]
MODULES = {
    **dict.fromkeys(GROUPS["heavy"], heavy),
    **dict.fromkeys(GROUPS["battery"], battery),
    **dict.fromkeys(GROUPS["speed"], speed),
}
MBGA_ONLY = {"heavy-sleep", "battery-pinned"}


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True, check=False).stdout.strip()


def preflight(browsers):
    running = subprocess.run(["pgrep", "-f", MBGA.binary], capture_output=True, text=True, check=False).stdout
    if running.strip():
        raise SystemExit("MBGA is already running; quit it first")
    for port in (PAGE_PORT, DEVTOOLS_PORT):
        if listening_pid(port):
            raise SystemExit(f"port {port} is in use")
    for b in browsers:
        if not b.available():
            raise SystemExit(
                f"{b.key} not found ({getattr(b, 'binary', '')}); see scripts/fetch-chromium.sh and scripts/build.sh"
            )
    if MBGA in browsers:
        built = os.path.getmtime(MBGA.binary)
        sources = [
            os.path.join(d, f)
            for top in ("shell", "core/src")
            for d, _, files in os.walk(os.path.join(ROOT, top))
            for f in files
        ]
        stale = [s for s in sources if os.path.getmtime(s) > built]
        if stale:
            raise SystemExit(f"MBGA.app is older than {os.path.relpath(stale[0], ROOT)}; run scripts/build.sh")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("scenarios", nargs="*", default=["all"])
    parser.add_argument("--browsers", default="chromium,mbga")
    parser.add_argument("--label", help="what changed (default: the commit subject)")
    parser.add_argument(
        "--append", metavar="FILE", help="add these scenarios to an earlier results file of the same build"
    )
    args = parser.parse_args()

    scenarios = []
    for s in args.scenarios:
        for name in GROUPS.get(s, [s]):
            if name not in MODULES:
                raise SystemExit(f"unknown scenario {name}")
            if name not in scenarios:
                scenarios.append(name)
    browsers = [BROWSERS[b] for b in args.browsers.split(",")]
    preflight(browsers)
    build_tools()
    os.makedirs(WORK, exist_ok=True)

    dirty = bool(git("status", "--porcelain", "--", "shell", "core", "CMakeLists.txt"))
    results = {
        "format": 2,
        "date": time.strftime("%Y-%m-%d %H:%M"),
        "commit": git("rev-parse", "--short", "HEAD"),
        "subject": git("log", "-1", "--format=%s"),
        "dirty": dirty,
        "label": args.label or git("log", "-1", "--format=%s"),
        "machine": machine(),
        "engine_switches": os.environ.get("MBGA_ENGINE_SWITCHES", ""),
        "engine_omit": os.environ.get("MBGA_ENGINE_OMIT", ""),
        "versions": {b.key: b.version() for b in browsers},
        "results": {b.key: {} for b in browsers},
    }
    out_dir = os.path.join(ROOT, "bench", "results")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, time.strftime("%Y%m%d-%H%M%S") + ".json")
    if args.append:
        path = os.path.abspath(args.append)
        with open(path) as f:
            earlier = json.load(f)
        for key, versions in results["versions"].items():
            earlier["versions"].setdefault(key, versions)
            earlier["results"].setdefault(key, {})
        results = earlier
    log(f"{results['label']} ({results['commit']}{', uncommitted changes' if dirty else ''})")

    for scenario in scenarios:
        for b in browsers:
            if scenario in MBGA_ONLY and b is not MBGA:
                continue
            r = MODULES[scenario].run(b, scenario)
            if r is not None:
                results["results"][b.key][scenario] = r
                with open(path, "w") as f:
                    json.dump(results, f, indent=2)
    log(f"results written to {path}")
    with open(os.path.join(out_dir, "trend.html"), "w") as f:
        f.write(trend.render(trend.load_runs()))
    shutil.rmtree(WORK, ignore_errors=True)


if __name__ == "__main__":
    main()
