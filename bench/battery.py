"""Battery scenarios on local test pages (bench/pages), identical for every
browser and every run:

battery-static      A plain article on screen.
battery-busy        An ad-heavy news page on screen: ticker, spinner, animated
                    banner, analytics timers, two cross-site ad frames (one
                    animated, one with a muted looping video).
battery-video       A 1080p VP9 video playing.
battery-background  Ten busy pages in background tabs with the plain article
                    on screen; measured early (0:30-2:30) and late (6:00-8:00,
                    after Chromium's 5-minute intensive timer throttling).
battery-pinned      The same with the ten pages as pinned tabs, which MBGA
                    keeps running (MBGA only; Chromium has no such
                    distinction, so compare with its battery-background).
"""

import os
import time

from browsers import MBGA
from common import (
    DEVTOOLS_PORT,
    WORK,
    DevTools,
    activate,
    log,
    measure_window,
    page_targets,
    page_url,
    sleep_until,
    wait_for_window,
    window_bounds,
)

WINDOW = 120
SETTLE = 30
if os.environ.get("BENCH_QUICK"):
    WINDOW, SETTLE = 10, 5

BACKGROUND_TABS = 10


def pages(scenario):
    """(background pages, page on screen)."""
    if scenario in ("battery-background", "battery-pinned"):
        return [page_url(f"busy.html?tab={i}") for i in range(BACKGROUND_TABS)], page_url("static.html")
    return [], page_url(scenario.split("-", 1)[1] + ".html")


ATTEMPTS = 3


def run(browser, scenario):
    """Runs the scenario, again if its page was not on screen the whole time
    (someone using the machine can cover the window)."""
    if scenario == "battery-pinned" and browser.key != "mbga":
        return None
    for attempt in range(1, ATTEMPTS + 1):
        result = run_once(browser, scenario)
        result["attempts"] = attempt
        if result["check"]["ok"]:
            break
        log(f"{browser.key} {scenario}: not valid, " + ("retrying" if attempt < ATTEMPTS else "giving up"))
    return result


def hidden_ms(pid, front):
    devtools = DevTools(DEVTOOLS_PORT, pid, match=front)
    try:
        return devtools.evaluate("window.__hiddenMs ? window.__hiddenMs() : null")
    finally:
        devtools.close()


def run_once(browser, scenario):
    background, front = pages(scenario)
    data = os.path.join(WORK, f"{browser.key}-{scenario}")
    is_mbga = browser.key == "mbga"
    if is_mbga:
        tabs = (
            {"pinned": background, "today": [front]}
            if scenario == "battery-pinned"
            else {"today": [*background, front]}
        )
        MBGA.prepare(data, [{"space": "Bench", **tabs}])
        proc = MBGA.launch(data, devtools=True)
    else:
        browser.prepare(data)
        proc = browser.launch(data, [front, *background], devtools=True)
    result = {"first_window_s": wait_for_window(proc.pid)}
    time.sleep(2)
    if is_mbga and background:
        MBGA.select_every_tab([len(background) + 1])
    activate(proc.pid)
    t0 = time.time()
    result["window"] = window_bounds(proc.pid)
    log(f"{browser.key} {scenario}: settling")

    sleep_until(t0, SETTLE)
    hidden_before = hidden_ms(proc.pid, front)
    if background:
        result["early"] = measure_window(proc.pid, WINDOW)
        sleep_until(t0, 6 * 60 if WINDOW >= 60 else 60)
        result["late"] = measure_window(proc.pid, WINDOW)
        summary = f"early {result['early']['power_mw']:.0f} mW, late {result['late']['power_mw']:.0f} mW"
    else:
        result["idle"] = measure_window(proc.pid, WINDOW)
        summary = (
            f"{result['idle']['power_mw']:.0f} mW, {result['idle']['cpu_percent']:.1f}% CPU, "
            f"{result['idle']['gpu_percent']:.1f}% GPU, "
            f"impact {result['idle']['energy_impact']:.1f}"
        )
    result["check"] = check(proc.pid, scenario, front, hidden_before)
    log(f"{browser.key} {scenario}: {summary}; check {result['check']}")
    browser.quit(proc)
    time.sleep(3)
    return result


CHECKS = {
    "battery-static": "true",
    "battery-busy": "new Promise(r => { let n = 0; const f = () => ++n < 30 ? "
    "requestAnimationFrame(f) : r(true); requestAnimationFrame(f); "
    "setTimeout(() => r(n), 2000); })",
    "battery-video": "new Promise(r => { const v = document.querySelector('video'); "
    "const t = v.currentTime; setTimeout(() => r(!v.paused && v.currentTime != t), 500); })",
    "battery-background": "true",
    "battery-pinned": "true",
}


def check(pid, scenario, front, hidden_before):
    """The page on screen stayed visible through the measurement and is doing
    its thing, and (for the background scenarios) every background page is
    still loaded."""
    devtools = DevTools(DEVTOOLS_PORT, pid, match=front)
    try:
        hidden_during = devtools.evaluate("window.__hiddenMs()") - hidden_before
        works = devtools.evaluate(CHECKS[scenario], await_promise=True) is True
    finally:
        devtools.close()
    visible = hidden_during < 1000
    out = {"front_visible": visible, "hidden_during_ms": round(hidden_during), "works": works}
    if scenario in ("battery-background", "battery-pinned"):
        out["background_pages"] = sum(1 for t in page_targets(DEVTOOLS_PORT) if "busy.html" in t["url"])
    out["ok"] = visible and works and out.get("background_pages", BACKGROUND_TABS) == BACKGROUND_TABS
    if not out["ok"]:
        log(f"WARNING: {scenario} page check failed, the measurement is not valid: {out}")
    return out
