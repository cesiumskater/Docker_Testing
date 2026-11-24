#!/usr/bin/env python3
"""The acceptance checks that need a running container. Started by run-checks.sh.

    scenarios.py runtime --image IMG --password PW --port 47010 --work DIR
    scenarios.py update --image IMG --password PW --port 47010 --work DIR
    scenarios.py upgrade --image IMG --next NEWER_IMG --password PW --port 47010 --work DIR
    scenarios.py reference --image IMG --reference-sql BACKUP.sql --password PW --port 47010 --work DIR

Every check prints one line, "PASS  name" or "FAIL  name   [why]", and the run
goes on after a failure where it can. Test containers and volumes are named
fbcheck-*. Fishbowl's license agreement is accepted here on your behalf, in
throwaway trial installations: run the checks only if that is acceptable to you.
"""
import argparse
import hashlib
import os
import re
import shlex
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gui import (CHOOSER_FILE_NAME, CHOOSER_OPEN, RESTORE_BUTTON, RESTORE_MAGNIFIER,  # noqa: E402
                 RESTORE_PASSWORD, RESTORE_YES, RESTORED_OK, TAB_RESTORE, Gui, start_bridge)
from page import Page, PageError, access_code      # noqa: E402
from pty_session import Session                    # noqa: E402

FAILED = []
# Extra `docker run` arguments for every container that runs the image's entrypoint, e.g. the
# hardened set the README uses (read-only root, tmpfs, dropped capabilities). Tests E2 and E5.
RUN_ARGS = shlex.split(os.environ.get("FBCHECK_RUN_ARGS", ""))


def report(name, ok, detail=""):
    line = ("PASS  " if ok else "FAIL  ") + name
    if not ok and detail:
        line += "   [" + " ".join(str(detail).split())[:300] + "]"
    print(line, flush=True)
    if not ok:
        FAILED.append(name)
    return ok


def check(name, fn):
    """Run one check. It passes when fn returns without raising and doesn't return False."""
    try:
        result = fn()
        return report(name, result is not False, "" if result is not False else "returned False")
    except Exception as e:   # noqa: BLE001 - a failed check must not stop the others
        return report(name, False, f"{type(e).__name__}: {e}")


def expect(cond, why=""):
    if not cond:
        raise AssertionError(why or "condition not met")


def sh(*args, **kw):
    return subprocess.run(list(args), capture_output=True, text=True, **kw)


