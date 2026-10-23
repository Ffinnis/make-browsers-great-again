"""The heavy workload: 3 profiles and 50 real sites (favorites, pinned tabs,
pinned folders and Today tabs in MBGA; one window per profile in Chromium).

heavy        Load every tab, measure memory, idle 12 minutes, measure again,
             quit and restore the session. MBGA runs with tab sleeping off so
             every tab stays loaded, as in Chromium.
heavy-sleep  MBGA with its default tab sleeping (MBGA only).
"""

import json
import os
import time

from browsers import MBGA
from common import WORK, log, measure_window, sample, sleep_until, summarize, wait_for_window

SETTLE = 90
IDLE_WINDOW = 120
IDLE_MARK = 12 * 60
if os.environ.get("BENCH_QUICK"):
    SETTLE, IDLE_WINDOW, IDLE_MARK = 15, 10, 60

W = "https://en.wikipedia.org/wiki/"
WORKLOAD = [
    {
        "profile": "Personal",
        "space": "Home",
        "icon": "🏠",
        "color": 0x8B5CF6,
        "favorites": [
            "https://www.youtube.com/",
            "https://x.com/",
            "https://www.spotify.com/",
            "https://www.netflix.com/",
        ],
        "folders": {
            "News": [
                "https://www.bbc.com/news",
                "https://www.bbc.com/sport",
                "https://arstechnica.com/",
                "https://techcrunch.com/",
            ]
        },
        "pinned": ["https://www.google.com/maps/search/coffee+near+san+francisco"],
        "today": [
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
            "https://www.amazon.com/",
            "https://www.amazon.com/s?k=mechanical+keyboard",
            "https://www.imdb.com/",
            "https://www.imdb.com/chart/top/",
            "https://www.twitch.tv/",
            "https://www.twitch.tv/directory",
            "https://maps.google.com/",
        ],
    },
    {
        "profile": "Work",
        "space": "Work",
        "icon": "💼",
        "color": 0x3B82F6,
        "favorites": ["https://github.com/", "https://linear.app/", "https://stripe.com/", "https://www.google.com/"],
        "folders": {
            "Repos": [
                "https://github.com/rust-lang/rust",
                "https://github.com/chromiumembedded/cef",
                "https://github.com/torvalds/linux",
                "https://github.com/apple/swift",
                "https://github.com/microsoft/vscode",
                "https://github.com/facebook/react",
            ]
        },
        "pinned": ["https://news.ycombinator.com/", "https://lobste.rs/"],
        "today": [
            "https://news.ycombinator.com/newest",
            "https://www.cloudflare.com/",
            "https://tailwindcss.com/",
            "https://nodejs.org/en",
            "https://www.google.com/search?q=chromium+embedded+framework",
        ],
    },
    {
        "profile": "Research",
        "space": "Research",
        "icon": "📚",
        "color": 0x10B981,
        "favorites": ["https://www.wikipedia.org/", "https://www.apple.com/", "https://www.microsoft.com/"],
        "folders": {
            "Wiki": [
                W + "Web_browser",
                W + "Chromium_(web_browser)",
                W + "Rust_(programming_language)",
                W + "Swift_(programming_language)",
                W + "MacOS",
            ]
        },
        "pinned": ["https://archive.org/"],
        "today": [
            W + "Linux",
            W + "Internet",
            W + "Arc_(web_browser)",
            W + "Apple_silicon",
            W + "WebKit",
            "https://www.producthunt.com/",
            "https://archive.org/details/texts",
        ],
    },
]


def urls(space):
    folder_tabs = [u for tabs in space["folders"].values() for u in tabs]
    return space["favorites"] + folder_tabs + space["pinned"] + space["today"]


ALL_URLS = [u for s in WORKLOAD for u in urls(s)]
assert len(ALL_URLS) == 50, len(ALL_URLS)


