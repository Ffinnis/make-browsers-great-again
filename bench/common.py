"""Shared benchmark plumbing: sampling a browser's process tree, idle
measurement windows, the local test-page server and a minimal DevTools
client."""

import base64
import contextlib
import functools
import http.server
import json
import os
import platform
import re
import socket
import struct
import subprocess
import threading
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HERE = os.path.join(ROOT, "bench")
TOOLS = os.path.join(ROOT, "build", "bench-tools")
MEDIA = os.path.join(ROOT, "build", "bench-media")
WORK = "/tmp/mbga-bench"
PAGE_PORT = 8765
DEVTOOLS_PORT = 9555


def machine():
    """The architecture and CPU, for telling result files apart."""
    cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True, check=False)
    return f"{platform.machine()} {cpu.stdout.strip()}"


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def build_tools():
    os.makedirs(TOOLS, exist_ok=True)
    for name in ["sample", "windows", "key", "activate", "frontwatch"]:
        out = os.path.join(TOOLS, name)
        src = os.path.join(HERE, f"{name}.swift")
        if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
            subprocess.run(["swiftc", "-O", src, "-o", out], check=True)


def sleep_until(t0, offset):
    remaining = t0 + offset - time.time()
    if remaining > 0:
        time.sleep(remaining)


def wait_exit(proc, timeout=30):
    try:
        proc.wait(timeout)
    except subprocess.TimeoutExpired:
        log("did not exit in time, killing")
        proc.kill()
        proc.wait()


def quit_app(pid, timeout=60):
    """Quits this process the way Cmd+Q does (a quit Apple event to it
    alone, so another copy of the same app keeps running). Returns whether
    it exited in time."""
    script = (
        f"ObjC.import('AppKit'); "
        f"var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier({pid}); "
        f"app.isNil() ? false : app.terminate"
    )
    subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, timeout=30, check=False)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                return True
        except ChildProcessError:
            pass
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.2)
    return False


def wait_for_window(pid, timeout=30):
    start = time.time()
    while time.time() - start < timeout:
        out = subprocess.run(
            [os.path.join(TOOLS, "windows"), str(pid)], capture_output=True, text=True, check=False
        ).stdout.strip()
        if out and int(out) > 0:
            return time.time() - start
        time.sleep(0.05)
    return None


def activate(pid):
    """Brings the browser to the front, as when a user switches to it."""
    subprocess.run([os.path.join(TOOLS, "activate"), str(pid)], check=False)


def window_bounds(pid):
    out = subprocess.run(
        [os.path.join(TOOLS, "windows"), str(pid), "--bounds"], capture_output=True, text=True, check=False
    ).stdout
    return json.loads(out or "[]")


