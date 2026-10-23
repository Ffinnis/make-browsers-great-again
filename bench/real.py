#!/usr/bin/env python3
"""MBGA against Arc on your own browsing data: your profiles, spaces,
favorites and tabs as they are. Each browser opens, selects every tab once as
you would going through them (so each loads), goes back to the tab you were
on, and is measured while nobody touches it.

  MBGA  runs from a copy of your data directory (in /tmp), driven by the
        mbga command on the copy's own socket: your MBGA and its data are
        never touched. Other builds can run on the same copy for a
        before/after (pass the app's path).
  Arc   has no way to run from a copy, so it runs on your data. Each
        space's favorites are selected with Cmd+1-8 and its sidebar tabs
        through AppleScript (allow the terminal to control Arc when macOS
        asks). Selecting tabs is all it does.

Per launch: tabs opened, memory and renderers right after, and two idle
windows (2:00-4:00 and 6:00-8:00 after) with CPU, power, GPU, wakeups and
Energy Impact. --as-launched skips opening the tabs and measures each
browser as it starts (0:40-2:40 and 2:40-4:40). A window counts only if the browser stayed in front and
nobody used the keyboard or mouse during it; the summary leaves out the rest.

Usage:
  bench/real.py [--rounds 1] [--browsers arc,mbga,/path/to/MBGA.app]

Arc, if open, is quit the normal way and reopened at the end; your MBGA
keeps running. The harness waits until you have left the machine alone for
30 s before each launch. About 10 minutes per launch.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import time

from browsers import MBGA
from common import (
    ROOT,
    TOOLS,
    WORK,
    activate,
    build_tools,
    log,
    machine,
    measure_window,
    quit_app,
    sample,
    sleep_until,
    summarize,
    wait_for_window,
)

QUICK = bool(os.environ.get("BENCH_QUICK"))
WINDOW = 20 if QUICK else 120
EARLY, LATE, END = (30, 60, 90) if QUICK else (120, 360, 480)
SELECT_PAUSE = 0.8
IDLE_BEFORE = 5 if QUICK else 30
MBGA_DATA = os.path.expanduser("~/Library/Application Support/MBGA")
ARC_APP = "/Applications/Arc.app"
ARC_BUNDLE = "company.thebrowser.Browser"
FAVORITE_KEYS = [18, 19, 20, 21, 23, 22, 26, 28]


def hid_idle_seconds():
    """How long since the last keyboard or mouse input."""
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem", "-d", "4"], capture_output=True, text=True, check=False).stdout
    m = re.search(r'"HIDIdleTime" = (\d+)', out)
    return int(m.group(1)) / 1e9 if m else 0.0


def wait_until_idle(seconds):
    waited = False
    while hid_idle_seconds() < seconds:
        if not waited:
            log(f"waiting until nobody has used the keyboard or mouse for {seconds} s")
            waited = True
        time.sleep(2)


def measure(pid, seconds):
    """measure_window, plus whether the window counts: the browser stayed in
    front and nobody touched the machine."""
    activate(pid)
    window = measure_window(pid, seconds)
    window["untouched"] = hid_idle_seconds() >= seconds
    window["valid"] = window["untouched"] and window["front_fraction"] >= 0.95
    if not window["valid"]:
        log(
            f"INVALID window: in front {window['front_fraction']:.0%}, "
            f"{'untouched' if window['untouched'] else 'keyboard or mouse used'}"
        )
    return window


def running(binary):
    out = subprocess.run(["pgrep", "-f", f"^{re.escape(binary)}$"], capture_output=True, text=True, check=False).stdout
    return [int(p) for p in out.split()]


class Arc:
    key = "arc"
    binary = os.path.join(ARC_APP, "Contents", "MacOS", "Arc")

    def version(self):
        return subprocess.run(
            ["defaults", "read", os.path.join(ARC_APP, "Contents", "Info.plist"), "CFBundleShortVersionString"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()

    def script(self, source, timeout=60):
        out = subprocess.run(
            ["osascript", "-e", f'tell application "Arc"\n{source}\nend tell'],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        if out.returncode:
            raise RuntimeError(f"arc: {out.stderr.strip()}")
        return out.stdout.strip()

    def launch(self):
        subprocess.run(["open", "-a", ARC_APP], check=True)
        deadline = time.time() + 60
        while True:
            pids = running(self.binary)
            if pids:
                try:
                    if int(self.script("count of tabs of front window", timeout=10)) > 0:
                        return pids[0]
                except (RuntimeError, ValueError, subprocess.TimeoutExpired):
                    pass
            if time.time() > deadline:
                raise RuntimeError("Arc did not show a window with tabs within 60 s")
            time.sleep(1)

    def open_all(self):
        """Space by space: the space's favorites with Cmd+1-8, as you would,
        then its sidebar tabs through AppleScript. Selecting tabs from the
        window's own list instead crashes Arc (an assertion in Arc): that
        list jumps between spaces and holds stale copies of favorites."""
        pid = running(self.binary)[0]
        here = self.script("""
            set i to 0
            repeat with s in spaces of front window
                set i to i + 1
                if id of s is id of active space of front window then return i
            end repeat
            return 1""")
        spaces = int(self.script("count of spaces of front window"))
        opened = 0
        for i in range(1, spaces + 1):
            self.script(f"tell space {i} of front window to focus")
            time.sleep(1.5)
            for code in FAVORITE_KEYS:
                activate(pid)
                subprocess.run([os.path.join(TOOLS, "key"), "--to", ARC_BUNDLE, str(code), "cmd"], check=True)
                time.sleep(SELECT_PAUSE)
            opened += int(
                self.script(
                    f"""
                set n to count of tabs of space {i} of front window
                repeat with j from 1 to n
                    tell tab j of space {i} of front window to select
                    delay {SELECT_PAUSE}
                end repeat
                return n""",
                    timeout=600,
                )
            )
        self.script(f"tell space {here} of front window to focus")
        return opened

    def quit(self, pid):
        if not quit_app(pid):
            raise RuntimeError("Arc did not quit within 60 s; quit it yourself")


class MbgaCopy:
    """An MBGA build on a copy of your data directory."""

    def __init__(self, key, app):
        self.key, self.app = key, app
        self.binary = os.path.join(app, "Contents", "MacOS", "MBGA")
        self.data = os.path.join(WORK, "real-mbga")
        self.socket = os.path.join(self.data, "agent.sock")
        self.proc = None

    def version(self):
        if os.path.abspath(self.app) == MBGA.app:
            return subprocess.run(
                ["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=False
            ).stdout.strip()
        return self.app

    def launch(self):
        shutil.rmtree(self.data, ignore_errors=True)
        subprocess.run(
            ["rsync", "-a", "--exclude", "Singleton*", "--exclude", "agent.sock", MBGA_DATA + "/", self.data + "/"],
            check=True,
        )
        self.proc = subprocess.Popen(
            [self.binary],
            env={**os.environ, "MBGA_DATA_DIR": self.data, "MBGA_DEBUG_AGENT": "1"},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return self.proc.pid

    def mbga(self, *args):
        out = subprocess.run(
            ["mbga", *args],
            env={**os.environ, "MBGA_SOCKET": self.socket},
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if out.returncode:
            raise RuntimeError(f"mbga {' '.join(args)}: {out.stdout}{out.stderr}".strip())
        return out.stdout

    def open_all(self):
        deadline = time.time() + 30
        while True:
            try:
                listing = self.mbga("tabs", "--all")
                break
            except RuntimeError:
                if time.time() > deadline:
                    raise
                time.sleep(1)
        tabs = re.findall(r"^\s*([*>]\s*)?(t\d+) ", listing, re.M)
        if not tabs:
            raise RuntimeError(f"mbga listed no tabs: {listing.strip()[:200]}")
        for _, tab in tabs:
            self.mbga("focus", tab)
            time.sleep(SELECT_PAUSE)
        for mark, tab in tabs:
            if "*" in mark:
                self.mbga("focus", tab)
        return len(tabs)

    def quit(self, pid):
        if not quit_app(pid):
            self.proc.kill()
            raise RuntimeError("MBGA (the copy) did not quit within 60 s")
        shutil.rmtree(self.data, ignore_errors=True)


def run_once(browser, open_all=True):
    wait_until_idle(IDLE_BEFORE)
    log(f"{browser.key}: launching")
    pid = browser.launch()
    result = {"first_window_s": wait_for_window(pid, timeout=60)}
    activate(pid)
    time.sleep(5)
    started = time.time()
    result["tabs_opened"] = browser.open_all() if open_all else 0
    result["open_all_s"] = round(time.time() - started, 1)
    t0 = time.time()
    result["memory_loaded"] = summarize(sample(pid))
    r = result["memory_loaded"]["by_kind"].get("renderer", {"count": 0, "mb": 0})
    log(
        f"{browser.key}: opened {result['tabs_opened']} tabs in {result['open_all_s']:.0f} s; "
        f"{result['memory_loaded']['total_mb']:.0f} MB, {r['count']} renderers ({r['mb']:.0f} MB)"
    )
    sleep_until(t0, EARLY)
    result["early"] = measure(pid, WINDOW)
    sleep_until(t0, LATE)
    result["late"] = measure(pid, WINDOW)
    sleep_until(t0, END)
    result["memory_end"] = summarize(sample(pid))
    early, late = result["early"], result["late"]
    log(
        f"{browser.key}: {result['memory_end']['total_mb']:.0f} MB at {clock(END)}; "
        f"idle {early['cpu_percent']:.1f}% / {late['cpu_percent']:.1f}% CPU, "
        f"{early['power_mw']:.0f} / {late['power_mw']:.0f} mW, "
        f"impact {early['energy_impact']:.1f} / {late['energy_impact']:.1f}"
    )
    browser.quit(pid)
    time.sleep(5)
    return result


def clock(seconds):
    return f"{seconds // 60}:{seconds % 60:02d}"


def print_summary(results):

    def span(start):
        return f"idle {clock(start)}-{clock(start + WINDOW)}"

    head = ["browser", "tabs", "MB loaded", f"MB at {clock(END)}", span(EARLY), span(LATE)]
    rows = []
    for key, runs in results.items():
        for i, r in enumerate(runs, 1):
            rows.append(
                [
                    f"{key} #{i}",
                    str(r["tabs_opened"]),
                    f"{r['memory_loaded']['total_mb']:.0f}",
                    f"{r['memory_end']['total_mb']:.0f}",
                ]
                + [
                    f"{w['cpu_percent']:.1f}% CPU, {w['power_mw']:.0f} mW" if w["valid"] else "invalid"
                    for w in (r["early"], r["late"])
                ]
            )
    widths = [max(len(x) for x in col) for col in zip(head, *rows, strict=True)]
    for row in [head, *rows]:
        print("  ".join(c.ljust(w) for c, w in zip(row, widths, strict=True)))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--browsers", default="arc,mbga")
    parser.add_argument(
        "--as-launched",
        action="store_true",
        help="measure each browser as it starts, without opening any tab (windows at 0:40-2:40 and 2:40-4:40)",
    )
    args = parser.parse_args()
    if args.as_launched and not QUICK:
        global EARLY, LATE, END
        EARLY, LATE, END = 40, 160, 280

    browsers = []
    for k in args.browsers.split(","):
        if k == "arc":
            browsers.append(Arc())
        elif k == "mbga":
            browsers.append(MbgaCopy("mbga", MBGA.app))
        else:
            browsers.append(MbgaCopy(os.path.basename(os.path.dirname(os.path.abspath(k))), k))
    arc_was_open = any(isinstance(b, Arc) for b in browsers) and running(Arc.binary)
    if arc_was_open:
        log("quitting Arc (it reopens at the end)")
        if not quit_app(running(Arc.binary)[0]):
            raise SystemExit("Arc did not quit")
    build_tools()
    os.makedirs(WORK, exist_ok=True)

    def git(*a):
        return subprocess.run(["git", "-C", ROOT, *a], capture_output=True, text=True, check=False).stdout.strip()

    results = {
        "format": 2,
        "kind": "real-profile-as-launched" if args.as_launched else "real-profile",
        "date": time.strftime("%Y-%m-%d %H:%M"),
        "commit": git("rev-parse", "--short", "HEAD"),
        "subject": git("log", "-1", "--format=%s"),
        "machine": machine(),
        "versions": {b.key: b.version() for b in browsers},
        "results": {b.key: [] for b in browsers},
    }
    path = os.path.join(ROOT, "bench", "results", "real-" + time.strftime("%Y%m%d-%H%M%S") + ".json")
    order = []
    for r in range(args.rounds):
        order += browsers if r % 2 == 0 else list(reversed(browsers))
    try:
        for browser in order:
            results["results"][browser.key].append(run_once(browser, open_all=not args.as_launched))
            with open(path, "w") as f:
                json.dump(results, f, indent=2)
    finally:
        if arc_was_open and not running(Arc.binary):
            subprocess.run(["open", "-a", ARC_APP], check=False)
    log(f"results written to {path}")
    print_summary(results["results"])


if __name__ == "__main__":
    main()
