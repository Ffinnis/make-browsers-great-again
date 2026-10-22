#!/usr/bin/env python3
"""A/B of engine switches on one scenario, without rebuilding MBGA.

Each trial runs MBGA with extra engine switches (merged with the built-in
defaults in shell/engine/MBEngine.mm); a token "-name" instead drops the
built-in default switch or feature of that name. Repeat and interleave names
(`a b a b`) to see past run-to-run noise.

  --scenario heavy        memory 90 s after loading the 50 tabs (default)
  --scenario battery-*    Energy Impact, CPU power and GPU of a battery scenario
  --scenario speedometer  Speedometer 3.1 score

Usage: bench/trials.py [--scenario NAME] [trial ...]
Results: bench/results/trials-<timestamp>.json
"""

import argparse
import json
import os
import time

import battery
import heavy
import speed
from browsers import MBGA
from common import HERE, WORK, build_tools, log

# BENCH_LATE=180 also samples memory 180 s after the last tab opened.
LATE = int(os.environ.get("BENCH_LATE", "0"))

TRIALS = {
    "defaults": "",
    "strict-isolation": "--site-per-process",
    # Power: candidates found in the engine's feature list.
    "60hz": "--enable-features=ThrottleMainFrameTo60Hz",
    "unimportant-frames": "--enable-features=ThrottleUnimportantFrameTimers,ThrottleUnimportantFrameRate",
    "unimportant-frames-250ms": (
        "--enable-features=ThrottleUnimportantFrameTimers:"
        "unimportant_frame_timers_throttled_wake_up_interval_millis/250,"
        "ThrottleUnimportantFrameRate"
    ),
    "align-wakeups": "--enable-features=AlignWakeUps",
    "timer-slack": "--enable-features=TimerSlackMac",
    "no-damage-frames": "--enable-features=ThrottleRepeatedNoDamageFrames",
    "video-frame-rate": "--enable-features=OnBeginFrameThrottleVideo,SingleVideoFrameRateThrottling",
    "background-gc": (
        "--enable-features=V8SingleThreadedGCInBackground,"
        "RestrictThreadPoolInBackground,IsolatesPriorityBestEffortWhenHidden"
    ),
    "intensive-throttling-60s": "--enable-features=IntensiveWakeUpThrottling:grace_period_seconds/60",
    "invisible-svg": "--enable-features=InvisibleSVGAnimationThrottling",
    # Speed: what the memory defaults cost.
    "no-optimize-for-size": "-js-flags",
    "low-end-mode": "--enable-low-end-device-mode",
}


def run_trial(scenario):
    if scenario == "heavy":
        r = heavy.run_mbga("trial", idle=False, restore_test=False, idle_cpu=False, late_sample=LATE)
        return {
            "total_mb": r["loaded"]["total_mb"],
            "late_mb": r.get("late", {}).get("total_mb"),
            "processes": r["loaded"]["processes"],
            "tabs_with_title": r["tabs_with_title"],
            "by_kind": r["loaded"]["by_kind"],
        }
    if scenario in ("speedometer", "startup"):
        return speed.run(MBGA, scenario)
    r = battery.run(MBGA, scenario)
    windows = {k: r[k] for k in ("idle", "early", "late") if k in r}
    return {
        k: {m: w[m] for m in ("energy_impact", "power_mw", "cpu_percent", "gpu_percent", "wakeups_per_s")}
        | {"by_kind": w["by_kind"]}
        for k, w in windows.items()
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", default="heavy")
    parser.add_argument("trials", nargs="*")
    args = parser.parse_args()
    names = args.trials or ([*list(TRIALS), "defaults"])
    build_tools()
    os.makedirs(WORK, exist_ok=True)
    results = []
    for name in names:
        tokens = TRIALS[name].split()
        os.environ["MBGA_ENGINE_SWITCHES"] = " ".join(t for t in tokens if t.startswith("--"))
        os.environ["MBGA_ENGINE_OMIT"] = " ".join(t[1:] for t in tokens if not t.startswith("--"))
        r = run_trial(args.scenario)
        results.append({"trial": name, "scenario": args.scenario, "switches": TRIALS[name], **r})
        log(f"trial {name}: {json.dumps({k: v for k, v in r.items() if k != 'by_kind'}, default=str)[:300]}")
    out = os.path.join(HERE, "results", time.strftime("trials-%Y%m%d-%H%M%S.json"))
    with open(out, "w") as f:
        json.dump(results, f, indent=2)

    if args.scenario == "heavy":
        base = [r["total_mb"] for r in results if r["trial"] == "defaults"]
        ref = sum(base) / len(base) if base else results[0]["total_mb"]
        print(f"\n{'trial':26} {'MB':>7} {'vs base':>8} {'procs':>6}")
        for r in results:
            print(f"{r['trial']:26} {r['total_mb']:7.0f} {r['total_mb'] / ref - 1:+8.1%} {r['processes']:6}")
    elif args.scenario == "speedometer":
        for r in results:
            print(f"{r['trial']:26} {r['score']:7.1f} {r['confidence']}")
    elif args.scenario == "startup":
        for r in results:
            print(f"{r['trial']:26} {r['first_window_s']:6.2f}s {r['memory_mb']:6.0f} MB")
    else:
        print(f"\n{'trial':26} {'window':7} {'impact':>7} {'mW':>7} {'CPU %':>7} {'GPU %':>7} {'wake/s':>7}")
        for r in results:
            for w in ("idle", "early", "late"):
                if w in r:
                    m = r[w]
                    print(
                        f"{r['trial']:26} {w:7} {m['energy_impact']:7.1f} {m['power_mw']:7.1f} "
                        f"{m['cpu_percent']:7.2f} {m['gpu_percent']:7.2f} {m['wakeups_per_s']:7.1f}"
                    )
    print(f"\nresults: {out}")


if __name__ == "__main__":
    main()
