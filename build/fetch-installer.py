#!/usr/bin/env python3
"""Build-time helper: find the Fishbowl installer on the GitHub release,
download and verify it, and pull the license agreement out of it.

Runs inside the Dockerfile's `installer` stage. It reads the release metadata
that the Dockerfile fetched with ADD (so BuildKit notices when the release's
assets change), then:

  1. requires exactly one asset named Fishbowl-<version>.sh,
  2. downloads it and checks its size (and SHA-256 when GitHub reports one),
  3. unpacks the installer's archive WITHOUT running any of its code, to read
     the install4j configuration (version, Java requirement) and the license
     text the installer shows,
  4. writes everything the runtime image needs into --out.

Every failure exits non-zero with a message aimed at the maintainer.
"""

import argparse
import fnmatch
import gzip
import hashlib
import html
import html.parser
import json
import os
import re
import subprocess
import sys
import tarfile
import textwrap
import xml.etree.ElementTree as ET

ASSET_PATTERN = "Fishbowl-*.sh"
VERSION_RE = re.compile(r"Fishbowl-([0-9]+(?:\.[0-9]+)*)\.sh")
REQUIRED_JAVA = "21"


def fail(message):
    bar = "=" * 72
    sys.stderr.write(f"\n{bar}\nFISHBOWL INSTALLER LOOKUP FAILED\n\n{message}\n{bar}\n\n")
    sys.exit(1)


def info(message):
    print(f"[fetch-installer] {message}", flush=True)


# --------------------------------------------------------------------------
# 1. Pick the asset
# --------------------------------------------------------------------------
def pick_asset(release, repo, tag):
    where = f"release '{tag}' of {repo}"
    if not isinstance(release, dict) or "assets" not in release:
        msg = release.get("message") if isinstance(release, dict) else None
        fail(f"The GitHub API did not return release data for the {where}."
             + (f"\nGitHub said: {msg}" if msg else "")
             + "\nCheck INSTALLER_REPO and INSTALLER_RELEASE_TAG, and that the release exists and is published.")

    matches = [a for a in release["assets"]
               if fnmatch.fnmatchcase(a.get("name", ""), ASSET_PATTERN)]
    if not matches:
        others = ", ".join(a.get("name", "?") for a in release["assets"]) or "none"
        fail(f"No Fishbowl installer found on the {where}.\n"
             f"Expected exactly one asset named like {ASSET_PATTERN} "
             f"(for example Fishbowl-2026.11.sh).\nAssets on the release: {others}\n\n"
             "Fix: upload the Fishbowl Linux installer to that release.")
    if len(matches) > 1:
        names = "\n  ".join(a["name"] for a in matches)
        fail(f"Found {len(matches)} Fishbowl installers on the {where}:\n  {names}\n\n"
             "The release must hold exactly one. Fix: delete the old installer(s) "
             "from the release, keep only the one you want built.")

    asset = matches[0]
    state = asset.get("state", "uploaded")
    if state != "uploaded":
        fail(f"{asset['name']} on the {where} is not fully uploaded (state: {state}).\n"
             "Wait for the upload to finish, then build again.")
    m = VERSION_RE.fullmatch(asset["name"])
    if not m:
        fail(f"Can't read a version from the asset name '{asset['name']}'.\n"
             "Name it Fishbowl-<version>.sh, for example Fishbowl-2026.11.sh "
             "(the name Fishbowl publishes it under).")
    return asset, m.group(1)


