"""The browsers under test: Chromium-family apps driven from the command line,
and MBGA driven through its state file and keyboard shortcuts."""

import json
import os
import re
import shutil
import subprocess
import time
from typing import ClassVar

from common import DEVTOOLS_PORT, ROOT, TOOLS, wait_exit

KEY_TAB, KEY_Q = 48, 12
KEY_DIGITS = [18, 19, 20, 21, 23, 22, 26, 28, 25]


class Chromium:
    """Chromium or Google Chrome with a throwaway --user-data-dir."""

    FLAGS: ClassVar[list[str]] = [
        "--no-first-run",
        "--no-default-browser-check",
        "--use-mock-keychain",
        "--window-position=224,99",
    ]
    WINDOW = "--window-size=1004,891"
    ENV: ClassVar[dict[str, str]] = {
        "GOOGLE_API_KEY": "no",
        "GOOGLE_DEFAULT_CLIENT_ID": "no",
        "GOOGLE_DEFAULT_CLIENT_SECRET": "no",
    }

    def __init__(self, key, app):
        self.key = key
        self.app = app
        name = os.path.splitext(os.path.basename(app))[0]
        self.binary = os.path.join(app, "Contents", "MacOS", name)

    def available(self):
        return os.path.exists(self.binary)

    def version(self):
        return subprocess.run(
            ["defaults", "read", os.path.join(self.app, "Contents", "Info.plist"), "CFBundleShortVersionString"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()

    def prepare(self, data, profile_names=("Personal",)):
        shutil.rmtree(data, ignore_errors=True)
        for i, name in enumerate(profile_names, 1):
            prefs_dir = os.path.join(data, f"Profile {i}")
            os.makedirs(prefs_dir)
            with open(os.path.join(prefs_dir, "Preferences"), "w") as f:
                json.dump({"session": {"restore_on_startup": 1}, "profile": {"name": name}}, f)

    def command(self, data, profile=1, extra=()):
        return [
            self.binary,
            f"--user-data-dir={data}",
            *self.FLAGS,
            self.WINDOW,
            f"--profile-directory=Profile {profile}",
            *extra,
        ]

    def launch(self, data, urls=(), profile=1, extra=(), devtools=False):
        if devtools:
            extra = [*extra, f"--remote-debugging-port={DEVTOOLS_PORT}"]
        return subprocess.Popen(
            self.command(data, profile, extra) + list(urls),
            env={**os.environ, **self.ENV},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def open_in_running(self, data, urls, profile, extra=()):
        """Hands URLs to the running instance (which opens a window for the
        profile) and returns once the helper invocation exits."""
        subprocess.run(
            self.command(data, profile, extra) + list(urls),
            env={**os.environ, **self.ENV},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )

    def quit(self, proc):
        proc.terminate()
        wait_exit(proc)


class Mbga:
    key = "mbga"
    app = os.path.join(ROOT, "build", "cmake", "out", "MBGA.app")
    binary = os.path.join(app, "Contents", "MacOS", "MBGA")

    def available(self):
        return os.path.exists(self.binary)

    def version(self):
        with open(os.path.join(ROOT, "third_party", "cef", "dist", "include", "cef_version.h")) as f:
            return re.search(r'#define CEF_VERSION "([^"]+)"', f.read()).group(1)

    @staticmethod
    def state(spaces, sleep_after_secs=10**8, max_live_tabs=1000, **policy):
        """An MBGA state file. Each space: profile, space, icon, color, and
        favorites / folders / pinned / today URL lists; the first tab in
        sidebar order is the active one."""
        next_id = 1

        def alloc():
            nonlocal next_id
            next_id += 1
            return next_id - 1

        state = {
            "version": 1,
            "profiles": [],
            "favorites": {},
            "spaces": [],
            "tabs": {},
            "policy": {"sleep_after_secs": sleep_after_secs, "max_live_tabs": max_live_tabs, **policy},
            "search_template": "https://www.google.com/search?q=%s",
            "doomed_profiles": [],
        }

        def tab(url, pinned):
            tid = alloc()
            state["tabs"][str(tid)] = {
                "id": tid,
                "url": url,
                "title": "",
                "favicon": None,
                "pinned_url": url if pinned else None,
                "last_active_ms": 0,
            }
            return tid

        profiles = {}
        for space in spaces:
            name = space.get("profile", "Personal")
            if name not in profiles:
                profiles[name] = alloc()
                state["profiles"].append({"id": profiles[name], "name": name})
                state["favorites"][str(profiles[name])] = []
            pid = profiles[name]
            favs = [tab(u, True) for u in space.get("favorites", [])]
            state["favorites"][str(pid)] += favs
            pinned = []
            for folder, urls in space.get("folders", {}).items():
                pinned.append(
                    {
                        "kind": "folder",
                        "id": alloc(),
                        "name": folder,
                        "expanded": True,
                        "children": [{"kind": "tab", "id": tab(u, True)} for u in urls],
                    }
                )
            pinned += [{"kind": "tab", "id": tab(u, True)} for u in space.get("pinned", [])]
            today = [tab(u, False) for u in space.get("today", [])]
            first = (favs + [c["id"] for n in pinned for c in n.get("children", [n])] + today)[0]
            sid = alloc()
            state["spaces"].append(
                {
                    "id": sid,
                    "name": space.get("space", name),
                    "icon": space.get("icon", "🏠"),
                    "color": space.get("color", 0x8B5CF6),
                    "profile_id": pid,
                    "pinned": pinned,
                    "today": today,
                    "active_tab": first,
                }
            )
        state["active_space"] = state["spaces"][0]["id"]
        state["next_id"] = next_id
        return state

    def prepare(self, data, spaces, **policy):
        shutil.rmtree(data, ignore_errors=True)
        os.makedirs(data)
        with open(os.path.join(data, "state.json"), "w") as f:
            json.dump(self.state(spaces, **policy), f)

    def launch(self, data, devtools=False):
        switches = os.environ.get("MBGA_ENGINE_SWITCHES", "")
        if devtools:
            switches += f" --remote-debugging-port={DEVTOOLS_PORT}"
        env = {**os.environ, "MBGA_DATA_DIR": data, "MBGA_MOCK_KEYCHAIN": "1", "MBGA_ENGINE_SWITCHES": switches.strip()}
        return subprocess.Popen([self.binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def press(self, code, *mods):
        for _ in range(3):
            subprocess.run(["open", "-a", self.app], check=False)
            time.sleep(0.3)
            if subprocess.run([os.path.join(TOOLS, "key"), str(code), *mods], check=False).returncode == 0:
                return
        raise RuntimeError("could not bring MBGA to the front")

    def select_every_tab(self, tab_counts):
        """Selects every tab once (each selection loads it), space by space;
        tab_counts[i] is the number of tabs in space i."""
        for i, count in enumerate(tab_counts):
            self.press(KEY_DIGITS[i], "ctrl")
            time.sleep(1.0)
            for _ in range(count - 1):
                self.press(KEY_TAB, "ctrl")
                time.sleep(0.4)

    def quit(self, proc):
        self.press(KEY_Q, "cmd")
        wait_exit(proc)

    @staticmethod
    def check_profiles(data):
        """Profiles that fail to open fall back to shared in-memory storage,
        which would make any measurement meaningless."""
        log_path = os.path.join(data, "engine", "engine.log")
        errors = 0
        if os.path.exists(log_path):
            with open(log_path) as f:
                errors = f.read().count("Cannot create profile")
        if errors:
            raise RuntimeError(f"{errors} profiles failed to open; see {log_path}")


CHROMIUM = Chromium("chromium", os.path.join(ROOT, "third_party", "chromium", "chrome-mac", "Chromium.app"))
CHROME = Chromium("chrome", "/Applications/Google Chrome.app")
MBGA = Mbga()
BROWSERS = {b.key: b for b in (CHROMIUM, CHROME, MBGA)}
