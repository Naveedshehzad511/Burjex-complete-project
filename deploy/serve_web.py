"""SPA static server for Flutter web builds (index.html fallback)."""
from __future__ import annotations

import mimetypes
import sys
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
PORT = int(sys.argv[2])
HOST = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"

mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/javascript", ".mjs")


class SpaHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def do_GET(self) -> None:
        rel = self.path.split("?", 1)[0].split("#", 1)[0].lstrip("/")
        candidate = (ROOT / rel).resolve()
        try:
            candidate.relative_to(ROOT)
        except ValueError:
            self.send_error(403)
            return
        if rel and candidate.is_file():
            return super().do_GET()
        self.path = "/index.html"
        return super().do_GET()

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    httpd = ThreadingHTTPServer((HOST, PORT), SpaHandler)
    print(f"serving {ROOT} at http://{HOST}:{PORT}/", flush=True)
    httpd.serve_forever()