# --------------------------------------------------------------------------
# 2. Download and verify
# --------------------------------------------------------------------------
def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(asset, dest):
    url = asset["browser_download_url"]
    part = dest + ".part"
    info(f"Downloading {asset['name']} ({asset['size']:,} bytes) from {url}")
    cmd = ["curl", "--fail", "--location", "--silent", "--show-error",
           "--retry", "5", "--retry-delay", "5", "--retry-all-errors",
           "--output", part, url]
    if subprocess.run(cmd).returncode != 0:
        fail(f"Downloading {asset['name']} failed (URL: {url}).\n"
             "The release must be public, or the build needs network access to GitHub.")
    size = os.path.getsize(part)
    if size != asset["size"]:
        fail(f"Downloaded {size:,} bytes but GitHub says {asset['name']} is {asset['size']:,} bytes.\n"
             "The download was cut short or the asset changed mid-build. Build again.")
    digest = sha256_of(part)
    reported = (asset.get("digest") or "")
    if reported.startswith("sha256:"):
        if reported.split(":", 1)[1].lower() != digest:
            fail(f"SHA-256 mismatch for {asset['name']}.\n"
                 f"GitHub reports {reported}, download is sha256:{digest}.")
        info("SHA-256 matches the digest GitHub reports for the asset.")
    else:
        info("GitHub reported no digest for this asset; size check only.")
    os.replace(part, dest)
    return digest


# --------------------------------------------------------------------------
# 3. Look inside the installer (no code from it is executed)
# --------------------------------------------------------------------------
def payload_length(installer):
    with open(installer, "rb") as f:
        header = f.read(256 * 1024).decode("latin-1")
    if not header.startswith("#!/bin/sh") or "INSTALL4J" not in header:
        fail("The downloaded file does not look like an install4j Linux installer "
             "(no '#!/bin/sh' header mentioning INSTALL4J).")
    m = re.search(r'tail -c (\d+) "\$prg_dir/\$\{progname\}"', header)
    if not m:
        fail("Could not find the archive offset in the installer header "
             "(expected a line like: tail -c <N> \"$prg_dir/${progname}\").\n"
             "The installer format changed; fetch-installer.py needs updating.")
    return int(m.group(1))


def read_archive_members(installer, wanted):
    """Stream the installer's embedded tar.gz and return {name: bytes} for wanted names."""
    length = payload_length(installer)
    found = {}
    with open(installer, "rb") as f:
        f.seek(-length, os.SEEK_END)
        with gzip.GzipFile(fileobj=f) as gz, tarfile.open(fileobj=gz, mode="r|") as tar:
            for member in tar:
                if member.isfile() and wanted(member.name):
                    found[member.name] = tar.extractfile(member).read()
    return found


def parse_i4j_config(raw):
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as e:
        fail(f"i4jparams.conf inside the installer is not valid XML: {e}")
    general = root.find("general")
    if general is None:
        fail("i4jparams.conf has no <general> element; installer format changed.")
    variables = {v.get("name"): v.get("value") for v in root.iter("variable")}
    app_version = general.get("applicationVersion", "")
    java_min = variables.get("sys.javaMinVersion") or general.get("minJavaVersion", "")
    java_max = variables.get("sys.javaMaxVersion", "")
    if java_min != REQUIRED_JAVA or java_max not in ("", REQUIRED_JAVA):
        fail(f"This installer requires Java {java_min}"
             + (f" to {java_max}" if java_max else "+")
             + f", but the image ships Java {REQUIRED_JAVA}.\n"
             "Update the Java package in the Dockerfile (and re-test) before publishing this version.")

    # The license screen: the form screen whose radio buttons set 'agreed'.
    license_files = []
    for screen in root.iter("screen"):
        text = ET.tostring(screen, encoding="unicode")
        if "<string>agreed</string>" not in text:
            continue
        for comp in screen.iter("formComponent"):
            obj = comp.find("./java/object")
            if obj is None or not obj.get("class", "").endswith("HtmlDisplayFormComponent"):
                continue
            strings = [s.text or "" for s in comp.iter("string")]
            internal = [s for s in strings if s.startswith("i4j_extf_")]
            originals = [s for s in strings if re.search(r"\.(html?|txt)$", s, re.I)
                         and not s.startswith("i4j_extf_")]
            if internal:
                license_files.append((internal[0], originals[0] if originals else internal[0]))
        break
    if not license_files:
        fail("Could not find the license agreement screen in the installer's configuration.\n"
             "Without it the image cannot show Fishbowl's EULA, so the build stops here.")
    return app_version, java_min, license_files