def run_chromium(browser):
    data = os.path.join(WORK, browser.key)
    browser.prepare(data, [s["profile"] for s in WORKLOAD])
    result = {}

    log(f"{browser.key}: launching 3 profiles with 50 tabs")
    t_launch = time.time()
    proc = browser.launch(data, urls(WORKLOAD[0]), profile=1)
    result["first_window_s"] = wait_for_window(proc.pid)
    time.sleep(2)
    for i in (2, 3):
        browser.open_in_running(data, urls(WORKLOAD[i - 1]), profile=i)
    t0 = time.time()
    log(f"{browser.key}: all tabs opened after {t0 - t_launch:.1f}s")

    sleep_until(t0, SETTLE)
    result["loaded"] = summarize(sample(proc.pid))
    log(f"{browser.key}: loaded {result['loaded']['total_mb']:.0f} MB")
    result["idle_loaded"] = measure_window(proc.pid, IDLE_WINDOW)
    sleep_until(t0, IDLE_MARK)
    result["after_idle"] = summarize(sample(proc.pid))
    log(f"{browser.key}: after idle {result['after_idle']['total_mb']:.0f} MB")
    result["idle_after"] = measure_window(proc.pid, IDLE_WINDOW)

    with open(os.path.join(data, "Local State")) as f:
        local_state = json.load(f)
    result["memory_saver_state"] = (
        local_state.get("performance_tuning", {}).get("high_efficiency_mode", {}).get("state")
    )

    log(f"{browser.key}: quitting")
    browser.quit(proc)
    time.sleep(3)

    def launch():
        return browser.launch(data, profile=1, extra=["--restore-last-session"])

    def open_other_profiles(proc):
        time.sleep(4)
        for i in (2, 3):
            browser.open_in_running(data, [], profile=i, extra=["--restore-last-session"])
            time.sleep(2)

    result["restore"] = restore(launch, browser.quit, open_other_profiles)
    return result


def loaded_titles(data):
    with open(os.path.join(data, "state.json")) as f:
        tabs = json.load(f)["tabs"].values()
    return sum(1 for t in tabs if t["title"])


def run_mbga(name="heavy", sleeping=False, idle=True, restore_test=True, idle_cpu=True, late_sample=0):
    data = os.path.join(WORK, f"mbga-{name}")
    policy = {"sleep_after_secs": 600, "max_live_tabs": 8} if sleeping else {}
    MBGA.prepare(data, WORKLOAD, **policy)
    result = {}
    log(f"mbga {name}: launching")
    proc = MBGA.launch(data)
    result["first_window_s"] = wait_for_window(proc.pid)
    time.sleep(3)
    log(f"mbga {name}: opening all 50 tabs")
    MBGA.select_every_tab([len(urls(s)) for s in WORKLOAD])
    t0 = time.time()

    sleep_until(t0, SETTLE)
    result["loaded"] = summarize(sample(proc.pid))
    result["tabs_with_title"] = loaded_titles(data)
    MBGA.check_profiles(data)
    log(
        f"mbga {name}: loaded {result['loaded']['total_mb']:.0f} MB, "
        f"{result['tabs_with_title']}/50 tabs reported a title"
    )
    if late_sample:
        sleep_until(t0, late_sample)
        result["late"] = summarize(sample(proc.pid))
    if idle_cpu:
        result["idle_loaded"] = measure_window(proc.pid, IDLE_WINDOW)
    if idle:
        sleep_until(t0, IDLE_MARK)
        result["after_idle"] = summarize(sample(proc.pid))
        log(f"mbga {name}: after idle {result['after_idle']['total_mb']:.0f} MB")
        result["idle_after"] = measure_window(proc.pid, IDLE_WINDOW)

    MBGA.quit(proc)
    time.sleep(3)
    if restore_test:
        result["restore"] = restore(lambda: MBGA.launch(data), MBGA.quit)
    return result


def restore(launch, quit, after_window=None):
    """Cold launch with the saved 50-tab session."""
    t = time.time()
    proc = launch()
    first = wait_for_window(proc.pid)
    if after_window:
        after_window(proc)
    out = {"first_window_s": first}
    for mark in (30, 90):
        sleep_until(t, mark)
        out[f"at_{mark}s"] = summarize(sample(proc.pid))
    log(f"restore: window {first}s, {out['at_90s']['total_mb']:.0f} MB at 90s")
    quit(proc)
    time.sleep(3)
    return out


def run(browser, scenario):
    if browser.key == "mbga":
        return run_mbga(scenario, sleeping=scenario == "heavy-sleep", restore_test=scenario == "heavy")
    if scenario == "heavy":
        return run_chromium(browser)
    return None