class Box:
    """One test container and its three volumes."""

    def __init__(self, name, image, port, password, work):
        self.name, self.image, self.port, self.password, self.work = name, image, port, password, work
        self._page = None

    @property
    def volume_args(self):
        return ["-v", f"{self.name}-mysql:/var/lib/mysql", "-v", f"{self.name}-app:/opt/Fishbowl",
                "-v", f"{self.name}-data:/var/lib/fishbowl"]

    def create_volumes(self):
        for part in ("mysql", "app", "data"):
            sh("docker", "volume", "create", f"{self.name}-{part}")

    def run(self, image=None, env=(), command=(), hardened=True):
        """Start it the way the README does: detached, no terminal (and FBCHECK_RUN_ARGS unless hardened=False)."""
        args = ["docker", "run", "-d", "--name", self.name, "--stop-timeout", "180", *(RUN_ARGS if hardened else ()),
                "-p", f"127.0.0.1:{self.port}:2456", "-p", f"127.0.0.1:{self.port + 1}:6080",
                "-p", f"127.0.0.1:{self.port + 2}:5999", "-p", f"127.0.0.1:{self.port + 3}:5998",
                "-p", f"127.0.0.1:{self.port + 4}:28192"]
        for e in env:
            args += ["-e", e]
        if not any(e.startswith("FISHBOWL_AUTO_UPDATE=") for e in env):
            args += ["-e", "FISHBOWL_AUTO_UPDATE=0"]   # the "update" checks turn it on; the others must not wait on dnf
        if not any(e.startswith("FISHBOWL_NETCHECK_DELAY=") for e in env):
            args += ["-e", "FISHBOWL_NETCHECK_DELAY=5"]   # the start-up network check, soon enough to look for it
        r = sh(*args, *self.volume_args, image or self.image, *command)
        expect(r.returncode == 0, "docker run failed: " + r.stderr.strip())
        self._page = None

    def remove(self, grace=180):
        sh("docker", "stop", "-t", str(grace), self.name)
        sh("docker", "rm", "-f", self.name)
        self._page = None

    def exec(self, *cmd, user=None, env=()):
        args = ["docker", "exec"]
        if user:
            args += ["-u", user]
        for e in env:
            args += ["-e", e]
        return sh(*args, self.name, *cmd)

    def helper(self, script):
        """Run a shell snippet in a throwaway container on the same volumes (for a stopped test container)."""
        return sh("docker", "run", "--rm", "--entrypoint", "sh", *self.volume_args, self.image, "-c", script)

    def state(self):
        return self.exec("cat", "/run/fishbowl/status").stdout.strip()

    def is_up(self):
        return sh("docker", "inspect", "-f", "{{.State.Running}}", self.name).stdout.strip() == "true"

    def wait_state(self, states, timeout=300):
        states = (states,) if isinstance(states, str) else tuple(states)
        deadline = time.time() + timeout
        last = ""
        while time.time() < deadline:
            last = self.state()
            if last in states:
                return last
            time.sleep(2)
        raise TimeoutError(f"{self.name} stayed '{last}' (wanted {states}) for {timeout}s")

    def sql(self, statement):
        r = self.exec("mysql", "--protocol=tcp", "-h127.0.0.1", "-uroot", "-N", "-B", "-e", statement,
                      env=["MYSQL_PWD=" + self.password])
        return r.stdout.strip()

    def tables(self, database):
        try:
            return int(self.sql(f"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='{database}'") or 0)
        except ValueError:
            return 0

    def logs(self, since=None):
        args = ["docker", "logs"] + (["--since", since] if since else []) + [self.name]
        r = sh(*args)
        return r.stdout + r.stderr

    def page(self):
        if self._page is None:
            p = Page(f"http://127.0.0.1:{self.port + 1}")
            expect(p.sign_in(access_code(self.name)), "the access code from fishbowl-link did not open the page")
            self._page = p
        return self._page

    def gui(self, label):
        return Gui(f"127.0.0.1::{self.port + 2}", os.path.join(self.work, "shots-" + label))

    def client_port_open(self):
        """Does Fishbowl Server answer on the published client port? (Docker's port
        forwarding accepts connections even when nothing listens behind it, so this
        asks for a page: Fishbowl Server speaks HTTP on that port.)"""
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
                s.sendall(b"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
                return s.recv(16).startswith(b"HTTP/")
        except OSError:
            return False

    def api_port_open(self):
        """Does Fishbowl Server listen behind the published API port (28192)? It waits
        for a request instead of answering a bare connection, so a connection that
        stays open means something listens; Docker closes it at once when nothing does."""
        try:
            with socket.create_connection(("127.0.0.1", self.port + 4), timeout=5) as s:
                s.settimeout(3)
                try:
                    return s.recv(1) != b""
                except socket.timeout:
                    return True
        except OSError:
            return False

    def installed_version(self):
        return self.exec("cat", "/var/lib/fishbowl/state/installed-version").stdout.strip()


def fishbowl_setup_answer(box, answer):
    """Run fishbowl-setup at a terminal up to the license question and give `answer` (None = end of input)."""
    s = Session(["docker", "exec", "-it", box.name, "fishbowl-setup"], os.devnull)
    s.expect(r"Press Enter to open the license agreement", 60)
    s.sendline()
    s.expect(r"q when done", 30)
    s.send("q")
    s.expect(r'Type "yes" to accept: ', 30)
    if answer is None:
        s.send(b"\x04")
    else:
        s.sendline(answer)
    return s.wait_exit(60)


def screen_is_drawn(box, vnc_port, path):
    """True when the window's screen shows more than a blank background."""
    from PIL import Image
    exe = os.environ.get("VNCDO", "vncdo")
    subprocess.run([exe, "-s", f"127.0.0.1::{vnc_port}", "capture", path], check=True, timeout=120,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    colors = Image.open(path).convert("RGB").getcolors(maxcolors=1 << 20)
    return colors is None or len(colors) > 50


# ------------------------------------------------------------------ runtime --
def runtime(a):
    pw = a.password
    box = Box("fbcheck-a", a.image, a.port, pw, a.work)
    box.create_volumes()

    # -- a container started with nothing but the image (what Docker Desktop's Run button does)
    bare = "fbcheck-bare"
    sh("docker", "run", "-d", "--name", bare, *RUN_ARGS, a.image)

    def bare_state():
        for _ in range(45):
            if sh("docker", "exec", bare, "cat", "/run/fishbowl/status").stdout.strip() == "needs-setup":
                return True
            time.sleep(2)
        return False
    check("start with no volumes and no terminal: stays up and waits for setup", bare_state)
    check("  ...and says its volumes are unnamed, in the log and to the page", lambda: expect(
        "without named volumes" in (sh("docker", "logs", bare).stdout) and
        "volumes=unnamed" in sh("docker", "exec", bare, "cat", "/run/fishbowl/info").stdout))
    sh("docker", "rm", "-f", "-v", bare)

    # -- an image whose packages haven't been brought up to date for a while (decision 4)
    def stale_image():
        import tempfile
        old = "fbcheck-old"
        stamp = os.path.join(tempfile.mkdtemp(prefix="fbcheck-"), "image-built")
        with open(stamp, "w") as f:
            f.write("2026-01-01T00:00:00Z\n")
        sh("docker", "run", "-d", "--name", old, *RUN_ARGS, "-v", f"{stamp}:/usr/local/share/fishbowl/image-built:ro", a.image)
        try:
            logs = ""
            for _ in range(40):
                r = sh("docker", "logs", old)
                logs = r.stdout + r.stderr
                if "system packages are" in logs:
                    break
                time.sleep(3)
            expect(re.search(r"system packages are \d+ days old", logs), "no warning in the log: " + logs[-300:])
            r = sh("docker", "exec", old, "python3", "-I", "-c",
                   "import sys; sys.path.insert(0, '/usr/local/lib/fishbowl'); import portal; "
                   "s = portal.build_status(); print(s['image_age_days'], s['image_max_age_days'])")
            age, most = (int(x) for x in r.stdout.split())
            expect(age > most == 14, f"the page's data: {r.stdout!r} {r.stderr[-200:]}")
        finally:
            sh("docker", "rm", "-f", "-v", old)
    check("an image not rebuilt for over 14 days: the log warns, and the page gets its age to show the warning",
          stale_image)

    # -- first start on named volumes, detached
    box.run()
    check("first start without a terminal: container stays up, waiting for setup",
          lambda: expect(box.wait_state("needs-setup", 90) and box.is_up()))
    check("the log gives the link to the Fishbowl page",
          lambda: expect(re.search(r"http://localhost:6080/\?code=[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}", box.logs())))

    anon = Page(f"http://127.0.0.1:{box.port + 1}")

    def protected():
        expect(anon.request("GET", "/")[0] == 303, "/ should redirect to the sign-in page")
        expect(anon.request("GET", "/api/status")[0] == 401, "/api/status should need the access code")
        expect(anon.request("GET", "/novnc/core/rfb.js")[0] == 303, "the viewer's files should need the access code")
        expect(anon.request("GET", "/?code=AAAA-BBBB-CCCC")[0] == 403, "a wrong code should be refused")
    check("the page needs its access code", protected)
    page = None

    def signed_in():
        nonlocal page
        page = box.page()
        expect(page.status()["state"] == "needs-setup")
    check("the link from fishbowl-link opens the page", signed_in)
    if page is None:
        return

    def eula_matches():
        e = page.eula()
        inside = box.exec("bash", "-c", '. /opt/fishbowl-installer/installer.env; sha256sum "$FISHBOWL_EULA"').stdout.split()[0]
        expect(e["sha256"] == inside and hashlib.sha256(e["text"].encode()).hexdigest() == inside,
               "the page's license text differs from the installer's")
        expect(len(e["text"]) > 1000)
    check("the page shows the license agreement the installer carries", eula_matches)

    def refused(status, **kw):
        try:
            page.setup(**kw)
        except PageError as e:
            expect(e.status == status, f"got {e.status}: {e.message}")
            return
        raise AssertionError("the setup form was accepted")
    check("setup form: license agreement not accepted -> refused", lambda: refused(400, accept=False))
    check("setup form: accepting a different text than the image's -> refused", lambda: refused(409, eula_sha256="0" * 64))
    check("fishbowl-setup: end of input is not acceptance (exit 3)", lambda: expect(fishbowl_setup_answer(box, None) == 3))
    check("fishbowl-setup: 'no' declines (exit 1)", lambda: expect(fishbowl_setup_answer(box, "no") == 1))
    check("fishbowl-setup: 'y' is not 'yes' (exit 1)", lambda: expect(fishbowl_setup_answer(box, "y") == 1))
    time.sleep(3)
    check("nothing accepted -> nothing installed", lambda: expect(
        box.exec("sh", "-c", "find /var/lib/mysql /opt/Fishbowl -mindepth 1 | wc -l").stdout.strip() == "0"
        and box.state() == "needs-setup"))

    # -- setup on the page (trial), then the database in Server Administration
    t0 = time.time()

    def setup_on_page():
        tz = page.status().get("time_zone") or {}
        expect(tz.get("name") == "UTC" and tz.get("offset_minutes") == 0, f"the form offers the container's zone as {tz}")
        page.setup(timezone=5)   # GMT +5 from the form's list (the container itself runs on UTC)
        st = page.wait_state("awaiting-database", 900)
        expect(st["install_type"] == "trial" and st["installed_version"] == st["image_version"])
    ok = check("setup on the page: license agreement, trial and time zone (GMT +5), no password to choose -> installed, waiting for a database", setup_on_page)
    print(f"      (install took {time.time() - t0:.0f}s)", flush=True)
    if not ok:
        return
    check("the acceptance is on record, with how it was given", lambda: expect(
        "Fishbowl page" in box.exec("sh", "-c", "cat /var/lib/fishbowl/state/eula/accepted-*").stdout))

    def time_zone_chosen():
        saved = box.exec("cat", "/var/lib/fishbowl/state/timezone").stdout.strip()
        expect(saved == "Etc/GMT-5", f"saved as {saved!r}")
        diff = box.sql("SELECT TIMEDIFF(NOW(), UTC_TIMESTAMP())")
        expect(diff == "05:00:00", f"MySQL's clock is {diff} from UTC")
        expect("Time zone: GMT +5" in box.logs(), "the log doesn't name the time zone")
    check("the time zone chosen at setup (GMT +5) is saved, MySQL runs on it, and the log says so", time_zone_chosen)

    def starts_with_no_database():
        st = page.status()
        expect(st.get("database", "") == "", f"a database is already selected: {st.get('database')!r}")
        extra = schemas(box)
        expect(not extra, f"MySQL already holds databases: {sorted(extra)}")
        expect(st.get("imports") == [], f"the import folder isn't empty: {st.get('imports')}")
    check("a new installation starts with no database: MySQL holds only its own system databases, "
          "none is selected, the import folder is empty", starts_with_no_database)

    def create_database():
        page.open_window("admin")
        start_bridge(box.name)
        g = box.gui("create")
        g.locate()
        g.create_database("fbcheck", None, box.tables)   # Password left as Fishbowl filled it in
        g.select_database(0)
        page.wait_window_closed("admin", 120)
        st = page.wait_state("running", 600)
        expect(st["database"] == "fbcheck", f"database is {st['database']!r}")
    ok = check("Server Administration in its browser window: create a database, Password left as Fishbowl filled it in -> Fishbowl Server starts by itself", create_database)
    if not ok:
        return

    def server_time_zone():
        r = box.exec("sh", "-c", "for p in $(pgrep -u fishbowl java); do tr '\\0' '\\n' < /proc/$p/environ | grep '^TZ='; done | sort -u",
                     user="fishbowl")
        expect(r.stdout.strip() == "TZ=Etc/GMT-5", f"Fishbowl's Java runs with {r.stdout.strip() or 'no TZ'} {r.stderr.strip()}")
    check("Fishbowl Server runs in the time zone chosen at setup (TZ=Etc/GMT-5)", server_time_zone)

    out = box.sql("SELECT VERSION(), @@lower_case_table_names")
    check("MySQL reports 8.4.x", lambda: expect(out.startswith("8.4."), out))
    check("lower_case_table_names = 1", lambda: expect(out.split("\t")[-1] == "1", out))

    def heap():
        r = box.exec("bash", "-c", '/usr/lib/jvm/temurin-21-jdk/bin/jcmd "$(pgrep -u fishbowl -o -f com\\\\.evnt\\\\.eve\\\\.Eve)" VM.flags',
                     user="fishbowl")
        m = re.search(r"-XX:MaxHeapSize=(\d+)", r.stdout)
        expect(m and int(m.group(1)) == 8192 * 1024 * 1024, r.stdout[-200:] + r.stderr[-200:])
    check("Fishbowl Server heap is 8192 MB", heap)
    check("client launchers set 2048 MB", lambda: expect(
        box.exec("grep", "-qx", "--", "-Xmx2048M", "/opt/Fishbowl/client/bin/Fishbowl Client.vmoptions").returncode == 0))
    check("Fishbowl Server runs as non-root user 'fishbowl'", lambda: expect(
        box.exec("bash", "-c", "ps -o user= -C java | sort -u").stdout.split() == ["fishbowl"]))
    check("the page's web server runs as its own non-root user", lambda: expect(
        box.exec("bash", "-c", "ps -o user= -p \"$(pgrep -f portal.py | head -n 1)\"").stdout.strip() == "fbweb"))
    check("Fishbowl Clients can reach the published port", lambda: expect(box.client_port_open()))
    check("Fishbowl's API port (28192, integrated apps and integrations) listens behind its published port",
          lambda: expect(box.api_port_open()))

    def netcheck():
        r = box.exec("fishbowl-netcheck")
        out = r.stdout
        expect(r.returncode in (0, 1), f"exit {r.returncode}: {r.stderr[-300:]}")
        for want in ("fishbowlconnect.com:81", "artanis.fishbowldev.com:443", "Listening for the network",
                     "MySQL (3306) doesn't listen for the network"):
            expect(want in out, f"{want!r} missing from the report")
        expect("97.75.181" not in out and "199.79.55" not in out,
               "the cutsheet's addresses are no longer part of the allowlist (decision 1)")
        listening = out.split("Listening for the network", 1)[1]
        expect(re.search(r"^  2456 ", listening, re.M) and re.search(r"^  28192 ", listening, re.M),
               "2456 and 28192 should be listed as listening")
        expect(not re.search(r"^  3306 ", listening, re.M), "MySQL must not listen for the network")
        # 5998 and 5999 are these checks' own VNC bridge (tests/lib/vnc_bridge.py), not part of the image.
        harness = {"5998", "5999"}
        flagged = set(re.findall(r"^  (\d+) +NOT ALLOWED", out, re.M))
        expect(not flagged - harness, f"only 2456, 28192 and 6080 may listen for the network, not {sorted(flagged - harness)}")
        blocked = "Result: not reachable" in out
        expect(r.returncode == (1 if blocked or flagged else 0), f"exit {r.returncode}, blocked {blocked}, flagged {sorted(flagged)}")
        # The check at start-up said the same thing in the log: a warning exactly when something is blocked.
        warned = "Fishbowl's servers can't be reached from this container" in box.logs()
        expect(warned == blocked, f"blocked: {blocked}, warning in the log: {warned}")
        # Decision 2: anything else that listens for the network is reported and fails the check.
        probe = ("python3 -I -c 'import socket, time; s = socket.socket(); "
                 "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((\"0.0.0.0\", 8080)); "
                 "s.listen(); time.sleep(30)' & sleep 1; fishbowl-netcheck; echo \"rc=$?\"; kill $!")
        r2 = box.exec("bash", "-c", probe)
        expect(re.search(r"^  8080 +NOT ALLOWED", r2.stdout, re.M) and "rc=1" in r2.stdout,
               "a listener on 8080 must be flagged and fail the check:\n" + r2.stdout[-500:])
        # Only this Fishbowl's own pair: another Fishbowl's (2457 and 28193) is flagged too.
        code = ("import socket, time\nls = []\nfor p in (2457, 28193):\n    s = socket.socket()\n"
                "    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n    s.bind((\"0.0.0.0\", p))\n"
                "    s.listen()\n    ls.append(s)\ntime.sleep(30)\n")
        r3 = box.exec("bash", "-c", f"python3 -I -c '{code}' & sleep 1; fishbowl-netcheck; echo \"rc=$?\"; kill $!")
        expect(re.search(r"^  2457 +NOT ALLOWED", r3.stdout, re.M) and re.search(r"^  28193 +NOT ALLOWED", r3.stdout, re.M)
               and "rc=1" in r3.stdout,
               "listeners on another Fishbowl's ports (2457, 28193) must be flagged:\n" + r3.stdout[-600:])
    check("fishbowl-netcheck reports Fishbowl's servers and what listens; the log warns exactly when one is blocked",
          netcheck)

    def healthy():
        for _ in range(40):
            if sh("docker", "inspect", "-f", "{{.State.Health.Status}}", box.name).stdout.strip() == "healthy":
                return True
            time.sleep(3)
        return False
    check("Docker reports the container healthy", healthy)

    key = box.exec("python3", "-I", "/usr/local/lib/fishbowl/props.py", "get", "/opt/Fishbowl/server/bin/eve.properties", "licenseKey").stdout.strip()
    def password_never_shown():
        st = page.status()
        expect(st.get("root_password_kind") == "image" and "mysql_root_password" not in st, str(st))
        # nothing the page serves to a signed-in browser contains it either
        for p in ("/", "/admin", "/client", "/api/status", "/static/app.js", "/static/view.js",
                  "/static/index.html", "/static/view.html"):
            body = page.get_text(p)
            expect(len(body) > 100 and pw not in body, p + " is empty or contains the MySQL password")
        expect(box.sql("SELECT 1") == "1")
    check("the MySQL password is never shown on the page or sent to the browser, and MySQL accepts it", password_never_shown)
    check("MySQL password not in docker logs", lambda: expect(pw not in box.logs()))
    check("license key not in docker logs", lambda: expect(not key or key not in box.logs()))
    # Fishbowl's own installer lists this same password (variable mysql8Password in
    # /opt/Fishbowl/.install4j/i4jparams.conf), so that folder is left out.
    check("MySQL password not written into the volumes, /etc, /root or /tmp by this image", lambda: expect(
        box.exec("grep", "-rlaF", "--exclude-dir=.install4j", "--", pw, "/var/lib/fishbowl", "/opt/Fishbowl", "/etc", "/root", "/tmp", "/run", "/dev/shm").stdout.strip() == ""))
    check("a second container on the same volumes is refused", lambda: expect(
        sh("timeout", "60", "docker", "run", "--rm", *RUN_ARGS, *box.volume_args, box.image).returncode == 6))

    # -- the Client in its own window
    def client_window():
        page.open_window("client", 1280, 800)
        time.sleep(45)   # the first start unpacks the Client's built-in web view
        expect(screen_is_drawn(box, box.port + 3, os.path.join(a.work, "client-window.png")), "the Client's screen is blank")
        expect(page.status()["sessions"] == {"admin": "closed", "client": "ready"})
        page.close_window("client")
        page.wait_window_closed("client", 60)
    check("the Fishbowl Client opens in its own browser window", client_window)

    # -- buttons on the page, and things going wrong
    def stop_start():
        page.server("stop")
        page.wait_state("paused", 120)
        expect(not box.client_port_open(), "port 2456 still answers after Stop")
        expect(box.sql("SELECT 1") == "1", "MySQL should keep running while Fishbowl Server is stopped")
        page.server("start")
        page.wait_state("running", 300)
    check("Stop and Start on the page", stop_start)

    def foreign_requests():
        p2 = Page(f"http://127.0.0.1:{box.port + 1}")
        expect(p2.request("POST", "/api/server/stop", b"{}", {"X-Fishbowl": "1", "Content-Type": "application/json"})[0] == 401)
        cookie = "; ".join(f"{c.name}={c.value}" for c in page.jar)
        expect(p2.request("POST", "/api/server/stop", b"{}", {"Cookie": cookie, "Content-Type": "application/json"})[0] == 403,
               "a request without the page's own header should be refused")
        expect(p2.request("POST", "/api/server/stop", b"{}", {"Cookie": cookie, "X-Fishbowl": "1", "Origin": "http://elsewhere.example",
                                                             "Content-Type": "application/json"})[0] == 403)
        expect(page.status()["state"] == "running")
    check("requests that don't come from the page are refused", foreign_requests)

    def restarts():
        return sh("docker", "inspect", "-f", "{{.RestartCount}}", box.name).stdout.strip()

    def kill_server():
        box.exec("bash", "-c", 'kill -9 "$(pgrep -u fishbowl -o -f com\\\\.evnt\\\\.eve\\\\.Eve)"')
        time.sleep(8)
        box.wait_state("running", 300)
        expect(box.is_up() and "Starting Fishbowl Server again" in box.logs())
    check("Fishbowl Server killed -> started again in place", kill_server)

    def kill_mysql():
        box.exec("pkill", "-9", "-x", "mysqld")
        time.sleep(8)
        box.wait_state("running", 300)
        expect(box.is_up() and box.sql("SELECT 1") == "1" and "Starting MySQL again" in box.logs())
    check("MySQL killed -> both started again in place", kill_mysql)

    # -- data survives a new container; an unclean stop doesn't block the next start
    box.sql("CREATE TABLE IF NOT EXISTS fbcheck.zz_fbcheck_marker (id INT PRIMARY KEY, v VARCHAR(40)); "
            "REPLACE INTO fbcheck.zz_fbcheck_marker VALUES (1,'kept');")
    before = box.sql("SELECT v FROM fbcheck.zz_fbcheck_marker; CHECKSUM TABLE fbcheck.part, fbcheck.sysuser;")
    box.remove()
    box.run()

    def recreated():
        box.wait_state("running", 300)
        expect("license agreement" not in box.logs().lower().replace("license agreement for", ""), "it asked about the license agreement again")
        expect(box.sql("SELECT v FROM fbcheck.zz_fbcheck_marker; CHECKSUM TABLE fbcheck.part, fbcheck.sysuser;") == before, "data differs")
    check("a new container on the same volumes starts by itself and keeps the data", recreated)
    page = box.page()

    def unclean_stop():
        # MySQL's socket lock file keeps the old process number. Make it name a thread
        # of the next mysqld (the numbers repeat from start to start), which made MySQL
        # refuse to start before the container removed stale lock files.
        pid = box.exec("pgrep", "-x", "mysqld").stdout.split()[0]
        tids = box.exec("ls", f"/proc/{pid}/task").stdout.split()
        victim = tids[min(4, len(tids) - 1)]
        sh("docker", "kill", box.name)
        time.sleep(2)
        box.helper(f"echo {victim} > /var/lib/mysql/mysql.sock.lock")
        mark = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
        sh("docker", "start", box.name)
        box.wait_state("running", 400)
        expect("Another process with pid" not in box.logs(since=mark + "Z"), "MySQL tripped over the stale lock file")
        expect(box.sql("SELECT v FROM fbcheck.zz_fbcheck_marker") == "kept")
    check("killed without a clean shutdown (stale MySQL lock file) -> next start works", unclean_stop)
    page = box.page()

    # -- a .sql backup: upload on the page, restore in the Restore tab, switch to it
    dump = os.path.join(a.work, "fbrestored_2026-01-01.sql")
    with open(dump, "w") as f:
        r = subprocess.run(["docker", "exec", "-e", "MYSQL_PWD=" + pw, box.name, "mysqldump", "--protocol=tcp", "-h127.0.0.1",
                            "-uroot", "--single-transaction", "--routines", "--triggers", "--set-gtid-purged=OFF", "fbcheck"],
                           stdout=f, stderr=subprocess.PIPE, text=True)
    box.sql("UPDATE fbcheck.zz_fbcheck_marker SET v='changed after the backup' WHERE id=1;")

    def upload():
        expect(r.returncode == 0 and os.path.getsize(dump) > 100000, "mysqldump failed: " + r.stderr[-200:])
        stored = page.upload(dump)
        files = {f["name"]: f["size"] for f in page.status()["imports"]}
        expect(files.get(stored) == os.path.getsize(dump), f"import folder has {files}")
        # any file type can be uploaded (reports, spreadsheets, images ...), and nothing is read from it
        for other in ("notes.txt", "ReorderReport.jasper", "archive.tar.gz"):
            stored2 = page.upload(dump, other)
            expect(stored2 == other, f"{other} was stored as {stored2}")
        names = {f["name"] for f in page.status()["imports"]}
        expect({"notes.txt", "ReorderReport.jasper", "archive.tar.gz"} <= names, str(names))
        for other in ("notes.txt", "ReorderReport.jasper", "archive.tar.gz"):
            box.exec("rm", "-f", "/var/lib/fishbowl/import/" + other)
    ok = check("upload a .sql backup on the page, and files of other types are accepted too", upload)

    def restore_in_gui():
        page.open_window("admin")
        start_bridge(box.name)
        g = box.gui("restore")
        g.locate()
        g.restore("/var/lib/fishbowl/import/" + os.path.basename(dump), "fbrestored", None, box.tables)
        expect(box.sql("SELECT v FROM fbrestored.zz_fbcheck_marker") == "kept", "the restored database lacks the backup's data")
        g.select_database(1)     # the list is sorted by name: fbcheck, fbrestored
        page.wait_window_closed("admin", 120)
        st = page.status()
        expect(st["pending_settings"] and st["pending_database"] == "fbrestored" and st["database"] == "fbcheck",
               f"pending={st['pending_settings']} pending_database={st['pending_database']!r} database={st['database']!r}")
    if ok:
        ok = check("Restore tab: restore the upload into a new database, Password left as Fishbowl filled it in, and select it (takes effect at the restart)", restore_in_gui)

    def restart_on_page():
        page.server("restart")
        time.sleep(5)
        st = page.wait_state("running", 300)
        expect(st["database"] == "fbrestored" and not st["pending_settings"], f"database is {st['database']!r}")
        expect(box.sql("SELECT v FROM fbcheck.zz_fbcheck_marker") == "changed after the backup", "the other database was touched")
    if ok:
        check("Restart on the page -> Fishbowl Server runs on the restored database", restart_on_page)

    # -- backup of everything, and the restore command
    def backup():
        s = Session(["docker", "exec", "-it", box.name, "fishbowl-backup"], os.devnull)
        path = s.expect(r"Backup written: (\S+)", 600).group(1).decode()
        s.wait_exit(30)
        expect(path.startswith("/var/lib/fishbowl/backups/"))
        return path
    backup_path = None

    def do_backup():
        nonlocal backup_path
        backup_path = backup()
    check("fishbowl-backup writes a backup", do_backup)

    def unattended_backup():
        paths = []
        for _ in range(3):
            r = box.exec("fishbowl-backup", "--label", "fbcheck-auto", "--keep", "2")
            expect(r.returncode == 0, r.stdout[-300:] + r.stderr[-300:])
            paths.append(r.stdout.strip().splitlines()[-1])
            time.sleep(1.1)   # the name carries the time to the second
        left = box.exec("bash", "-c", "ls -1 /var/lib/fishbowl/backups/fbcheck-auto-*.sql.gz").stdout.split()
        expect(sorted(left) == sorted(paths[1:]), f"kept {left}, wrote {paths}")
        box.exec("bash", "-c", "rm -f /var/lib/fishbowl/backups/fbcheck-auto-*.sql.gz")
    check("fishbowl-backup without a terminal (the weekly maintenance): the image's password, the newest N kept",
          unattended_backup)

    def restore_command():
        box.sql("UPDATE fbrestored.zz_fbcheck_marker SET v='changed' WHERE id=1;")
        box.remove()
        s = Session(["docker", "run", "-it", "--rm", *RUN_ARGS, *box.volume_args, box.image, "restore", backup_path], os.devnull)
        s.expect(r'Type "restore" to continue: ', 60)
        s.sendline("restore")
        s.expect(r"Restore finished", 900)
        expect(s.wait_exit(180) == 0)
        box.run()
        box.wait_state("running", 400)
        expect(box.sql("SELECT v FROM fbrestored.zz_fbcheck_marker") == "kept")
    if backup_path:
        check("the restore command brings back the backed-up data", restore_command)

    def new_code():
        old = box.page()
        r = box.exec("fishbowl-link", "--new-code")
        expect(r.returncode == 0)
        expect(old.request("GET", "/api/status")[0] == 401, "the old sign-in still works")
        box._page = None
        expect(box.page().status()["state"] == "running")
    check("fishbowl-link --new-code signs every browser out", new_code)

    # -- an installation from an earlier version of this image, which let its owner choose a password
    def earlier_installation():
        own = "Own!pass123x"
        box.sql(f"ALTER USER 'root'@'localhost' IDENTIFIED BY '{own}'")
        box.password = own
        box.remove()
        box.helper("rm -f /var/lib/fishbowl/state/mysql-root-password")
        box.run()
        deadline = time.time() + 300
        st = {}
        while time.time() < deadline:
            try:
                st = box.page().status()
                if st.get("root_password_kind"):
                    break
            except Exception:
                pass
            time.sleep(3)
        expect(st.get("root_password_kind") == "own" and "mysql_root_password" not in st, str(st))
        r = box.exec("fishbowl-backup", "--label", "fbcheck-auto")
        expect(r.returncode == 3 and "password of its own" in r.stdout + r.stderr,
               f"without a terminal it must stop with 3: {r.returncode} {r.stderr[-200:]}")
        s = Session(["docker", "exec", "-it", box.name, "fishbowl-backup"], os.devnull)
        s.expect(r"MySQL root password: ", 120)
        s.sendline(own)
        s.expect(r"Backup written: (\S+)", 600)
        s.wait_exit(30)
        # Put it back: the upgrade checks carry on from these volumes.
        box.sql(f"ALTER USER 'root'@'localhost' IDENTIFIED BY '{pw}'")
        box.password = pw
        expect(box.exec("sh", "-c", "echo image > /var/lib/fishbowl/state/mysql-root-password").returncode == 0)
        expect(box.sql("SELECT 1") == "1")
    check("an earlier installation's own MySQL password: the page says so, and fishbowl-backup asks for it", earlier_installation)

    if RUN_ARGS:
        def hardened_clean():
            t = box.exec("touch", "/usr/.fbcheck")
            expect(t.returncode != 0 and "Read-only file system" in t.stderr, "the root filesystem should be read-only")
            found = box.exec("bash", "-c", "grep -rlsF 'Read-only file system' /var/lib/fishbowl/logs /opt/Fishbowl/logs").stdout.strip()
            expect(not found and "Read-only file system" not in box.logs(), "something ran into the read-only root: " + found)
        check("hardened run (FBCHECK_RUN_ARGS): the root filesystem is read-only, and nothing ran into it", hardened_clean)

    box.remove()


# ------------------------------------------------------------------- update --
# update-all.sh: the logic with a stand-in dnf (what it excludes, how it ends,
# what it never does), then once for real inside a container that has just
# started.
STUB_DNF = r"""#!/bin/bash
echo "dnf $*" >> /stub/calls
case " $* " in
  *" repoquery "*) printf '%s' "${STUB_CANDIDATES:-}"; exit "${STUB_REPO_RC:-0}" ;;
  *" upgrade "*) [ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"; echo "pkg-new-1.0" >> /stub/pkgs; exit "${STUB_DNF_RC:-0}" ;;
esac
exit 0
"""
STUB_RPM = "#!/bin/bash\ncat /stub/pkgs\n"
STUB_SETCAP = "#!/bin/bash\necho \"setcap $*\" >> /stub/calls\nexit 0\n"
STUB_VERIFY = "#!/bin/bash\necho verify >> /stub/calls\nexit \"${STUB_VERIFY_RC:-0}\"\n"


def update(a):
    import tempfile
    image = a.image
    stub = tempfile.mkdtemp(prefix="stub-", dir=a.work if os.path.isdir(a.work) else None)
    os.makedirs(stub, exist_ok=True)
    for name, body in (("dnf", STUB_DNF), ("rpm", STUB_RPM), ("setcap", STUB_SETCAP), ("verify", STUB_VERIFY)):
        with open(os.path.join(stub, name), "w") as f:
            f.write(body.replace("\\n", "\n"))
        os.chmod(os.path.join(stub, name), 0o755)

    def run_script(script, docker_args=(), **env):
        """The real update-all.sh from the image, with the stand-ins in front of dnf, rpm and setcap."""
        with open(os.path.join(stub, "pkgs"), "w") as f:
            f.write("base-1.0\n")
        open(os.path.join(stub, "calls"), "w").close()
        envargs = []
        for k, v in env.items():
            envargs += ["-e", f"{k}={v}"]
        r = sh("docker", "run", "--rm", *docker_args, "--entrypoint", "bash", "-v", f"{stub}:/stub",
               "-e", "PATH=/stub:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
               "-e", "FISHBOWL_UPDATE_VERIFY=/stub/verify", *envargs, image, "-c", script)
        with open(os.path.join(stub, "calls")) as f:
            calls = f.read()
        return r, calls

    GOOD = "mysql-server 8.4.13\ntemurin-21-jdk 21.0.14\n"

    def normal():
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh", STUB_CANDIDATES=GOOD)
        expect(r.returncode == 0, r.stdout[-300:] + r.stderr[-300:])
        expect("--exclude" not in calls, calls)
        expect("--enablerepo=adoptium-temurin-java-repository" in calls, "Java's repository was not switched on")
        expect("verify" in calls and "setcap -r /usr/libexec/mysqld" in calls, calls)
        expect("1 package(s) updated" in r.stdout, r.stdout[-300:])
        expect("autoremove" not in calls and "reboot" not in r.stdout.lower().replace("no reboot", ""), "it must not autoremove or mention a reboot")
    check("update-all.sh: updates through dnf with Java's repository on, fixes mysqld's capability, runs the runtime check", normal)

    def mysql9():
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh", STUB_CANDIDATES="mysql-server 9.1.0\ntemurin-21-jdk 21.0.14\n")
        up = [l for l in calls.splitlines() if " upgrade" in l][0]
        expect("--exclude=mysql*" in up and "--exclude=temurin" not in up, up)
    check("update-all.sh: a MySQL that isn't 8.4 is left out, the rest still updates", mysql9)

    def java25():
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh", STUB_CANDIDATES="temurin-25-jdk 25.0.1\n")
        up = [l for l in calls.splitlines() if " upgrade" in l][0]
        expect("--exclude=temurin-*" in up, up)
    check("update-all.sh: a Java that isn't 21 is left out", java25)

    def verify_fails():
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh", STUB_CANDIDATES=GOOD, STUB_VERIFY_RC=1)
        expect(r.returncode == 2 and "FAILED" in r.stdout, f"{r.returncode}: {r.stdout[-300:]}")
    check("update-all.sh: a failing runtime check after the update ends with status 2 and says what to do", verify_fails)

    def offline():
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh", STUB_REPO_RC=1)
        expect(r.returncode == 1 and " upgrade" not in calls, f"{r.returncode}: {calls}")
    check("update-all.sh: repositories unreachable -> nothing is changed, status 1", offline)

    def dnf_fails():
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh", STUB_CANDIDATES=GOOD, STUB_DNF_RC=1)
        expect(r.returncode == 1 and "dnf failed" in r.stdout, f"{r.returncode}: {r.stdout[-300:]}")
    check("update-all.sh: dnf failing is reported, status 1", dnf_fails)

    def build_mode():
        r, calls = run_script("mkdir -p /var/lib/fishbowl/logs; update-all.sh --build; echo rc=$?; ls /var/lib/fishbowl/logs | wc -l",
                              STUB_CANDIDATES="")
        out = r.stdout.strip().splitlines()
        expect("rc=0" in out and out[-1] == "0", r.stdout[-300:] + r.stderr[-300:])
        expect("skip_if_unavailable=False" in calls, "an image build must fail on a repository it can't read: " + calls)
        expect("verify" in calls and "setcap -r /usr/libexec/mysqld" in calls,
               "every build runs the runtime check and fixes mysqld's capability, even with nothing to update: " + calls)
    check("update-all.sh --build (every image build): strict about repositories, always checks the runtime, no log files", build_mode)

    def build_offline():
        r, calls = run_script("update-all.sh --build; echo rc=$?", STUB_REPO_RC=1)
        expect("rc=1" in r.stdout and " upgrade" not in calls, r.stdout[-300:])
    check("update-all.sh --build: repositories unreachable -> status 1, so the image build stops", build_offline)

    def read_only():
        ro = ("--read-only", "--tmpfs", "/run", "--tmpfs", "/tmp:exec", "--tmpfs", "/var/tmp", "--tmpfs", "/var/lib/fishbowl")
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh --at-start; echo rc=$?; "
                              "ls /var/lib/fishbowl/logs | wc -l; update-all.sh; echo rc=$?",
                              docker_args=ro, FISHBOWL_UPDATE_DELAY=0, STUB_CANDIDATES=GOOD)
        lines = r.stdout.strip().splitlines()
        expect(lines[:2] == ["rc=0", "0"] and lines[-1] == "rc=1" and "read-only" in r.stdout and calls == "",
               f"{r.stdout[-400:]!r} {calls!r}")
    check("on a read-only container (the hardened setup) update-all.sh changes nothing and says updates come from rebuilds",
          read_only)

    def off_switch():
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh --at-start; echo rc=$?; ls /var/lib/fishbowl/logs | wc -l",
                              FISHBOWL_AUTO_UPDATE=0, FISHBOWL_UPDATE_DELAY=0, STUB_CANDIDATES=GOOD)
        expect(r.stdout.split() == ["rc=0", "0"] and calls == "", f"{r.stdout!r} {calls!r}")
    check("FISHBOWL_AUTO_UPDATE=0: nothing runs", off_switch)

    def at_start_quiet():
        script = ("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh --at-start; echo rc=$?; "
                  "echo ---; ls /var/lib/fishbowl/logs; grep -c 'Result: 1 package' /var/lib/fishbowl/logs/update-*.log")
        r, calls = run_script(script, FISHBOWL_UPDATE_DELAY=0, STUB_CANDIDATES=GOOD)
        out = r.stdout
        expect("rc=0" in out and "update-" in out, out)
        expect("System updates: 1 package(s) updated" in out.split("---")[0], "no one-line summary in the container log")
        expect("Updated packages" not in out.split("---")[0] and "Upgrading" not in out.split("---")[0], "the details leaked into the container log")
    check("update-all.sh at start: details go to a log file, one line to the container log", at_start_quiet)

    def keeps_five():
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; for i in 1 2 3 4 5 6 7; do update-all.sh --at-start >/dev/null 2>&1; sleep 1; done; ls /var/lib/fishbowl/logs/update-*.log | wc -l",
                              FISHBOWL_UPDATE_DELAY=0, STUB_CANDIDATES=GOOD)
        expect(r.stdout.strip() == "5", r.stdout + r.stderr)
    check("update logs: the five newest are kept", keeps_five)

    def stop_while_waiting():
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh --at-start & p=$!; sleep 1; kill -TERM $p; s=$(date +%s); wait $p; echo rc=$? waited=$(( $(date +%s) - s ))",
                              FISHBOWL_UPDATE_DELAY=300, STUB_CANDIDATES=GOOD)
        m = re.search(r"rc=(\d+) waited=(\d+)", r.stdout)
        expect(m and m.group(1) == "0" and int(m.group(2)) <= 3 and " upgrade" not in calls, r.stdout + calls)
    check("stopping the container while an update is still waiting its turn ends it at once", stop_while_waiting)

    def stop_during_dnf():
        r, calls = run_script("mkdir -p /run/fishbowl /var/lib/fishbowl/logs; update-all.sh --at-start >/dev/null 2>&1 & p=$!; sleep 2; kill -TERM $p; wait $p; echo rc=$?; grep -c 'Result: 1 package' /var/lib/fishbowl/logs/update-*.log",
                              FISHBOWL_UPDATE_DELAY=0, STUB_CANDIDATES=GOOD, STUB_SLEEP=4)
        expect("rc=0" in r.stdout and r.stdout.strip().endswith("1") and " upgrade" in calls, r.stdout + calls)
    check("stopping the container while dnf works lets the package step finish first", stop_during_dnf)

    def setup_waits():
        script = ("mkdir -p /run/fishbowl; ( exec 9>/run/fishbowl/update.lock; flock 9; sleep 5 ) & sleep 1; s=$(date +%s); "
                  "bash -c '. /usr/local/lib/fishbowl/common.sh; wait_for_system_update; echo got-lock' ; echo waited=$(( $(date +%s) - s ))")
        r, calls = run_script(script)
        m = re.search(r"waited=(\d+)", r.stdout)
        expect("got-lock" in r.stdout and m and int(m.group(1)) >= 3, r.stdout + r.stderr)
    check("a first-time setup or upgrade waits for a running system update", setup_waits)

    # -- once for real, in a container that has just started
    box = Box("fbcheck-u", image, a.port, a.password, a.work)
    box.create_volumes()
    box.run(env=["FISHBOWL_AUTO_UPDATE=1", "FISHBOWL_UPDATE_DELAY=3"], hardened=False)   # a writable container
    try:
        box.wait_state("needs-setup", 120)
        started = sh("docker", "inspect", "-f", "{{.State.StartedAt}} {{.RestartCount}}", box.name).stdout.strip()

        def real_update():
            deadline = time.time() + 900
            log = ""
            while time.time() < deadline:
                log = box.exec("bash", "-c", "cat /var/lib/fishbowl/logs/update-*.log 2>/dev/null").stdout
                if "Result:" in log:
                    break
                time.sleep(5)
            expect("Result:" in log, "the update never finished: " + log[-300:])
            expect("Update run started" in log)
            return log
        log = {}
        ok = check("a container that has just started updates itself in the background (real dnf)", lambda: log.update(text=real_update()) or True)
        if ok:
            text = log["text"]
            result = re.search(r"Result: (.*)", text).group(1)
            print(f"      (update result: {result})", flush=True)
            check("the update did not restart the container or any program, and asked nothing",
                  lambda: expect(sh("docker", "inspect", "-f", "{{.State.StartedAt}} {{.RestartCount}}", box.name).stdout.strip() == started
                                 and box.state() == "needs-setup" and "[Y/n]" not in text and "reboot" not in text.lower()))
            check("after the update MySQL 8.4 and Java 21 still pass the image's runtime check (mysqld starts under Docker's default capabilities)",
                  lambda: expect(box.exec("bash", "/usr/local/lib/fishbowl/verify-runtime.sh").returncode == 0))
            check("the update left no package cache behind", lambda: expect(
                box.exec("bash", "-c", "du -sk /var/cache/libdnf5 /var/cache/dnf 2>/dev/null | awk '{s+=$1} END {print s+0}'").stdout.strip() in ("0", "") or
                int(box.exec("bash", "-c", "du -sk /var/cache/libdnf5 /var/cache/dnf 2>/dev/null | awk '{s+=$1} END {print s+0}'").stdout.strip() or 0) < 20000))
    finally:
        box.remove()
        sh("docker", "volume", "rm", "-f", *[f"fbcheck-u-{p}" for p in ("mysql", "app", "data")])


