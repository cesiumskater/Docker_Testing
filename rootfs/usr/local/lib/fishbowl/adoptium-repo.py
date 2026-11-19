#!/usr/bin/env python3
"""Write the dnf repository file for Eclipse Temurin (Java 21) from Adoptium.

Used by the Dockerfile at build time:

    python3 -I adoptium-repo.py --out /etc/yum.repos.d/adoptium.repo [--release N]

Adoptium publishes one RPM tree per Fedora release under
https://packages.adoptium.net/artifactory/rpm/fedora/<release>/<arch>/, and a new
Fedora release's tree can appear weeks after that release (Fedora 45's was
missing when Fedora 45 came out). Temurin's packages are built against common
system libraries, not one Fedora release, so this picks the newest tree that
exists: this system's release, or the one or two before it. --release N forces
one tree.

The repository is switched on and limited to Temurin 21, so it can never offer
anything else to dnf. Packages are checked against Adoptium's signing key.

Exit status: 0 = written; 1 = no tree found (the build stops with the reason).
"""

import argparse
import os
import platform
import subprocess
import sys
import urllib.error
import urllib.request

BASE = "https://packages.adoptium.net/artifactory/rpm/fedora"
GPG_KEY = "https://packages.adoptium.net/artifactory/api/gpg/key/public"
FALLBACK = 2  # how many earlier Fedora releases to try


def fedora_release():
    try:
        out = subprocess.run(["rpm", "-E", "%fedora"], capture_output=True, text=True, check=True).stdout.strip()
        return int(out)
    except (OSError, subprocess.CalledProcessError, ValueError):
        pass
    try:
        with open("/etc/os-release", encoding="utf-8") as f:
            for line in f:
                if line.startswith("VERSION_ID="):
                    return int(line.split("=", 1)[1].strip().strip('"'))
    except (OSError, ValueError):
        pass
    return None


def tree_exists(release, arch, timeout=30):
    url = "%s/%d/%s/repodata/repomd.xml" % (BASE, release, arch)
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "fishbowl-docker-build"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status == 200 and b"<repomd" in r.read(4096)
    except (urllib.error.URLError, OSError, ValueError):
        return False


def repo_text(release, note):
    return "\n".join([
        "# Eclipse Temurin 21 (Java) from Adoptium, written by adoptium-repo.py at image build.",
        "# %s" % note,
        "[adoptium]",
        "name=Eclipse Temurin (Adoptium) for Fedora %d" % release,
        "baseurl=%s/%d/$basearch" % (BASE, release),
        "enabled=1",
        "gpgcheck=1",
        "repo_gpgcheck=0",
        "gpgkey=%s" % GPG_KEY,
        "includepkgs=temurin-21-jdk temurin-21-jre",
        "",
    ])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--release", default="", help="force this Fedora release's tree")
    a = ap.parse_args()

    arch = platform.machine() or "x86_64"
    if a.release.strip():
        if not a.release.strip().isdigit():
            print("adoptium-repo.py: --release takes a Fedora release number, such as 45", file=sys.stderr)
            return 1
        release = int(a.release)
        if not tree_exists(release, arch):
            print("\nBUILD STOPPED: Adoptium has no Temurin tree for Fedora %d (%s/%d/%s). "
                  "Leave ADOPTIUM_FEDORA_RELEASE empty to pick the newest one.\n" % (release, BASE, release, arch),
                  file=sys.stderr)
            return 1
        note = "Fedora %d tree, chosen with ADOPTIUM_FEDORA_RELEASE." % release
    else:
        own = fedora_release()
        if own is None:
            print("\nBUILD STOPPED: can't tell which Fedora release this is (rpm -E %fedora).\n", file=sys.stderr)
            return 1
        release = None
        for r in range(own, own - FALLBACK - 1, -1):
            if tree_exists(r, arch):
                release = r
                break
            print("Adoptium has no Temurin tree for Fedora %d yet" % r)
        if release is None:
            print("\nBUILD STOPPED: Adoptium has no Temurin tree for Fedora %d or the %d releases "
                  "before it (%s/<release>/%s), or packages.adoptium.net can't be reached from this build.\n"
                  % (own, FALLBACK, BASE, arch), file=sys.stderr)
            return 1
        if release == own:
            note = "Fedora %d tree (this image's own release)." % release
        else:
            note = ("Fedora %d tree: Adoptium had no Fedora %d tree when this image was built; "
                    "the next rebuild checks again." % (release, own))
    tmp = a.out + ".tmp"
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(repo_text(release, note))
    os.chmod(tmp, 0o644)
    os.replace(tmp, a.out)
    print("Java 21 comes from Adoptium's " + note)
    return 0


if __name__ == "__main__":
    sys.exit(main())
