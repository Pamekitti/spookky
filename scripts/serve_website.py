#!/usr/bin/env python3
"""Preview the static site under its real GitHub Pages project prefix."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "website"


class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        if not path.startswith("/spookky/"):
            return str(ROOT / ".not-found")
        self.path = path[len("/spookky"):]  # Standard handler normalizes traversal and URL escapes.
        return super().translate_path(self.path)


if __name__ == "__main__":
    import functools
    print("http://127.0.0.1:48768/spookky/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 48768), functools.partial(Handler, directory=str(ROOT))).serve_forever()
