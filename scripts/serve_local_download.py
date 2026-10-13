#!/usr/bin/env python3
"""Serve only prepared local installer files on the loopback interface."""
import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--port", type=int, default=48769)
    args = parser.parse_args()
    root = args.directory.resolve()
    manifest = json.loads((root / "local-build.json").read_text())
    if manifest.get("kind") != "local" or not re.fullmatch(r"Spookky-\d+\.\d+\.\d+-local-arm64\.dmg", manifest.get("asset", "")):
        raise SystemExit("Use a prepared private local installer directory")
    allowed = {"index.html", "icon.png", "SHA256SUMS", "local-build.json", manifest["asset"]}

    class Handler(SimpleHTTPRequestHandler):
        def send_head(self):
            name = unquote(urlsplit(self.path).path).removeprefix("/") or "index.html"
            target = root / name
            if name not in allowed or not target.is_file() or target.is_symlink():
                self.send_error(404)
                return None
            return super().send_head()

        def translate_path(self, path):
            name = unquote(urlsplit(path).path).removeprefix("/") or "index.html"
            return str(root / name)

        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if urlsplit(self.path).path == "/" + manifest["asset"]:
                self.send_header("Content-Disposition", 'attachment; filename="' + manifest["asset"] + '"')
            super().end_headers()

        def list_directory(self, path):
            self.send_error(404); return None

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"http://127.0.0.1:{server.server_port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__": main()