# ---------------------------------------------------------------- reference --
# A known-good backup made by Fishbowl (--reference-sql), restored the way a
# person does it: uploaded on the page, restored in Server Administration's
# Restore tab under the name Fishbowl suggests, selected on the Database tab.
# The restored database is compared with a direct load of the same file.
def dump_made_by(path):
    """The Fishbowl version recorded in a backup's databaseversion table ("2026.7"), or ""."""
    found = ""
    with open(path, "rb") as f:
        for line in f:
            if line.startswith(b"INSERT INTO `databaseversion`"):
                for m in re.finditer(rb"'Fishbowl v(\d+(?:\.\d+)+)'", line):
                    v = m.group(1).decode()
                    if tuple(map(int, v.split("."))) > tuple(map(int, (found or "0").split("."))):
                        found = v
    return found


def year_month(v):
    return tuple(int(x) for x in v.split(".")[:2])


def schemas(box):
    return set(box.sql("SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN "
                       "('mysql','sys','performance_schema','information_schema')").split())


def fingerprint(box, db):
    """Everything that should match between two copies of a database."""
    tables = box.sql(f"SELECT table_name FROM information_schema.tables WHERE table_schema='{db}' "
                     "AND table_type='BASE TABLE' ORDER BY 1").split()
    expect(tables, f"database {db} has no tables")
    sums = box.sql("CHECKSUM TABLE " + ", ".join(f"`{db}`.`{t}`" for t in tables) + " EXTENDED")
    sums = sorted(line.split(".", 1)[1] for line in sums.splitlines())
    rows = int(box.sql("SELECT " + " + ".join(f"(SELECT COUNT(*) FROM `{db}`.`{t}`)" for t in tables)))
    defs = box.sql(f"""SELECT CONCAT('VIEW ', table_name, ' ', view_definition) FROM information_schema.views WHERE table_schema='{db}'
                       UNION ALL SELECT CONCAT('TRIGGER ', trigger_name, ' ', action_statement) FROM information_schema.triggers WHERE trigger_schema='{db}'
                       UNION ALL SELECT CONCAT('ROUTINE ', routine_name, ' ', routine_definition) FROM information_schema.routines WHERE routine_schema='{db}'
                       ORDER BY 1""").replace(f"`{db}`.", "`DB`.")
    version = box.sql(f"SELECT MAX(version) FROM `{db}`.databaseversion")
    return {"tables": len(tables), "checksums": sums, "rows": rows, "definitions": defs, "db_version": version}


