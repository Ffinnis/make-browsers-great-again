# Benchmarks

MBGA against plain Chromium 154, the version its engine (CEF) is built on,
on memory, battery and speed. Every browser runs alone from a throwaway data
directory under `/tmp`, so your own browsing data is never touched, and is
measured over its whole process tree.

`bench/results/trend.html` charts every benchmarked change against Chromium.
Each run is saved as `bench/results/<timestamp>.json` with the commit it
measured, and the chart is regenerated after every run. Results stay on the
machine that ran them; they aren't committed.

## Scenarios

| Scenario | What happens | Measured |
|---|---|---|
| `heavy` | 3 profiles, 50 real sites (favorites, pinned tabs and folders, Today tabs in MBGA; a window per profile in Chromium). Every tab loaded, 12 idle minutes, quit, restore. MBGA runs with tab sleeping off so every tab stays loaded. | Memory loaded and after 12 min, idle CPU, power and Energy Impact, restore time and memory |
| `heavy-sleep` | The same with MBGA's default tab sleeping (MBGA only). | Memory |
| `battery-static` | A plain article on screen. | Energy Impact, CPU power, GPU, wakeups |
| `battery-busy` | An ad-heavy news page on screen: ticker, spinner, animated banner, analytics timers, two cross-site ad frames (one animated, one with a muted looping video). | same |
| `battery-video` | A 1080p VP9 video playing. | same |
| `battery-background` | Ten ad-heavy pages in background tabs, the article on screen; measured at 0:30–2:30 and 6:00–8:00. | same |
| `startup` | Cold launch showing the article, 3 times. | Time to window, memory at 10 s |
| `speedometer` | [Speedometer 3.1](https://browserbench.org/Speedometer3.1/), read through DevTools. | Score |

Battery pages are in `bench/pages` and served locally (the ad frames from
`localhost`, a different site than the page's `127.0.0.1`), so every run sees
identical content. After each battery run the harness checks through DevTools
that the page on screen is visible and working (the video plays, animations
run) and that the background pages are still loaded.

What the numbers mean:

- **Memory** is the physical footprint, what Activity Monitor reports as
  "Memory".
- **Energy Impact** is Activity Monitor's figure, read from `top`. It weighs
  CPU time, wakeups and GPU use, and is what macOS uses to flag apps that drain
  the battery.
- **CPU power** is the energy the processor spent on the browser
  (`proc_pid_rusage`), excluding the graphics chip.
- **GPU busy** is the share of time the graphics chip ran the browser's work
  (the driver's per-process counters, as Activity Monitor's GPU column).

Both browsers get the same web viewport (1004×804 CSS pixels on a 2× display):
Chromium's window is sized to match MBGA's default window minus its sidebar.

## Running

```sh
scripts/fetch-chromium.sh                 # once: Chromium 154 into third_party/chromium
scripts/build.sh                          # MBGA
bench/run.py                              # everything, ~1 h 45 min
bench/run.py battery --label "what changed"
bench/run.py speed --browsers chromium,chrome,mbga
```

Quit MBGA first; the harness drives it with keyboard shortcuts, so leave the
machine alone while it runs. `BENCH_QUICK=1` shortens every wait for a smoke
test of the mechanics.

`bench/trials.py` A/Bs engine switches on one scenario without rebuilding:

```sh
bench/trials.py --scenario battery-busy defaults 60hz defaults 60hz
bench/trials.py --scenario speedometer defaults no-optimize-for-size
```

A trial passes extra switches through `MBGA_ENGINE_SWITCHES` (feature lists
and `--js-flags` merge with the built-in ones) and drops built-in defaults
through `MBGA_ENGINE_OMIT`.

| File | Purpose |
|---|---|
| `run.py` | Runs scenarios, saves results, regenerates the chart. |
| `heavy.py`, `battery.py`, `speed.py` | The scenarios. |
| `browsers.py` | Driving Chromium/Chrome and MBGA. |
| `common.py` | Sampling, measurement windows, the page server, a minimal DevTools client. |
| `trend.py` | `trend.html` from every results file. |
| `trials.py` | A/B of engine switches. |
| `sample.swift`, `windows.swift`, `key.swift`, `activate.swift` | Process-tree sampling, window detection, key presses, bringing a browser to the front. |

Real sites change between runs, so `heavy` varies by about ±4%. The battery
scenarios use local pages and vary less, but other apps on the machine still
add noise to timings and Speedometer.

## Earlier results

Before the Chromium baseline, MBGA was measured against Google Chrome 155 on
the same 50-tab workload: 2,122 MB against
4,320 MB with every tab loaded, 900 MB with tab sleeping (the first defaults:
asleep after 10 minutes, 8 tabs loaded; now 2 hours and 24), and 0.4% against
18.4% idle CPU after 12 minutes.

### Memory options tried then

Effects are relative to the configuration at the time, averaged over repeated
runs. Early rounds ran before a bug was fixed that made every profile fall
back to shared in-memory storage, so treat those effects as indicative; the
final configuration was re-measured with real profiles.

Kept as defaults:

| Option | Effect |
|---|---|
| Shared renderer processes (`--disable-features=SitePerProcess`, `--renderer-process-limit=4`, sign-in origins isolated) | Largest single saving. Strict isolation measured +29% with real profiles. |
| Network service in the browser process (`NetworkServiceInProcess2`) | About −120 MB: one process less and its caches shared. |
| HTTP/3 off (`--disable-quic`) | About −3.5%. |
| Cached resources not pinned (`--disable-features=MemoryCacheStrongReference`) | About −4%; holds as tabs age. |
| Purge renderers when backgrounded or when a page freezes (`MemoryPurgeInBackground`, `MemoryPurgeOnFreeze`) | About −3% to −6%, larger over time. |
| Freezing hidden Today tabs (DevTools `Page.setWebLifecycleState`) | About −2.5% memory, stops background growth, cuts idle CPU. |
| Release off-screen tiles when idle (`ReclaimPrepaintTilesWhenIdle`, `ReclaimOldPrepaintTiles`) | About −2%. |
| V8 `--optimize-for-size`, no prerendering, no spare renderer | Individually within noise, together a few percent. |

Measured and rejected:

| Option | Why |
|---|---|
| Skia Ganesh instead of Graphite | +15–19% memory. |
| PartitionAlloc hardening off (BackupRefPtr and friends) | No measurable gain; kept for use-after-free protection. |
| PartitionAlloc anti-fragmentation options | No effect. |
| V8 `--memory-saver-mode` | No effect. |
| V8 `--max-semi-space-size=1` | Within noise, costs CPU on allocation-heavy pages. |
| Disabling Media Router, Translate, phishing detection, sync | No effect. |
| Low-end device mode | Within noise, and it tells every process the Mac has 512 MB of RAM: a renderer's JavaScript heap stops at ~270 MB, so heavy sites froze and crashed. |

A simulated critical memory-pressure signal freed only ~35 MB, all of it in
the network service: what remains is live page data (JavaScript heaps and
DOM), not caches. A Chromium memory-infra dump (taken with shared processes
and QUIC off, before the cache, tile and freeze changes) showed renderers
holding 627 MB in malloc partitions of which only 426 MB was live objects, a
347 MB Blink object heap, a 334 MB V8 heap and a 189 MB resource cache (128 MB
of it script source). That slack and cache is what the purge, freeze and
cache options above go after.
