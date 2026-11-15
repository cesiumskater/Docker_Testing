#!/usr/bin/env python3
"""CI step: find the one Fishbowl-*.sh asset on the release and print its facts
as key=value lines for $GITHUB_OUTPUT. Same rules and messages as the build
(it reuses build/fetch-installer.py's checks).

usage: find_installer.py OWNER/REPO TAG
env:   GITHUB_TOKEN (optional, raises the API rate limit), GITHUB_API_URL (optional)
"""
import importlib.util
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fetch_installer", os.path.join(HERE, "..", "build", "fetch-installer.py"))
fi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fi)


def main():
    repo, tag = sys.argv[1], sys.argv[2]
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    req = urllib.request.Request(f"{api}/repos/{repo}/releases/tags/{tag}",
                                 headers={"Accept": "application/vnd.github+json",
                                          "User-Agent": "fishbowl-docker-ci"})
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            release = json.load(r)
    except urllib.error.HTTPError as e:
        fi.fail(f"GitHub API returned {e.code} for release '{tag}' of {repo}.\n"
                "Create a published (not draft) release with exactly that tag, holding one Fishbowl-*.sh asset.")
    asset, version = fi.pick_asset(release, repo, tag)
    digest = asset.get("digest") or ""
    out = {
        "asset_id": str(asset["id"]),
        "asset_name": asset["name"],
        "version": version,
        "size": str(asset["size"]),
        "digest": digest,
        "updated_at": asset.get("updated_at", ""),
    }
    for k, v in out.items():
        print(f"{k}={v}")


if __name__ == "__main__":
    main()