def sample(pid):
    """Footprint, CPU time, energy and wakeups of every process in the tree."""
    out = subprocess.run([os.path.join(TOOLS, "sample"), str(pid)], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def tree_pids(pid):
    return {p["pid"] for p in sample(pid)["procs"]}


def kind_of(proc):
    return proc["type"].split(":")[0]


def summarize(s):
    """Memory by process kind, in MB."""
    kinds = {}
    for p in s["procs"]:
        k = kinds.setdefault(kind_of(p), {"count": 0, "mb": 0.0})
        k["count"] += 1
        k["mb"] += p["footprint"] / 2**20
    return {"total_mb": s["footprint"] / 2**20, "processes": s["count"], "by_kind": kinds}


def gpu_times():
    """Accumulated GPU time per process in ns, as Activity Monitor's GPU
    column reads it from the graphics driver's user clients."""
    out = subprocess.run(
        ["ioreg", "-l", "-w0", "-r", "-c", "AGXDeviceUserClient"], capture_output=True, text=True, check=False
    ).stdout
    times = {}
    for block in out.split("+-o AGXDeviceUserClient")[1:]:
        m = re.search(r'"IOUserClientCreator" = "pid (\d+)', block)
        if m:
            pid = int(m.group(1))
            ns = sum(int(t) for t in re.findall(r'"accumulatedGPUTime"=(\d+)', block))
            times[pid] = times.get(pid, 0) + ns
    return times


class EnergyImpact:
    """Activity Monitor's "Energy Impact" per process, from `top`, averaged
    over a window that starts when this object is created."""

    def __init__(self, seconds):
        self.proc = subprocess.Popen(
            ["top", "-l", "2", "-s", str(int(seconds)), "-stats", "pid,power"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )

    def result(self):
        out, _ = self.proc.communicate(timeout=60)
        last = out.split("PID")[-1].splitlines()[1:]
        impact = {}
        for line in last:
            parts = line.split()
            if len(parts) >= 2 and parts[0].isdigit():
                with contextlib.suppress(ValueError):
                    impact[int(parts[0])] = float(parts[1])
        return impact


def measure_window(pid, seconds):
    """CPU (% of one core), CPU energy, wakeups, GPU busy time and Energy
    Impact of the whole tree while nobody touches it, overall and by
    process kind."""
    a, ga = sample(pid), gpu_times()
    top = EnergyImpact(seconds)
    front = subprocess.Popen(
        [os.path.join(TOOLS, "frontwatch"), str(pid), str(seconds - 1)], stdout=subprocess.PIPE, text=True
    )
    time.sleep(seconds)
    b, gb = sample(pid), gpu_times()
    impact = top.result()
    front_fraction = float(front.communicate(timeout=30)[0] or 0)
    elapsed = b["t"] - a["t"]
    before = {p["pid"]: p for p in a["procs"]}
    zero = {"cpu_ns": 0, "energy_nj": 0, "wakeups": 0}
    total = {"cpu_percent": 0.0, "power_mw": 0.0, "wakeups_per_s": 0.0, "gpu_percent": 0.0, "energy_impact": 0.0}
    kinds = {}
    for p in b["procs"]:
        q = before.get(p["pid"], zero)
        row = {
            "cpu_percent": (p["cpu_ns"] - q["cpu_ns"]) / (elapsed * 1e9) * 100,
            "power_mw": (p["energy_nj"] - q["energy_nj"]) / elapsed / 1e6,
            "wakeups_per_s": (p.get("wakeups", 0) - q.get("wakeups", 0)) / elapsed,
            "gpu_percent": (gb.get(p["pid"], 0) - ga.get(p["pid"], 0)) / (elapsed * 1e9) * 100,
            "energy_impact": impact.get(p["pid"], 0.0),
        }
        k = kinds.setdefault(kind_of(p), dict.fromkeys(total, 0.0))
        for key, value in row.items():
            total[key] += value
            k[key] += value
    if front_fraction < 0.95:
        log(f"WARNING: the browser was in front only {front_fraction:.0%} of this window")
    return {
        "seconds": round(elapsed, 1),
        **total,
        "front_fraction": front_fraction,
        "by_kind": kinds,
        "memory": summarize(b),
    }


def ensure_media():
    """Test videos, generated once: a 1080p30 VP9 movie and a small ad."""
    os.makedirs(MEDIA, exist_ok=True)
    specs = {
        "movie.webm": ("testsrc2=size=1920x1080:rate=30", "noise=alls=12:allf=t", "4M", 20),
        "ad.webm": ("testsrc2=size=640x360:rate=30", "noise=alls=12:allf=t", "800k", 10),
    }
    for name, (src, vf, rate, secs) in specs.items():
        out = os.path.join(MEDIA, name)
        if os.path.exists(out):
            continue
        log(f"generating {name}")
        subprocess.run(
            [
                "ffmpeg",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                src,
                "-t",
                str(secs),
                "-vf",
                vf,
                "-c:v",
                "libvpx-vp9",
                "-b:v",
                rate,
                "-deadline",
                "realtime",
                "-cpu-used",
                "8",
                "-row-mt",
                "1",
                out + ".tmp.webm",
            ],
            check=True,
        )
        os.rename(out + ".tmp.webm", out)


class _Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        path = path.split("?", 1)[0]
        if path.startswith("/media/"):
            return os.path.join(MEDIA, os.path.basename(path))
        return os.path.join(HERE, "pages", os.path.basename(path) or "static.html")

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass


@functools.cache
def page_server():
    """Serves bench/pages on 127.0.0.1 (and as http://localhost, a different
    site, for the cross-site ad frames)."""
    ensure_media()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PAGE_PORT), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def page_url(name):
    page_server()
    return f"http://127.0.0.1:{PAGE_PORT}/{name}"


def page_targets(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=10) as r:
        return [t for t in json.load(r) if t.get("type") == "page"]


def listening_pid(port):
    out = subprocess.run(
        ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fp"], capture_output=True, text=True, check=False
    ).stdout
    pids = [int(line[1:]) for line in out.splitlines() if line.startswith("p")]
    return pids[0] if pids else None


class DevTools:
    """Minimal Chrome DevTools Protocol client over a raw WebSocket. Refuses
    to talk to any browser that is not in the process tree this harness
    launched, so it can never touch the user's own browsers."""

    def __init__(self, port, root_pid, match="", timeout=30):
        deadline = time.time() + timeout
        while True:
            owner = listening_pid(port)
            if owner is not None:
                break
            if time.time() > deadline:
                raise RuntimeError(f"nothing listening on DevTools port {port}")
            time.sleep(0.5)
        if owner not in tree_pids(root_pid):
            raise RuntimeError(f"port {port} belongs to pid {owner}, not the benchmarked browser")
        while True:
            pages = [t for t in page_targets(port) if match in t.get("url", "")]
            if pages:
                break
            if time.time() > deadline:
                raise RuntimeError(f"no page target matching {match!r}")
            time.sleep(0.5)
        url = pages[0]["webSocketDebuggerUrl"]
        host_port, path = url[len("ws://") :].split("/", 1)
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            (
                f"GET /{path} HTTP/1.1\r\nHost: {host_port}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        response = b""
        while b"\r\n\r\n" not in response:
            response += self.sock.recv(4096)
        if b" 101 " not in response.split(b"\r\n", 1)[0]:
            raise RuntimeError(f"WebSocket handshake failed: {response[:200]!r}")
        self.buffer = response.split(b"\r\n\r\n", 1)[1]
        self.next_id = 0

    def _recv_exact(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("DevTools connection closed")
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def _send(self, payload, opcode=1):
        header = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _recv_message(self):
        message = b""
        while True:
            b0, b1 = self._recv_exact(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._recv_exact(8))[0]
            payload = self._recv_exact(n)
            opcode = b0 & 0x0F
            if opcode == 9:
                self._send(payload, opcode=10)
                continue
            if opcode == 8:
                raise ConnectionError("DevTools connection closed")
            message += payload
            if b0 & 0x80:
                return json.loads(message)

    def call(self, method, params=None):
        self.next_id += 1
        self._send(json.dumps({"id": self.next_id, "method": method, "params": params or {}}).encode())
        while True:
            msg = self._recv_message()
            if msg.get("id") == self.next_id:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg["result"]

    def evaluate(self, expression, await_promise=False):
        result = self.call(
            "Runtime.evaluate", {"expression": expression, "returnByValue": True, "awaitPromise": await_promise}
        )
        return result["result"].get("value")

    def close(self):
        self.sock.close()
