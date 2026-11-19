#!/usr/bin/env python3
"""Copy Fishbowl Server's and MySQL's own log files into the container's log.

    python3 -I -u logstream.py TAG=FILE [TAG=FILE ...]

Fishbowl Server writes /opt/Fishbowl/logs/fbserver.log and MySQL writes
/var/lib/fishbowl/logs/mysqld.log. With FISHBOWL_LOG_STREAM=1 the entrypoint
runs this so both also reach `docker logs` (and any log collector reading it),
one event per line, in the same shape as the container's own lines:

    2026-11-19T09:15:02Z [fbserver] <the line as Fishbowl wrote it>

* Follows each file from its end at start (what was already there stays in the
  file), and from the beginning when a file appears or is replaced (rotation,
  a new install) or shrinks (truncated).
* Every line, Java stack-trace lines included, gets the timestamp and tag, so a
  collector can join a trace back together. No colours, no partial lines; a very
  long line is cut at 16 KiB and marked.
* Secrets never pass: the image's MySQL root password, the License Key, other
  password-like values in Fishbowl's settings files and the page's access code
  are replaced with [redacted]. The list is read again every minute, so a key
  entered after start is covered too.

The files themselves are left alone. Exits on SIGTERM.
"""

import os
import re
import signal
import sys
import time

POLL = 0.5
REFRESH = 60
MAX_LINE = 16384
LIB = "/usr/local/lib/fishbowl"
SECRET_SOURCES = {
    "password_file": LIB + "/mysql-root-password.txt",
    "web_code": "/var/lib/fishbowl/state/web-code",
    "props": [
        "/opt/Fishbowl/server/bin/eve.properties",
        "/opt/Fishbowl/server/bin/dbsettings.properties",
        "/opt/Fishbowl/installSettings",
        "/opt/Fishbowl/.install4j/response.varfile",
    ],
}
SECRET_KEY = re.compile(r"(licen[cs]e|passw|pwd|secret|token)", re.I)

running = True


def stop(*_):
    global running
    running = False


def read_first_line(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.readline().strip()
    except OSError:
        return ""


def props_values(path):
    """Values of password- and license-like keys in a Java properties file (simple reader)."""
    out = []
    try:
        with open(path, encoding="latin-1") as f:
            for raw in f:
                line = raw.strip()
                if not line or line[0] in "#!":
                    continue
                m = re.match(r"([^=:\s]+)\s*[=:\s]\s*(.*)$", line)
                if m and SECRET_KEY.search(m.group(1)):
                    val = m.group(2).replace("\\:", ":").replace("\\=", "=").replace("\\\\", "\\").strip()
                    out.append(val)
    except OSError:
        pass
    return out


def load_secrets():
    found = set()
    for v in (read_first_line(SECRET_SOURCES["password_file"]), read_first_line(SECRET_SOURCES["web_code"])):
        if v:
            found.add(v)
    for p in SECRET_SOURCES["props"]:
        found.update(props_values(p))
    # Short values (true, 0, 2456) would only blank out ordinary words.
    return sorted((s for s in found if len(s) >= 6), key=len, reverse=True)


def redact(text, secrets):
    for s in secrets:
        if s in text:
            text = text.replace(s, "[redacted]")
    return text


class Follower:
    def __init__(self, tag, path):
        self.tag, self.path = tag, path
        self.f = None
        self.ino = None
        self.buf = b""
        self.first = True  # at start: begin at the end of what is already there

    def _open(self):
        try:
            f = open(self.path, "rb")
        except OSError:
            self.first = False  # a file that appears later is read from its start
            return False
        st = os.fstat(f.fileno())
        if self.first:
            f.seek(0, os.SEEK_END)
        self.first = False
        self.f, self.ino, self.buf = f, st.st_ino, b""
        return True

    def _close(self):
        if self.f:
            self.f.close()
        self.f, self.ino, self.buf = None, None, b""

    def poll(self, emit):
        if self.f is None and not self._open():
            return
        # Replaced (rotation, a new install) or truncated: start over from the new file's beginning.
        try:
            st = os.stat(self.path)
            if st.st_ino != self.ino or st.st_size < self.f.tell():
                self._drain(emit)
                self._close()
                self.first = False
                if not self._open():
                    return
        except OSError:
            self._drain(emit)
            self._close()
            return
        self._drain(emit)

    def _drain(self, emit):
        while True:
            chunk = self.f.read(65536)
            if not chunk:
                break
            self.buf += chunk
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                emit(self.tag, line)
            if len(self.buf) > MAX_LINE:
                emit(self.tag, self.buf[:MAX_LINE] + b" [line cut]")
                self.buf = b""


def main(argv):
    pairs = []
    for arg in argv:
        tag, sep, path = arg.partition("=")
        if not sep or not re.fullmatch(r"[a-z][a-z0-9-]{0,15}", tag) or not path.startswith("/"):
            print("usage: logstream.py TAG=/path/to/file [...]", file=sys.stderr)
            return 2
        pairs.append(Follower(tag, path))
    if not pairs:
        print("usage: logstream.py TAG=/path/to/file [...]", file=sys.stderr)
        return 2
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    secrets, loaded = load_secrets(), time.monotonic()
    out = sys.stdout

    def emit(tag, raw):
        text = raw.decode("utf-8", errors="replace").rstrip("\r")
        text = "".join(ch if ch == "\t" or ch >= " " else " " for ch in text)  # no escape codes or colours
        if len(text) > MAX_LINE:
            text = text[:MAX_LINE] + " [line cut]"
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        out.write("%s [%s] %s\n" % (stamp, tag, redact(text, secrets)))

    while running:
        if time.monotonic() - loaded > REFRESH:
            secrets, loaded = load_secrets(), time.monotonic()
        for p in pairs:
            p.poll(emit)
        out.flush()
        time.sleep(POLL)
    for p in pairs:
        p.poll(emit)
    out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