def reference(a):
    pw, ref = a.password, a.reference_sql
    box = Box("fbcheck-r", a.image, a.port + 20, pw, a.work)
    made_by = dump_made_by(ref)
    base = os.path.basename(ref)
    stem = base[:-4] if base.lower().endswith(".sql") else base
    suggested = stem.rsplit("_", 1)[0] if "_" in stem else ""
    print(f"      (reference: {base}, {os.path.getsize(ref) / 1e6:.1f} MB, made by Fishbowl {made_by or '?'})", flush=True)
    box.create_volumes()
    box.run()
    page = None

    def install():
        nonlocal page
        box.wait_state("needs-setup", 90)
        page = box.page()
        page.setup()
        page.wait_state("awaiting-database", 900)
    if not check("reference: fresh trial installation, waiting for a database", install):
        box.remove()
        return

    stored = None

    def upload():
        nonlocal stored
        stored = page.upload(ref)
        deadline = time.time() + 120
        entry = {}
        while time.time() < deadline:
            entry = next((f for f in page.status()["imports"] if f["name"] == stored), {})
            if entry.get("made_by") is not None:
                break
            time.sleep(2)
        expect(entry.get("size") == os.path.getsize(ref), f"import folder entry: {entry}")
        expect(entry.get("made_by") == made_by, f"the page says made by {entry.get('made_by')!r}, the file says {made_by!r}")
    if not check("reference: upload on the page; the page reads which Fishbowl version made it", upload):
        box.remove()
        return

    restored = None
    expected = None

    def restore():
        nonlocal restored, expected
        before = schemas(box)
        page.open_window("admin")
        start_bridge(box.name)
        g = box.gui("reference")
        g.locate()
        g.click(TAB_RESTORE, pause=2)
        g.click(RESTORE_MAGNIFIER, pause=3)
        g.replace_text(CHOOSER_FILE_NAME, "/var/lib/fishbowl/import/" + stored)
        g.click(CHOOSER_OPEN, pause=3)
        g.shot("ref-1-file-chosen")              # the database name is Fishbowl's own suggestion
        # Password: left as Fishbowl filled it in, as the page says
        g.click(RESTORE_BUTTON, pause=3)
        g.shot("ref-2-confirm")
        g.click(RESTORE_YES)
        deadline = time.time() + 1800
        last, same = -1, 0
        while time.time() < deadline:
            time.sleep(5)
            new = schemas(box) - before
            if len(new) != 1:
                continue
            restored = new.pop()
            n = box.tables(restored)
            same = same + 1 if (n == last and n > 0) else 0
            last = n
            if same >= 3:
                break
        expect(restored and same >= 3, "the restore didn't finish within 30 minutes")
        time.sleep(8)
        g.shot("ref-3-restored")
        g.click(RESTORED_OK, pause=2)
        expected = fingerprint(box, restored)
        if suggested:
            expect(restored == suggested.lower(), f"restored into {restored!r}; the file name suggests {suggested!r}")
    if not check("reference: Restore tab restores it under the name Fishbowl suggests (the file name before its last underscore)", restore):
        box.remove()
        return

    def identical():
        box.sql("DROP DATABASE IF EXISTS fbcheck_direct; CREATE DATABASE fbcheck_direct")
        with open(ref, "rb") as f:
            r = subprocess.run(["docker", "exec", "-i", "-e", "MYSQL_PWD=" + pw, box.name, "mysql", "--protocol=tcp", "-h127.0.0.1",
                                "-uroot", "--max-allowed-packet=1G", "fbcheck_direct"], stdin=f, capture_output=True)
        expect(r.returncode == 0, "loading the file directly failed: " + r.stderr.decode(errors="replace")[-300:])
        direct = fingerprint(box, "fbcheck_direct")
        box.sql("DROP DATABASE fbcheck_direct")
        for k in ("tables", "rows", "db_version", "definitions", "checksums"):
            expect(expected[k] == direct[k], f"{k} differ")
        print(f"      ({expected['tables']} tables, {expected['rows']} rows, "
              f"{len(expected['definitions'].splitlines())} views/triggers/routines; database version {expected['db_version']})", flush=True)
    check("reference: the restored database is identical to the file (every table's checksum, rows, views, triggers, routines)", identical)

    installed = page.status()["installed_version"]
    older = bool(made_by) and year_month(made_by) < year_month(installed)

    def select_and_start():
        g = box.gui("reference")
        g.locate()
        g.select_database(0)
        page.wait_window_closed("admin", 120)
        st = page.wait_state(("running", "server-failed"), 900)
        if not older:
            expect(st["state"] == "running" and st["database"].lower() == restored, f"state {st['state']}, database {st['database']!r}")
            return
        # An older backup on a trial: Fishbowl Server has to update the database and won't.
        expect(st["state"] == "server-failed", f"state {st['state']} (expected Fishbowl to refuse a trial's database update)")
        expect("Trial accounts do not have access to update the database" in st["message"], st["message"][:200])
        time.sleep(10)
        expect(box.is_up() and box.state() == "server-failed", "the container didn't stay up and waiting")
        expect(fingerprint(box, restored) == expected, "the database changed after Fishbowl's refusal")
        page.open_window("admin")
        page.close_window("admin")
        page.wait_window_closed("admin", 60)
    if older and installed:
        name = (f"reference: select it -> Fishbowl Server {versionish(installed)} refuses to update a {made_by} database on a trial; "
                "the page shows why, the database is left unchanged, Server Administration still opens")
    else:
        name = "reference: select it on the Database tab -> Fishbowl Server starts on the restored database"
    check(name, select_and_start)
    box.remove()


