#!/usr/bin/env python3
"""Tiny stand-in for the two GitHub endpoints the build uses, for local tests.

  GET /repos/<any owner>/<any repo>/releases/tags/<tag>   -> release JSON
  GET /download/<name>                            -> the asset bytes

Serves every regular file in --assets as an asset of the release, so a test
can drop zero, one or two Fishbowl-*.sh files (or symlinks) there.

Usage: mock_github.py --assets DIR --port 8099 [--tag fishbowl-installer]
       [--no-digest] [--bad-digest]
"""
import argparse
import hashlib
import http.server
import json
import re
import os
import zlib

_digest_cache = {}


def asset_list(args, base):
    assets = []
    for name in sorted(os.listdir(args.assets)):
        path = os.path.join(args.assets, name)
        if not os.path.isfile(path):
            continue
        st = os.stat(path)
        entry = {
            "id": zlib.crc32(f"{name}:{st.st_size}:{st.st_mtime_ns}".encode()) & 0x7FFFFFFF,
            "name": name,
            "state": "uploaded",
            "size": st.st_size,
            "updated_at": "2026-11-15T00:00:00Z",
            "browser_download_url": f"{base}/download/{name}",
        }
        if not args.no_digest:
            key = (path, st.st_size, st.st_mtime_ns)
            if key not in _digest_cache:
                h = hashlib.sha256()
                with open(path, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                _digest_cache[key] = h.hexdigest()
            digest = _digest_cache[key]
            entry["digest"] = "sha256:" + ("0" * 64 if args.bad_digest else digest)
        assets.append(entry)
    return assets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--assets", required=True)
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--tag", default="fishbowl-installer")
    ap.add_argument("--no-digest", action="store_true")
    ap.add_argument("--bad-digest", action="store_true")
    args = ap.parse_args()
    base = f"http://127.0.0.1:{args.port}"
    # Any owner/repo: the build asks for whatever INSTALLER_REPO says.
    release_re = re.compile(r"^/repos/[^/]+/[^/]+/releases/tags/" + re.escape(args.tag) + r"$")

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *a):
            pass

        def do_GET(self):
            if release_re.match(self.path):
                body = json.dumps({"tag_name": args.tag, "assets": asset_list(args, base)}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path.startswith("/download/"):
                path = os.path.join(args.assets, os.path.basename(self.path))
                if os.path.isfile(path):
                    self.send_response(200)
                    self.send_header("Content-Length", str(os.path.getsize(path)))
                    self.end_headers()
                    with open(path, "rb") as f:
                        while chunk := f.read(1 << 20):
                            self.wfile.write(chunk)
                    return
            body = b'{"message":"Not Found"}'
            self.send_response(404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
