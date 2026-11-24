#!/usr/bin/env python3
"""The Fishbowl page: the small web server behind http://localhost:6080/.

It runs inside the container as the unprivileged user "fbweb" and does four
things:

  * shows what state the container is in and what it needs from you
  * takes first-time setup and upgrade answers (license agreement, license key
    or trial) and hands them to the entrypoint
  * takes files of any type into the import folder (.sql backups for the Restore tab of Fishbowl
    Server Administration
  * shows Server Administration and the Fishbowl Client in browser tabs (noVNC)
    by passing the browser's WebSocket through to that window's private socket

It never runs anything itself. Requests go to the root entrypoint as small
files in /dev/shm/fishbowl-web (RAM), and the entrypoint checks every value
again. Request bodies and query strings are never logged.

Everything except the sign-in page and the static files needs the access code
(printed in the container log; `docker exec <container> fishbowl-link`).
"""
import hashlib
import hmac
import http.server
import calendar
import json
import os
import posixpath
import re
import secrets
import select
import socket
import sys
import threading
import time
import urllib.parse

PORT = 6080
RUN = "/run/fishbowl"
WEB = "/usr/local/share/fishbowl/web"
NOVNC = "/usr/share/novnc"
SPOOL = os.environ.get("FISHBOWL_SPOOL", "/dev/shm/fishbowl-web")   # /run/fishbowl/spool in the split stack
# Who may read a request: root alone in the single container (0600); in the split
# stack, Fishbowl's own containers, through its group (0640, FISHBOWL_SPOOL_MODE).
SPOOL_MODE = 0o640 if os.environ.get("FISHBOWL_SPOOL_MODE") == "0640" else 0o600
IMPORT = "/var/lib/fishbowl/import"
CODE_FILE = RUN + "/web-code"
INSTALLER_ENV = "/opt/fishbowl-installer/installer.env"
INSTALLER_DIR = "/opt/fishbowl-installer"

COOKIE = "fishbowl_page"
COOKIE_MAX_AGE = 30 * 24 * 3600
MAX_JSON = 64 * 1024
CHUNK = 1024 * 1024
SESSIONS = ("admin", "client")

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".gif": "image/gif",
    ".jpg": "image/jpeg",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".ttf": "font/ttf",
    ".txt": "text/plain; charset=utf-8",
    ".oga": "audio/ogg",
    ".mp3": "audio/mpeg",
}
CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
       "img-src 'self' data: blob:; connect-src 'self' ws: wss:; frame-ancestors 'none'; "
       "base-uri 'none'; form-action 'self'")


# ------------------------------------------------------------- small helpers
def read_text(path, limit=256 * 1024):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit)
    except OSError:
        return ""


def first_line(path):
    return read_text(path, 4096).split("\n", 1)[0].strip()


def read_kv(path):
    out = {}
    for line in read_text(path).splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def installer_info():
    """installer.env is a shell file of KEY='value' lines written at build time."""
    out = {}
    for line in read_text(INSTALLER_ENV).splitlines():
        m = re.match(r"^([A-Z0-9_]+)='(.*)'$", line.strip())
        if m:
            out[m.group(1)] = m.group(2)
    return out


INSTALLER = installer_info()


EULA_PATH = INSTALLER.get("FISHBOWL_EULA", "")


def eula():
    """The license text the installer shows, and its SHA-256 (the entrypoint
    only accepts an acceptance that names this exact text)."""
    try:
        with open(EULA_PATH, "rb") as f:
            raw = f.read()
    except OSError:
        return "", ""
    return raw.decode("utf-8", errors="replace"), hashlib.sha256(raw).hexdigest()


def eula_variants():
    names = []
    for name in INSTALLER.get("FISHBOWL_EULA_VARIANTS", "").split():
        if re.fullmatch(r"[A-Za-z0-9._-]+", name) and os.path.join(INSTALLER_DIR, "eula", name) != EULA_PATH:
            names.append(name)
    return names


