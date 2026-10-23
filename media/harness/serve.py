"""Serves the converter harness on localhost.

/ is the repository, /samples/ a folder of real site media that isn't
committed, and POST /save/<name> stores converted output under the output
folder (also served, at /out/) for ffprobe.

    python3 media/harness/serve.py [samples-dir] [output-dir] [port]
"""

import http.server
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SAMPLES = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/video-delivery-research")
OUT = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "/tmp/mbga-media-harness")
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8791


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def translate_path(self, path):
        path = path.split("?", 1)[0]
        for prefix, base in (("/samples/", SAMPLES), ("/out/", OUT)):
            if path.startswith(prefix):
                return str(base / pathlib.PurePosixPath(path[len(prefix) :]).name)
        return super().translate_path(path)

    def do_POST(self):
        if not self.path.startswith("/save/"):
            self.send_error(404)
            return
        name = pathlib.PurePosixPath(self.path[len("/save/") :]).name
        length = int(self.headers.get("Content-Length", "0"))
        (OUT / name).write_bytes(self.rfile.read(length))
        self.send_response(204)
        self.end_headers()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