class _TextExtractor(html.parser.HTMLParser):
    BLOCK = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "head", "title"):
            self.skip += 1
        elif tag in self.BLOCK:
            self.parts.append("\n\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style", "head", "title"):
            self.skip = max(0, self.skip - 1)
        elif tag in self.BLOCK:
            self.parts.append("\n\n")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def html_to_text(raw):
    p = _TextExtractor()
    p.feed(raw.decode("utf-8", errors="replace"))
    text = html.unescape("".join(p.parts)).replace(" ", " ")
    paragraphs = []
    for block in re.split(r"\n\s*\n", text):
        block = re.sub(r"\s+", " ", block).strip()
        if block:
            paragraphs.append(textwrap.fill(block, width=78))
    return "\n\n".join(paragraphs) + "\n"


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--release-json", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo", default="(unknown repo)")
    ap.add_argument("--tag", default="(unknown tag)")
    ap.add_argument("--expected-asset-id", default="")
    args = ap.parse_args()

    try:
        with open(args.release_json, encoding="utf-8") as f:
            release = json.load(f)
    except (OSError, ValueError) as e:
        fail(f"Could not read the release metadata: {e}")

    asset, version = pick_asset(release, args.repo, args.tag)
    info(f"Found {asset['name']} (asset id {asset['id']}, version {version})")
    if args.expected_asset_id and str(asset["id"]) != args.expected_asset_id:
        fail(f"The release now holds asset id {asset['id']}, but this build was started for "
             f"asset id {args.expected_asset_id}. The installer was replaced mid-run; build again.")

    os.makedirs(os.path.join(args.out, "eula"), exist_ok=True)
    installer = os.path.join(args.out, asset["name"])
    digest = download(asset, installer)

    info("Reading the installer's configuration and license text (nothing is executed)")
    members = read_archive_members(installer, lambda n: n == "i4jparams.conf")
    if "i4jparams.conf" not in members:
        fail("i4jparams.conf not found inside the installer archive; installer format changed.")
    app_version, java_req, license_files = parse_i4j_config(members["i4jparams.conf"])
    wanted = {internal for internal, _ in license_files}
    docs = read_archive_members(installer, lambda n: n in wanted)

    written = []
    for internal, original in license_files:
        if internal not in docs:
            fail(f"License file {internal} ({original}) is referenced but missing from the archive.")
        name = re.sub(r"\.(html?|txt)$", "", original, flags=re.I) + ".txt"
        text = html_to_text(docs[internal]) if internal.lower().endswith((".htm", ".html")) \
            else docs[internal].decode("utf-8", errors="replace")
        if len(text) < 1000:
            fail(f"License text {original} is suspiciously short ({len(text)} characters).")
        with open(os.path.join(args.out, "eula", name), "w", encoding="utf-8") as f:
            f.write(text)
        written.append((name, original))
    default = next((n for n, o in written if o.lower() == "license.htm"), written[0][0])

    env = {
        "FISHBOWL_VERSION": version,
        "FISHBOWL_APP_VERSION": app_version,
        "FISHBOWL_INSTALLER": f"/opt/fishbowl-installer/{asset['name']}",
        "FISHBOWL_INSTALLER_SHA256": digest,
        "FISHBOWL_INSTALLER_SIZE": str(asset["size"]),
        "FISHBOWL_INSTALLER_ASSET_ID": str(asset["id"]),
        "FISHBOWL_JAVA_REQUIRED": java_req,
        "FISHBOWL_EULA": f"/opt/fishbowl-installer/eula/{default}",
        "FISHBOWL_EULA_VARIANTS": " ".join(n for n, _ in written),
    }
    with open(os.path.join(args.out, "installer.env"), "w", encoding="utf-8") as f:
        for k, v in env.items():
            if not re.fullmatch(r"[A-Za-z0-9._:/ +-]*", v):
                fail(f"Unexpected characters in {k}: {v!r}")
            f.write(f"{k}='{v}'\n")
    with open(os.path.join(args.out, "VERSION"), "w") as f:
        f.write(version + "\n")
    info(f"Fishbowl {app_version} (file version {version}); installer requires Java {java_req}; "
         f"license texts: {', '.join(n for n, _ in written)}; default: {default}")


if __name__ == "__main__":
    main()
