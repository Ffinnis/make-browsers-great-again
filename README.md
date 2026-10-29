<p align="center">
  <img src="assets/icon.svg" width="96" height="96" alt="MBGA icon">
</p>
<h1 align="center">make-browsers-great-again</h1>
<p align="center">A macOS browser with Arc's sidebar, built to use as little memory as possible.</p>
<p align="center">
  <a href="https://github.com/Ffinnis/make-browsers-great-again/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Ffinnis/make-browsers-great-again?style=flat-square" /></a>
  <a href="https://github.com/Ffinnis/make-browsers-great-again/actions/workflows/check.yml"><img alt="Check status" src="https://img.shields.io/github/actions/workflow/status/Ffinnis/make-browsers-great-again/check.yml?style=flat-square&branch=main&label=check" /></a>
  <img alt="macOS 15+ on Apple silicon" src="https://img.shields.io/badge/macOS-15%2B%20%C2%B7%20Apple%20silicon-black?style=flat-square" />
</p>

---

MBGA renders pages with Chromium (through the Chromium Embedded Framework),
keeps all browser state in a Rust core, and draws its window with plain
AppKit. With 50 real sites open it uses about a fifth of Chrome's memory.

### Installation

MBGA runs on macOS 15 or later on Apple silicon. Paste into Terminal:

```sh
curl -fL https://github.com/Ffinnis/make-browsers-great-again/releases/latest/download/MBGA.zip -o /tmp/MBGA.zip && ditto -x -k /tmp/MBGA.zip /Applications && open /Applications/MBGA.app
```

Or download `MBGA.dmg` from the [latest release](https://github.com/Ffinnis/make-browsers-great-again/releases/latest),
open it and drag MBGA to Applications.

Releases are signed with a Developer ID and notarized by Apple. Once
installed, MBGA keeps itself up to date: it downloads new versions in the
background and offers to restart into them, with your windows, spaces and
tabs back where they were. Settings ▸ General turns this off.

### Features

- **Spaces and profiles.** Swipe between spaces with two fingers or press
  Ctrl+1…9. Each space has a name, an emoji, a color that tints the window,
  and optionally its own profile with separate cookies and logins.
- **Favorites, pinned tabs and folders.** Favorites form the grid at the top,
  pinned tabs and nested folders are kept per space, and Today tabs sit below
  the divider. Drag tabs anywhere, including onto another space's icon.
- **Command bar** (⌘T / ⌘L). Open a URL or search, switch to a tab or space,
  run a command, or reopen a closed tab.
- **Layouts.** The full sidebar, a Compact rail of favicons, or Focus mode
  (⌘S), where the page fills the window.
- **Little windows and multiple windows.** Drag a tab onto the page to give it
  a small window of its own, or open another window on the same spaces (⌘N).
- **Ad and tracker blocking.** EasyList, EasyPrivacy and uBlock Origin's
  lists, matched by Brave's engine, plus cosmetic rules, scriptlets and your
  own filters.
- **H.264 video** on X, Reddit, Twitch and other sites the engine can't play
  natively, converted to VP9 in the page as it plays.
- **Chrome extensions** from the Chrome Web Store, with toolbar buttons,
  popups, menus and shortcuts. Manifest V3 only, so use uBlock Origin Lite.
- **Import** spaces, pinned tabs and favorites from Arc; bookmarks and tabs
  from Chrome, Brave, Edge, Helium, Vivaldi, Opera, Firefox, Zen and Safari.
- **Passwords** imported from other browsers or a CSV file, filled on sign-in
  pages and sealed per profile with a key in your keychain.
- **Undo** for closing a tab, Clear and deleting a folder (⌘Z or ⇧⌘T).

### Memory

Measured against Chrome 155 on 3 profiles and 50 real sites, with every tab
loaded (method and tools in [`bench/`](bench/README.md)):

|                                          |    Chrome | MBGA, sleeping off | MBGA, defaults |
| ---------------------------------------- | --------: | -----------------: | -------------: |
| Memory, all 50 tabs loaded               | 4,320 MB  |     2,122 MB (49%) |   900 MB (21%) |
| Memory after 12 idle minutes             | 4,302 MB  |     2,116 MB (49%) |   681 MB (16%) |
| Idle CPU after 12 minutes                |    18.4%  |               0.4% |           0.2% |
| Idle power after 12 minutes              |   202 mW  |               3 mW |         <1 mW  |
| Memory 90 s after restoring the session  | 1,659 MB  |             254 MB |              – |

"Sleeping off" keeps every tab loaded, so it compares the engines like for
like. With the defaults, idle tabs are also unloaded.

How MBGA gets there, roughly in order of impact:

- **Shared renderer processes.** Like Chrome on Android, sites share four
  renderer processes instead of one each. Sign-in pages and sites that ask
  for isolation (COOP headers) keep their own. **MBGA ▸ Strict Site
  Isolation** switches to desktop Chrome's one-process-per-site model for the
  strongest protection against Spectre-class attacks, at about 30% more
  memory.
- **Tabs sleep.** A background tab idle for 2 hours, or beyond 24 loaded
  tabs, is unloaded and reloads when selected. When MBGA as a whole uses more
  than 2.5 GB, the tabs used longest ago sleep until it's back under. Tabs an
  agent opened sleep 5 minutes after it stops using them. Tabs playing audio
  or using the camera, microphone or screen stay awake, and you can keep any
  tab or site awake from its menu. Settings ▸ General changes the limits.
- **Hidden tabs freeze.** A tab hidden for 5 minutes keeps its state but runs
  no JavaScript until shown again. Sites allowed to show notifications or use
  the camera or microphone keep running, so mail, chat and calls keep working.
- **Hidden renderers purge** their caches and return free memory.
- **A leaner engine.** The network service runs in the browser process,
  HTTP/3 is off, Blink and V8 run in low-memory mode, and there is no spare
  renderer, prerendering or optimization-hint fetching.
- **Lazy loading.** After a restart, spaces open with no tab selected.
  Pick a tab to load it; each space remembers your choice until you quit.

The costs: sites in the same process are less isolated from each other and
a heavy page can slow others in its process; heavy JavaScript runs somewhat
slower; frozen Today tabs don't update in the background.

Run `scripts/measure-memory.sh` while MBGA is open to see each process's
physical footprint, the figure Activity Monitor reports.

### How it's built

```
core/          Rust: spaces, profiles, tabs, favorites, folders, persistence,
               tab sleep policy, omnibox, ad blocking, imports, passwords.
               Exposed to Swift through UniFFI.
shell/engine/  Objective-C++ bridge to CEF: one client per tab, per-profile
               storage, popups, downloads, permissions, extensions.
shell/helper/  Entry point of Chromium's subprocesses (renderer, GPU, ...).
shell/app/     AppKit UI: sidebar, spaces, command bar, settings. No SwiftUI.
```

The core owns the data; the shell renders snapshots of it and forwards
engine events back. Nothing in the UI keeps browser state of its own.

### Not yet built

- Importing history, and open tabs from Firefox and Safari.
- Generated passwords and passkeys.
- Split view, Peek, Little Arc, Boosts, link routing to spaces, the archive
  view and multi-color gradient themes.
- Scriptlets newer than uBlock Origin 1.48, redirect resources (such rules
  just block), and sync.

### Contributing

If you'd like to help, read the [contributing guide](./CONTRIBUTING.md)
before opening a pull request. It covers building from source, the checks
every change must pass, and what makes a pull request easy to merge.