def versionish(v):
    return ".".join(v.split(".")[:2])


# ------------------------------------------------------------------ upgrade --
def quick_install(box):
    """A trial install with a database, for the upgrade checks when the runtime checks didn't run."""
    box.create_volumes()
    box.run()
    box.wait_state("needs-setup", 90)
    page = box.page()
    page.setup()
    page.wait_state("awaiting-database", 900)
    page.open_window("admin")
    start_bridge(box.name)
    g = box.gui("install")
    g.locate()
    g.create_database("fbcheck", box.password, box.tables)
    g.select_database(0)
    page.wait_window_closed("admin", 120)
    page.wait_state("running", 600)
    box.sql("CREATE TABLE IF NOT EXISTS fbcheck.zz_fbcheck_marker (id INT PRIMARY KEY, v VARCHAR(40)); "
            "REPLACE INTO fbcheck.zz_fbcheck_marker VALUES (1,'kept');")
    box.remove()


def upgrade(a):
    pw = a.password
    box = Box("fbcheck-a", a.image, a.port, pw, a.work)
    have = sh("docker", "run", "--rm", "--entrypoint", "cat", "-v", "fbcheck-a-data:/d", a.image, "/d/state/installed-version")
    if have.returncode != 0 or not have.stdout.strip():
        if not check("a trial installation to upgrade (setup on the page, database in Server Administration)", lambda: quick_install(box)):
            return
    old = sh("docker", "run", "--rm", "--entrypoint", "cat", "-v", "fbcheck-a-data:/d", a.image, "/d/state/installed-version").stdout.strip()
    new = sh("docker", "run", "--rm", a.next, "version").stdout.strip()
    database = box.helper("python3 -I /usr/local/lib/fishbowl/props.py get /opt/Fishbowl/server/bin/eve.properties dbName").stdout.strip()
    print(f"      (installed {old}, newer image carries {new}, database {database})", flush=True)

    # -- a trial is not upgraded (Fishbowl Server won't update a trial's database), but it keeps running
    box.run(image=a.next)

    def trial_blocked():
        box.wait_state("running", 400)
        st = box.page().status()
        expect(st["upgrade_blocked"] == "trial" and not st["upgrade_to"], f"blocked={st['upgrade_blocked']!r} to={st['upgrade_to']!r}")
        expect(box.installed_version() == old and "trial installation" in box.logs())
    check("newer image, trial installation: the installed version keeps running, the upgrade isn't offered", trial_blocked)
    box.remove()

    # -- told that the new version leaves the database alone (the stand-in "newer" version is the same installer)
    env = ["FISHBOWL_ALLOW_TRIAL_UPGRADE=1"]
    box.run(image=a.next, env=env)
    page = None

    def offered():
        nonlocal page
        box.wait_state("running", 400)
        page = box.page()
        st = page.status()
        expect(st["upgrade_to"] == new and st["installed_version"] == old and st["state"] == "running", str(st))
        expect(box.installed_version() == old)
    if not check("newer image: starts without a terminal, runs the installed version, offers the upgrade on the page", offered):
        box.remove()
        return

    def not_accepted():
        try:
            page.upgrade(accept=False)
        except PageError as e:
            expect(e.status == 400, f"{e.status}: {e.message}")
        else:
            raise AssertionError("an upgrade without the license agreement was accepted")
        s = Session(["docker", "exec", "-it", box.name, "fishbowl-upgrade"], os.devnull)
        s.expect(r"Press Enter to open the license agreement", 60)
        s.sendline()
        s.expect(r"q when done", 30)
        s.send("q")
        s.expect(r'Type "yes" to accept: ', 30)
        s.sendline("no")
        expect(s.wait_exit(60) == 1, "fishbowl-upgrade should exit 1 after 'no'")
        time.sleep(3)
        expect(box.installed_version() == old and box.state() == "running")
    check("upgrade: license agreement not accepted (page, and 'no' at fishbowl-upgrade) -> nothing changes", not_accepted)

    def wrong_password():
        page.upgrade("Wrong!pass123")
        deadline = time.time() + 30
        st = {}
        while time.time() < deadline:
            st = page.status()
            if st["last_error"] and not st["requests"]["upgrade"]:
                break
            time.sleep(1)
        expect("rejected" in st.get("last_error", ""), f"last_error={st.get('last_error')!r}")
        expect(st["state"] == "running" and box.installed_version() == old and box.client_port_open())
    check("upgrade: wrong MySQL password -> refused before anything is stopped", wrong_password)

    def upgrade_on_page():
        page.upgrade()
        deadline = time.time() + 60
        while time.time() < deadline and page.status()["state"] != "upgrading":
            time.sleep(1)
        st = page.wait_state("running", 1800)
        expect(st["installed_version"] == new and not st["upgrade_to"], str(st))
        expect(box.installed_version() == new)
    ok = check("upgrade on the page: license agreement only -> backup, upgrade, server running", upgrade_on_page)
    if ok:
        check("the new version's acceptance is on record", lambda: expect(
            "Fishbowl page" in box.exec("cat", f"/var/lib/fishbowl/state/eula/accepted-{new}").stdout))
        check("upgrade kept the data and the selected database", lambda: expect(
            box.sql(f"SELECT v FROM {database}.zz_fbcheck_marker") == "kept" and page.status()["database"] == database))
        check("upgrade left a database backup", lambda: expect(
            box.exec("bash", "-c", "ls /var/lib/fishbowl/backups/pre-upgrade-*.sql.gz").returncode == 0))
        check("upgrade kept the memory settings", lambda: expect(
            box.exec("grep", "-qx", "--", "-Xmx8192M", "/opt/Fishbowl/server/bin/Fishbowl Server Service.vmoptions").returncode == 0))
    box.remove()
    if not ok:
        return

    # -- an upgrade that stopped half-way must be finished before Fishbowl Server starts
    box.helper(f"echo {old} > /var/lib/fishbowl/state/installed-version; echo test > /var/lib/fishbowl/state/upgrade.in-progress")
    box.run(image=a.next, env=env)

    def interrupted():
        box.wait_state("upgrade-interrupted", 300)
        time.sleep(5)
        expect(not box.client_port_open(), "Fishbowl Server was started on a half-upgraded installation")
        p = box.page()
        p.upgrade()
        st = p.wait_state("running", 1800)
        expect(st["installed_version"] == new and box.installed_version() == new)
        expect(box.exec("test", "-e", "/var/lib/fishbowl/state/upgrade.in-progress").returncode != 0)
    check("an interrupted upgrade: Fishbowl Server stays stopped until the upgrade is run again", interrupted)
    box.remove()

    # -- no way back: an older image holds instead of touching anything
    box.run(image=a.image)

    def downgrade():
        box.wait_state("downgrade", 120)
        time.sleep(5)
        expect(box.is_up() and box.installed_version() == new)
        expect(box.exec("pgrep", "-x", "mysqld").returncode != 0, "MySQL was started")
        expect("Downgrades are refused" in box.page().status()["message"])
    check("older image on upgraded volumes: nothing is started or changed, and the page says why", downgrade)
    box.remove(grace=30)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("group", choices=["runtime", "update", "upgrade", "reference"])
    ap.add_argument("--image", required=True)
    ap.add_argument("--next", default="")
    ap.add_argument("--reference-sql", default="")
    ap.add_argument("--password", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--work", required=True)
    a = ap.parse_args()
    os.makedirs(a.work, exist_ok=True)
    if a.group == "reference" and not os.path.isfile(a.reference_sql):
        sys.exit("--reference-sql FILE is needed for the reference checks")
    try:
        {"runtime": runtime, "update": update, "upgrade": upgrade, "reference": reference}[a.group](a)
    except Exception as e:   # noqa: BLE001
        report(f"{a.group} checks ran to the end", False, f"{type(e).__name__}: {e}")
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