def log(msg):
    sys.stdout.write("%s [fishbowl page] %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg))
    sys.stdout.flush()


# ------------------------------------------------------------------- sign-in
def current_code():
    return first_line(CODE_FILE)


def normalize_code(text):
    s = re.sub(r"[^A-Za-z0-9]", "", text or "").upper()
    if len(s) == 12:
        return "%s-%s-%s" % (s[0:4], s[4:8], s[8:12])
    return s


def token_for(code):
    """The cookie value. Derived from the access code, so sign-ins survive a
    restart and end when the code is replaced (fishbowl-link --new-code)."""
    return hmac.new(code.encode(), b"fishbowl-page-session-v1", hashlib.sha256).hexdigest()


class Limiter:
    """After too many wrong codes, refuse sign-ins for a while."""

    def __init__(self, tries=10, window=60):
        self.tries, self.window = tries, window
        self.fails = []
        self.lock = threading.Lock()

    def blocked(self):
        with self.lock:
            now = time.time()
            self.fails = [t for t in self.fails if now - t < self.window]
            return len(self.fails) >= self.tries

    def failed(self):
        with self.lock:
            self.fails.append(time.time())


LIMITER = Limiter()
UPLOAD_LOCK = threading.Lock()


# ------------------------------------------------------------------- status
def session_state(name):
    state = first_line("%s/session-%s" % (RUN, name))
    if state == "ready" and not os.path.exists("%s/ws/%s.sock" % (RUN, name)):
        return "starting"
    return state if state in ("starting", "ready") else "closed"


# Which Fishbowl version made a .sql backup: Fishbowl keeps a row per version it
# updated the database to in its `databaseversion` table ('Fishbowl v2026.7').
# Read once per file, in the background, and remembered while the file is unchanged.
VERSION_IN_DUMP = re.compile(rb"'Fishbowl v(\d+(?:\.\d+)+)'")
SCANS = {}          # (name, size, mtime_ns) -> "2026.7", or "" when not found
SCANS_RUNNING = set()
SCAN_LOCK = threading.Lock()


def version_key(v):
    try:
        return tuple(int(x) for x in v.split("."))
    except ValueError:
        return ()


def scan_made_by(path, key):
    found = ""
    try:
        with open(path, "rb") as f:
            for line in f:
                if line.startswith(b"INSERT INTO `databaseversion`"):
                    for m in VERSION_IN_DUMP.finditer(line):
                        v = m.group(1).decode()
                        if version_key(v) > version_key(found):
                            found = v
                elif found and line.startswith(b"INSERT INTO `"):
                    break   # mysqldump writes one table at a time: databaseversion is done
    except OSError:
        found = ""
    with SCAN_LOCK:
        SCANS[key] = found
        SCANS_RUNNING.discard(key)


def made_by(name, st):
    """The Fishbowl version in a backup: "2026.7", "" (not found), or None (still reading)."""
    key = (name, st.st_size, st.st_mtime_ns)
    with SCAN_LOCK:
        if key in SCANS:
            return SCANS[key]
        if key not in SCANS_RUNNING:
            SCANS_RUNNING.add(key)
            threading.Thread(target=scan_made_by, args=(os.path.join(IMPORT, name), key), daemon=True).start()
    return None


def list_imports():
    files = []
    try:
        with os.scandir(IMPORT) as it:
            for entry in it:
                if entry.name.startswith(".") or not entry.is_file(follow_symlinks=False):
                    continue
                st = entry.stat(follow_symlinks=False)
                files.append({"name": entry.name, "size": st.st_size, "modified": int(st.st_mtime),
                              "made_by": made_by(entry.name, st) if entry.name.lower().endswith(".sql") else "n/a"})
    except OSError:
        pass
    files.sort(key=lambda f: f["name"].lower())
    return files


def uploading_now():
    try:
        return any(n.startswith(".upload-") for n in os.listdir(IMPORT))
    except OSError:
        return False


def image_age_days(built):
    """Whole days since the image's packages were brought up to date, or None."""
    try:
        when = calendar.timegm(time.strptime(built, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None
    return max(0, int((time.time() - when) // 86400))


def build_status():
    info = read_kv(RUN + "/info")
    return {
        "state": first_line(RUN + "/status") or "starting-up",
        "message": read_text(RUN + "/message").rstrip("\n"),
        "last_error": read_text(RUN + "/last-error").strip(),
        "image_version": INSTALLER.get("FISHBOWL_VERSION", ""),
        "image_app_version": INSTALLER.get("FISHBOWL_APP_VERSION", ""),
        "installed_version": info.get("installed_version", ""),
        "install_type": info.get("install_type", ""),
        "database": info.get("database", ""),
        "client_port": info.get("client_port", "2456"),
        "upgrade_to": info.get("upgrade_to", ""),
        "upgrade_blocked": info.get("upgrade_blocked", ""),
        "volumes": info.get("volumes", "named"),
        # Decision 4: updates arrive with rebuilds; the page says when that has stalled.
        "image_built": info.get("image_built", ""),
        "image_age_days": image_age_days(info.get("image_built", "")),
        "image_max_age_days": int(info.get("image_max_age_days") or 14),
        # "image": MySQL's root password is the one this image sets. "own": the installation
        # was set up by an earlier version of this image with a password the person chose.
        # The password itself is never sent to a browser: Fishbowl fills it in by itself.
        "root_password_kind": info.get("root_password", ""),
        # answers handed over that the container has not picked up yet
        "requests": {name: os.path.exists(os.path.join(SPOOL, name)) for name in ("setup", "upgrade")},
        "pending_settings": os.path.exists(RUN + "/pending-settings"),
        "pending_database": first_line(RUN + "/pending-settings"),
        "sessions": {name: session_state(name) for name in SESSIONS},
        "imports": list_imports(),
    }


# ------------------------------------------------------- requests to root ---
def spool_write(name, lines=()):
    """Leave a request for the entrypoint: written under a hidden name, then
    renamed, so the entrypoint never sees half a file."""
    tmp = os.path.join(SPOOL, ".%s.%s" % (name, secrets.token_hex(8)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, SPOOL_MODE)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")
    os.rename(tmp, os.path.join(SPOOL, name))


def has_control(text):
    return any(ord(c) < 32 or ord(c) == 127 for c in text)


class Problem(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def check_eula(data):
    if data.get("eula_accepted") is not True:
        raise Problem(400, "Tick the box to accept Fishbowl's license agreement first.")
    _, digest = eula()
    if not digest or data.get("eula_sha256") != digest:
        raise Problem(409, "The license agreement on this page is out of date. Reload the page and read the one shown.")
    return digest


def setup_request(data):
    digest = check_eula(data)
    lines = ["fishbowl-answers 1", "kind=setup", "via=page", "eula=accepted", "eula_sha256=" + digest]
    license_kind = data.get("license")
    if license_kind == "trial":
        lines.append("license=trial")
    elif license_kind == "key":
        key = re.sub(r"\s+", "", str(data.get("key", "")))
        if len(key) < 5 or not all(c.isprintable() and not c.isspace() for c in key):
            raise Problem(400, "That doesn't look like a license key. Paste the whole key, or choose the trial.")
        company = str(data.get("company", "")).strip()
        if not company:
            raise Problem(400, "Enter the company name exactly as it appears on your Fishbowl license.")
        if has_control(company) or len(company) > 200:
            raise Problem(400, "The company name is too long or contains characters that can't be used.")
        lines += ["license=key", "key=" + key, "company=" + company]
    else:
        raise Problem(400, "Choose a license key or the 14 Day Trial.")
    return lines


def upgrade_request(data):
    digest = check_eula(data)
    # Only an installation made by an earlier version of this image has a password of
    # its own to give; everything else uses the image's password, and the container
    # fills that in when this one is empty.
    password = data.get("password", "")
    if not isinstance(password, str) or has_control(password):
        raise Problem(400, "That password contains characters that can't be used.")
    return ["fishbowl-answers 1", "kind=upgrade", "via=page", "eula=accepted", "eula_sha256=" + digest,
            "password=" + password]


def clean_upload_name(raw):
    """The name a file gets in the import folder: its last path part, with each
    run of anything but letters, digits, dot and dash turned into one underscore
    (Fishbowl's Restore tab suggests a database name from the file name)."""
    name = posixpath.basename(str(raw).replace("\\", "/"))
    name = re.sub(r"[^A-Za-z0-9.-]+", "_", name).lstrip("._")
    if not name:
        raise Problem(400, "That file needs a name.")
    if len(name) > 150:
        raise Problem(400, "That file name is too long; rename the file and try again.")
    return name


def check_upload_room(size):
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise Problem(400, "That file is empty.")
    try:
        st = os.statvfs(IMPORT)
    except OSError:
        raise Problem(503, "The import folder isn't ready yet. Try again in a moment.")
    free = st.f_bavail * st.f_frsize
    if size + 64 * 1024 * 1024 > free:
        raise Problem(507, "Not enough free disk space in Docker for this file: it is %d MB and %d MB are free."
                      % (size // (1024 * 1024) + 1, free // (1024 * 1024)))


# ------------------------------------------------------------------ handler
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 120   # seconds a connection may sit idle (also bounds a stalled upload)

    def log_message(self, fmt, *args):   # request lines can carry the access code: never log them
        pass

    def version_string(self):
        return "Fishbowl page"

    # ---- responses
    def send_bytes(self, status, body, ctype, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, status, obj, extra=None):
        self.send_bytes(status, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8", extra)

    def send_error_json(self, status, message):
        self.close_connection = True   # the request body may not have been read
        self.send_json(status, {"error": message})

    def redirect(self, location, extra=None):
        headers = {"Location": location}
        headers.update(extra or {})
        self.send_bytes(303, b"", "text/plain; charset=utf-8", headers)

    def send_file(self, root, rel):
        rel = posixpath.normpath("/" + rel).lstrip("/")
        root = os.path.realpath(root)
        full = os.path.realpath(os.path.join(root, rel))
        if not full.startswith(root + os.sep) or not os.path.isfile(full):
            return self.send_bytes(404, b"Not found\n", "text/plain; charset=utf-8")
        ctype = CONTENT_TYPES.get(os.path.splitext(full)[1].lower(), "application/octet-stream")
        with open(full, "rb") as f:
            body = f.read()
        self.send_bytes(200, body, ctype)

    def page(self, name, status=200, replace=None):
        body = read_text(os.path.join(WEB, name), 1024 * 1024)
        for k, v in (replace or {}).items():
            body = body.replace(k, v)
        self.send_bytes(status, body.encode("utf-8"), "text/html; charset=utf-8")

    # ---- who is asking
    def cookie_value(self):
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == COOKIE:
                return v
        return ""

    def authed(self):
        code = current_code()
        return bool(code) and hmac.compare_digest(self.cookie_value(), token_for(code))

    def secure_flag(self):
        """Behind the HTTPS edge (the Compose stack), the browser's connection is
        encrypted even though this hop isn't: the cookie then never travels over
        plain HTTP. Anyone who can send this header to the page directly is on
        this computer already, and could only make their own cookie stricter."""
        return "; Secure" if self.headers.get("X-Forwarded-Proto", "").lower() == "https" else ""

    def cookie_header(self, code):
        return "%s=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Lax%s" % (
            COOKIE, token_for(code), COOKIE_MAX_AGE, self.secure_flag())

    def same_origin(self):
        """Browsers send Origin on every request that can change something; it has
        to be this page. Programs without an Origin (curl) are fine: they can't
        be tricked by another website."""
        origin = self.headers.get("Origin")
        if not origin:
            return True
        return urllib.parse.urlsplit(origin).netloc == self.headers.get("Host", "")

    def may_change(self):
        """For everything that changes something: signed in, asked by this page."""
        if not self.authed():
            self.send_error_json(401, "Sign in first.")
            return False
        if self.headers.get("X-Fishbowl") != "1" or not self.same_origin():
            self.send_error_json(403, "This request did not come from the Fishbowl page.")
            return False
        return True

    def try_code(self, given):
        """Returns the access code if `given` is right, else None."""
        if LIMITER.blocked():
            return None
        code = current_code()
        if code and hmac.compare_digest(normalize_code(given), code):
            return code
        LIMITER.failed()
        log("a sign-in with a wrong access code was refused")
        return None

    def login_page(self, status=200, problem=""):
        if LIMITER.blocked():
            problem = "Too many wrong codes. Wait a minute, then try again."
        note = '<p class="error">%s</p>' % problem if problem else ""
        self.page("login.html", status, {"<!--PROBLEM-->": note})

    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            raise Problem(411, "Missing Content-Length.")
        if length < 0 or length > MAX_JSON:
            raise Problem(413, "That request is too large.")
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise Problem(400, "That request could not be read.")
        if not isinstance(data, dict):
            raise Problem(400, "That request could not be read.")
        return data

    # ---- GET
    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        path = url.path
        query = urllib.parse.parse_qs(url.query)

        if path.startswith("/static/"):
            return self.send_file(WEB, path[len("/static/"):])
        if "code" in query:
            # A link with ?code=... signs this browser in, then drops the code from the address bar.
            code = self.try_code(query["code"][0])
            if code:
                target = path if path in ("/", "/admin", "/client") else "/"
                return self.redirect(target, {"Set-Cookie": self.cookie_header(code)})
            return self.login_page(403, "That link's access code isn't valid (any more). Enter the current one.")
        if path == "/login":
            return self.redirect("/") if self.authed() else self.login_page()
        if path == "/favicon.ico":
            return self.send_file(WEB, "favicon.svg")

        if not self.authed():
            if path.startswith("/api/") or path.startswith("/ws/"):
                return self.send_json(401, {"error": "Sign in first."})
            return self.redirect("/login")

        if path == "/":
            return self.page("index.html")
        if path in ("/admin", "/client"):
            return self.page("view.html")
        if path == "/api/status":
            return self.send_json(200, build_status())
        if path == "/api/eula":
            name = (query.get("variant") or [""])[0]
            if name:
                if name not in eula_variants():
                    return self.send_json(404, {"error": "No such text."})
                return self.send_bytes(200, read_text(os.path.join(INSTALLER_DIR, "eula", name), 4 * 1024 * 1024).encode("utf-8"),
                                       "text/plain; charset=utf-8")
            text, digest = eula()
            return self.send_json(200, {"text": text, "sha256": digest, "file": os.path.basename(EULA_PATH),
                                        "variants": eula_variants()})
        if path.startswith("/novnc/"):
            return self.send_file(NOVNC, path[len("/novnc/"):])
        if path.startswith("/ws/"):
            return self.websocket(path[len("/ws/"):])
        return self.send_bytes(404, b"Not found\n", "text/plain; charset=utf-8")

    do_HEAD = do_GET

    # ---- POST
    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        try:
            if path == "/login":
                return self.post_login()
            if path == "/logout":
                self.close_connection = True
                return self.redirect("/login", {"Set-Cookie": "%s=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax%s" % (
                    COOKIE, self.secure_flag())})
            if not self.may_change():
                return None
            state = first_line(RUN + "/status")
            data = self.read_json()
            if path == "/api/setup":
                if state != "needs-setup":
                    raise Problem(409, "The container isn't waiting for first-time setup (any more). Reload the page.")
                spool_write("setup", setup_request(data))
                log("first-time setup answers handed to the container")
                return self.send_json(200, {"ok": True})
            if path == "/api/upgrade":
                info = read_kv(RUN + "/info")
                if not info.get("upgrade_to"):
                    raise Problem(409, "There is no upgrade waiting. Reload the page.")
                if state in ("upgrading", "setup"):
                    raise Problem(409, "An upgrade is already running.")
                spool_write("upgrade", upgrade_request(data))
                log("upgrade answers handed to the container")
                return self.send_json(200, {"ok": True})
            if path == "/api/imports-check":   # asked before an upload starts, so a refusal is cheap
                name = clean_upload_name(data.get("name", ""))
                check_upload_room(data.get("size"))
                return self.send_json(200, {"ok": True, "name": name})
            m = re.fullmatch(r"/api/session/(admin|client)/(open|close)", path)
            if m:
                return self.post_session(m.group(1), m.group(2), state, data)
            m = re.fullmatch(r"/api/server/(stop|start|restart)", path)
            if m:
                return self.post_server(m.group(1), state)
            raise Problem(404, "Not found.")
        except Problem as p:
            return self.send_error_json(p.status, p.message)
        except OSError:
            return self.send_error_json(503, "The container isn't taking requests right now. Try again in a moment.")

    def post_login(self):
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 4096)
        except ValueError:
            length = 0
        form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", errors="replace"))
        code = self.try_code((form.get("code") or [""])[0])
        if code:
            return self.redirect("/", {"Set-Cookie": self.cookie_header(code)})
        return self.login_page(403, "That access code isn't right.")

    def post_session(self, name, action, state, data):
        if action == "close":
            spool_write("close-" + name)
            return self.send_json(200, {"ok": True})
        allowed = ("running",) if name == "client" else ("awaiting-database", "starting", "running", "paused", "server-failed")
        if state not in allowed:
            if name == "client":
                raise Problem(409, "The Fishbowl Client needs Fishbowl Server running. See the Fishbowl page for what it is waiting for.")
            raise Problem(409, "Server Administration can't be opened right now. See the Fishbowl page for what the container is doing.")
        if session_state(name) == "closed":
            geometry = ""
            try:
                w, h = int(data.get("width", 0)), int(data.get("height", 0))
                if 800 <= w <= 3840 and 600 <= h <= 2160:
                    geometry = "%dx%d" % (w, h)
            except (TypeError, ValueError):
                pass
            spool_write("open-" + name, [geometry])
        return self.send_json(200, {"ok": True})

    def post_server(self, action, state):
        ok = {"stop": ("running",), "restart": ("running",), "start": ("paused", "server-failed")}[action]
        if state not in ok:
            raise Problem(409, "Fishbowl Server can't be asked to %s right now (it is: %s)." % (action, state))
        spool_write("server-" + action)
        log("Fishbowl Server %s requested on the page" % action)
        return self.send_json(200, {"ok": True})

    # ---- uploads into the import folder
    def do_PUT(self):
        path = urllib.parse.urlsplit(self.path).path
        if not self.may_change():
            return None
        try:
            if not path.startswith("/api/imports/"):
                raise Problem(404, "Not found.")
            name = clean_upload_name(urllib.parse.unquote(path[len("/api/imports/"):]))
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                raise Problem(411, "The upload has no size (Content-Length).")
            check_upload_room(length)
            if not UPLOAD_LOCK.acquire(blocking=False):
                raise Problem(409, "Another upload is still running. Wait for it to finish.")
            try:
                self.receive_upload(name, length)
            finally:
                UPLOAD_LOCK.release()
            log("uploaded %s (%d bytes) into the import folder" % (name, length))
            return self.send_json(200, {"ok": True, "name": name, "size": length})
        except Problem as p:
            return self.send_error_json(p.status, p.message)

    def receive_upload(self, name, length):
        part = os.path.join(IMPORT, ".upload-%s.part" % secrets.token_hex(8))
        try:
            fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        except OSError:
            raise Problem(503, "The import folder can't be written to right now.")
        done = False
        try:
            with os.fdopen(fd, "wb") as out:
                left = length
                while left > 0:
                    try:
                        chunk = self.rfile.read(min(CHUNK, left))
                    except OSError:
                        chunk = b""
                    if not chunk:
                        raise Problem(400, "The upload stopped before the whole file arrived.")
                    try:
                        out.write(chunk)
                    except OSError:
                        raise Problem(507, "Docker ran out of disk space while saving the file.")
                    left -= len(chunk)
                out.flush()
                os.fchmod(out.fileno(), 0o644)   # Server Administration (user fishbowl) must be able to read it
            os.rename(part, os.path.join(IMPORT, name))
            done = True
        finally:
            if not done:
                try:
                    os.unlink(part)
                except OSError:
                    pass

    def do_DELETE(self):
        path = urllib.parse.urlsplit(self.path).path
        if not self.may_change():
            return None
        try:
            if not path.startswith("/api/imports/"):
                raise Problem(404, "Not found.")
            name = posixpath.basename(urllib.parse.unquote(path[len("/api/imports/"):]))
            if not name or name.startswith(".") or name not in [f["name"] for f in list_imports()]:
                raise Problem(404, "No such file in the import folder.")
            try:
                os.unlink(os.path.join(IMPORT, name))
            except OSError:
                raise Problem(503, "That file can't be removed right now.")
            log("removed %s from the import folder" % name)
            return self.send_json(200, {"ok": True})
        except Problem as p:
            return self.send_error_json(p.status, p.message)

    # ---- the browser windows
    def websocket(self, name):
        """Pass the browser's WebSocket through to the window's websockify socket.
        The upgrade request is replayed as it came (minus the cookie), then bytes
        are copied both ways until either side closes."""
        self.close_connection = True
        if name not in SESSIONS or self.headers.get("Upgrade", "").lower() != "websocket":
            return self.send_bytes(400, b"Not a WebSocket request\n", "text/plain; charset=utf-8")
        if not self.same_origin():
            return self.send_bytes(403, b"Wrong origin\n", "text/plain; charset=utf-8")
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            upstream.connect("%s/ws/%s.sock" % (RUN, name))
        except OSError:
            upstream.close()
            return self.send_bytes(503, b"That window is not open\n", "text/plain; charset=utf-8")
        try:
            head = ["GET /websockify HTTP/1.1"]
            for key, value in self.headers.items():
                if key.lower() not in ("cookie", "authorization"):
                    head.append("%s: %s" % (key, value))
            upstream.sendall(("\r\n".join(head) + "\r\n\r\n").encode("latin-1"))
            client = self.connection
            client.settimeout(None)
            pair = {client: upstream, upstream: client}
            while True:
                readable, _, broken = select.select([client, upstream], [], [client, upstream], 300)
                if broken:
                    break
                closed = False
                for sock in readable:
                    try:
                        data = sock.recv(65536)
                    except OSError:
                        data = b""
                    if not data:
                        closed = True
                        break
                    pair[sock].sendall(data)
                if closed:
                    break
        except OSError:
            pass
        finally:
            upstream.close()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def handle_error(self, request, client_address):
        """A browser (or a health check) that hangs up in the middle of an answer
        is routine, so it leaves nothing in the log; anything else leaves one
        timestamped line instead of a multi-line traceback."""
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, TimeoutError, socket.timeout)):
            return
        log("error while answering a request: %s: %s" % (type(exc).__name__, exc))


def main():
    server = Server(("0.0.0.0", PORT), Handler)
    log("serving on port %d" % PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
