"""Talk to the Fishbowl page the way a browser does (standard library only).

Used by the acceptance checks: sign in with the access code, read the status,
submit the setup and upgrade forms, upload a .sql file, press the buttons.
"""
import http.client
import http.cookiejar
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request


class PageError(Exception):
    def __init__(self, status, message):
        super().__init__(f"{status}: {message}")
        self.status, self.message = status, message


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def access_code(container):
    """The page's access code, as `docker exec <container> fishbowl-link` prints it."""
    out = subprocess.run(["docker", "exec", container, "fishbowl-link"], capture_output=True, text=True, check=True).stdout
    return out.strip().rsplit("code=", 1)[1]


class Page:
    def __init__(self, base):
        self.base = base.rstrip("/")
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar), _NoRedirect())

    # ---- plumbing
    def request(self, method, path, body=None, headers=None, timeout=30):
        """Returns (status, headers, body bytes). Never follows redirects."""
        req = urllib.request.Request(self.base + path, data=body, method=method, headers=headers or {})
        try:
            with self.opener.open(req, timeout=timeout) as r:
                return r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()

    def api(self, method, path, obj=None, ok=(200,)):
        body = None if obj is None else json.dumps(obj).encode()
        status, _, raw = self.request(method, path, body, {"X-Fishbowl": "1", "Content-Type": "application/json"})
        try:
            data = json.loads(raw.decode() or "{}")
        except ValueError:
            data = {"raw": raw[:200].decode(errors="replace")}
        if status not in ok:
            raise PageError(status, data.get("error", str(data)))
        return data

    # ---- signing in
    def sign_in(self, code):
        """Open the link with the access code; True when the page let us in."""
        status, headers, _ = self.request("GET", "/?code=" + urllib.parse.quote(code))
        return status == 303 and headers.get("Location") == "/" and any(c.name == "fishbowl_page" for c in self.jar)

    # ---- reading
    def status(self):
        return self.api("GET", "/api/status")

    def wait_state(self, states, timeout=300, every=2.0):
        """Wait until the container's state is one of `states`; returns the status."""
        states = (states,) if isinstance(states, str) else tuple(states)
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            try:
                last = self.status()
                if last.get("state") in states:
                    return last
            except (PageError, OSError, http.client.HTTPException):
                pass   # the page may be restarting with the container
            time.sleep(every)
        raise TimeoutError(f"state stayed {last and last.get('state')!r} (wanted {states}) for {timeout}s; "
                           f"last error: {last and last.get('last_error')!r}")

    def eula(self):
        return self.api("GET", "/api/eula")

    # ---- the forms
    def setup(self, password, key=None, company=None, accept=True, password2=None, eula_sha256=None):
        body = {"eula_accepted": bool(accept), "eula_sha256": eula_sha256 or self.eula()["sha256"],
                "license": "key" if key else "trial", "password": password,
                "password2": password if password2 is None else password2}
        if key:
            body.update(key=key, company=company or "")
        return self.api("POST", "/api/setup", body)

    def upgrade(self, password, accept=True):
        return self.api("POST", "/api/upgrade", {"eula_accepted": bool(accept), "eula_sha256": self.eula()["sha256"],
                                                 "password": password})

    def server(self, action):
        return self.api("POST", "/api/server/" + action, {})

    def open_window(self, name, width=1280, height=800, timeout=90):
        """Ask for Server Administration ("admin") or the Client ("client") and wait until its screen is up."""
        self.api("POST", f"/api/session/{name}/open", {"width": width, "height": height})
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.status()["sessions"][name] == "ready":
                return True
            time.sleep(1)
        raise TimeoutError(f"the {name} window did not open within {timeout}s")

    def close_window(self, name):
        return self.api("POST", f"/api/session/{name}/close", {})

    def wait_window_closed(self, name, timeout=120):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.status()["sessions"][name] == "closed":
                return True
            time.sleep(1)
        raise TimeoutError(f"the {name} window was still open after {timeout}s")

    # ---- .sql files for the Restore tab
    def upload(self, path, name=None):
        """PUT a file into the import folder, streamed like a browser upload. Returns the stored name."""
        name = name or os.path.basename(path)
        size = os.path.getsize(path)
        self.api("POST", "/api/imports-check", {"name": name, "size": size})
        url = urllib.parse.urlsplit(self.base)
        conn = http.client.HTTPConnection(url.hostname, url.port, timeout=600)
        cookie = "; ".join(f"{c.name}={c.value}" for c in self.jar)
        with open(path, "rb") as f:
            conn.request("PUT", "/api/imports/" + urllib.parse.quote(name), body=f,
                         headers={"X-Fishbowl": "1", "Cookie": cookie, "Content-Length": str(size)})
            r = conn.getresponse()
            data = json.loads(r.read().decode() or "{}")
        conn.close()
        if r.status != 200:
            raise PageError(r.status, data.get("error", str(data)))
        return data["name"]

    def remove_upload(self, name):
        return self.api("DELETE", "/api/imports/" + urllib.parse.quote(name))
