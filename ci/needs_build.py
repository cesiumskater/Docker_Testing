#!/usr/bin/env python3
"""CI step: decide whether to build. Prints build=true|false and a reason.

Reads the installer asset id recorded as a label on IMAGE:latest. If the
image doesn't exist yet, can't be read, or carries a different asset id, the
installer changed (or was never built) and the answer is build=true.

usage: needs_build.py IMAGE ASSET_ID
"""
import json
import subprocess
import sys

LABEL = "io.github.fishbowl-docker.installer-asset-id"


def main():
    image, asset_id = sys.argv[1], sys.argv[2]
    r = subprocess.run(["docker", "buildx", "imagetools", "inspect", f"{image}:latest",
                        "--format", "{{json .Image}}"], capture_output=True, text=True)
    if r.returncode != 0:
        print("build=true")
        print(f"reason=no readable {image}:latest yet ({r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'not found'})")
        return
    data = json.loads(r.stdout)
    # Single-platform images give one config; multi-platform ones a map of platform -> config.
    configs = [data] if isinstance(data, dict) and ("config" in data or "rootfs" in data) else list(data.values())
    published = {((c.get("config") or {}).get("Labels") or {}).get(LABEL) for c in configs if isinstance(c, dict)}
    published.discard(None)
    if asset_id in published:
        print("build=false")
        print(f"reason={image}:latest was already built from installer asset {asset_id}")
    else:
        print("build=true")
        print(f"reason=installer asset changed ({', '.join(sorted(published)) or 'none'} -> {asset_id})")


if __name__ == "__main__":
    main()
