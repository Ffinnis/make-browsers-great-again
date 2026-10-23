#!/usr/bin/env python3
"""Checks that only the tab on screen is a visible page: tabs behind it,
other spaces' tabs and pinned tabs must report document.hidden and draw no
frames, in every way a tab can be shown or put away. Runs MBGA from a
throwaway data directory and drives it through the mbga command on its own
socket, so it never touches your browsers or takes the keyboard.

Usage: bench/visibility.py [--app path/to/MBGA.app]   (default: the build)
"""

import os
import re
import shutil
import subprocess
import sys
import time

from browsers import MBGA
from common import DEVTOOLS_PORT, WORK, DevTools, log, page_targets, page_url, quit_app, wait_for_window

FAILURES = []


def launch(data, spaces, **env):
    MBGA.prepare(data, spaces)
    socket = os.path.join(data, "agent.sock")
    proc = subprocess.Popen(
        [MBGA.binary],
        env={
            **os.environ,
            "MBGA_DATA_DIR": data,
            "MBGA_MOCK_KEYCHAIN": "1",
            "MBGA_DEBUG_AGENT": "1",
            "MBGA_ENGINE_SWITCHES": f"--remote-debugging-port={DEVTOOLS_PORT}",
            **env,
        },
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    wait_for_window(proc.pid)
    time.sleep(6)
    return proc, socket


def mbga(socket, *args):
    out = subprocess.run(
        ["mbga", *args],
        env={**os.environ, "MBGA_SOCKET": socket},
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if out.returncode:
        raise RuntimeError(f"mbga {' '.join(args)}: {out.stdout}{out.stderr}")
    return out.stdout


def tab_ids(socket):
    """URL -> tN for every tab."""
    listing = mbga(socket, "tabs", "--all")
    return {url: tab for tab, url in re.findall(r"(t\d+) .*? — (\S+)$", listing, re.M)}


def pages(pid):
    """URL -> (hidden, frames drawn in half a second) for every loaded page."""
    out = {}
    for t in page_targets(DEVTOOLS_PORT):
        if not t["url"].startswith("http"):
            continue
        d = DevTools(DEVTOOLS_PORT, pid, match=t["url"])
        try:
            frames = d.evaluate(
                "new Promise(r => { let n = 0; const f = () => { n++; "
                "requestAnimationFrame(f) }; requestAnimationFrame(f); "
                "setTimeout(() => r(n), 500) })",
                await_promise=True,
            )
            out[t["url"]] = (d.evaluate("document.hidden"), frames)
        finally:
            d.close()
    return out


def expect(step, pid, visible, loaded):
    """Exactly `visible` (one URL or none) is visible and drawing; every
    other page in `loaded` is loaded, hidden and drawing nothing."""
    state = pages(pid)
    problems = []
    for url in loaded:
        if url not in state:
            problems.append(f"{url} not loaded")
            continue
        hidden, frames = state[url]
        if url == visible and (hidden or frames < 10):
            problems.append(f"{url} should be on screen: hidden={hidden}, {frames} frames")
        if url != visible and (not hidden or frames > 0):
            problems.append(f"{url} should be hidden: hidden={hidden}, {frames} frames")
    log(f"{'FAIL' if problems else 'ok  '} {step}" + "".join(f"\n       {p}" for p in problems))
    if problems:
        FAILURES.append(step)


def quit(step, proc):
    started = time.time()
    if quit_app(proc.pid, timeout=20):
        log(f"ok   {step} ({time.time() - started:.1f} s)")
    else:
        log(f"FAIL {step}: still running after 20 s")
        FAILURES.append(step)
        proc.kill()


def main():
    if sys.argv[1:2] == ["--app"]:
        MBGA.binary = os.path.join(sys.argv[2], "Contents", "MacOS", "MBGA")
    if subprocess.run(
        ["lsof", "-nP", f"-iTCP:{DEVTOOLS_PORT}", "-sTCP:LISTEN"], capture_output=True, check=False
    ).stdout:
        raise SystemExit(f"port {DEVTOOLS_PORT} is in use")
    data = os.path.join(WORK, "visibility")
    a, b = page_url("busy.html?a"), page_url("busy.html?b")
    pinned, other = page_url("busy.html?pinned"), page_url("busy.html?other")

    proc, socket = launch(
        data, [{"space": "One", "pinned": [pinned], "today": [a, b]}, {"space": "Two", "today": [other]}]
    )
    ids = tab_ids(socket)
    expect(
        "launch: the pinned tab on screen, the other space's tab warmed and hidden", proc.pid, pinned, [pinned, other]
    )
    mbga(socket, "focus", ids[a])
    expect("another tab in the space", proc.pid, a, [pinned, other, a])
    mbga(socket, "focus", ids[b])
    expect("and another", proc.pid, b, [pinned, other, a, b])
    mbga(socket, "focus", ids[other])
    time.sleep(1)
    expect("a tab in the other space", proc.pid, other, [pinned, other, a, b])
    mbga(socket, "focus", ids[a])
    time.sleep(1)
    expect("back to the first space", proc.pid, a, [pinned, other, a, b])
    shot = mbga(socket, "screenshot", "--tab", ids[b]).split(" (")[0].strip()
    ok = os.path.exists(shot) and os.path.getsize(shot) > 50_000
    log(
        f"{'ok  ' if ok else 'FAIL'} an agent's screenshot of a hidden tab "
        f"({os.path.getsize(shot) // 1024 if os.path.exists(shot) else 0} KB)"
    )
    if not ok:
        FAILURES.append("screenshot of a hidden tab")
    expect("after the screenshot, that tab is hidden again", proc.pid, a, [pinned, other, a, b])
    behind = page_url("busy.html?behind")
    mbga(socket, "open", behind)
    expect("a tab opened behind the one on screen", proc.pid, a, [pinned, other, a, b, behind])
    quit("quit with hidden tabs loaded", proc)

    proc, socket = launch(data, [{"space": "One", "today": [a, b]}], MBGA_DEBUG_LITTLE_WINDOW="1")
    expect("a tab popped out to a little window is on screen", proc.pid, a, [a])
    quit("quit with a little window open", proc)

    shutil.rmtree(data, ignore_errors=True)
    if FAILURES:
        sys.exit(f"{len(FAILURES)} failed")
    log("all passed")


if __name__ == "__main__":
    main()
