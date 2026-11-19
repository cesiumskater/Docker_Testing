"""Checks for the image's small Python helpers that need no Docker.

    python3 -I -m unittest discover -s tests/unit -v      (from the repository root)

probe.py (the watchdog's liveness check), logstream.py (Fishbowl's and MySQL's
logs into `docker logs`) and adoptium-repo.py (the Java 21 repository file).
"""

import importlib.util
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "..", "rootfs", "usr", "local", "lib", "fishbowl")


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(LIB, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def probe(port, timeout=2):
    return subprocess.run([sys.executable, "-I", os.path.join(LIB, "probe.py"), "--port", str(port),
                           "--timeout", str(timeout)], capture_output=True, text=True)


class Quiet(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(404)
        self.end_headers()

    def log_message(self, *a):
        pass


class ProbeTests(unittest.TestCase):
    def test_http_answer_counts_even_404(self):
        srv = HTTPServer(("127.0.0.1", 0), Quiet)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            r = probe(srv.server_address[1])
            self.assertEqual(r.returncode, 0, r.stdout)
        finally:
            srv.shutdown()
            srv.server_close()

    def test_open_port_that_never_answers_is_a_hang(self):
        # listen() without accept(): the kernel completes the connection, like a frozen JVM.
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(5)
        try:
            t0 = time.monotonic()
            r = probe(s.getsockname()[1], timeout=1.5)
            self.assertEqual(r.returncode, 1, r.stdout)
            self.assertIn("didn't answer", r.stdout)
            self.assertLess(time.monotonic() - t0, 6)
        finally:
            s.close()

    def test_nothing_listening(self):
        r = probe(free_port(), timeout=1)
        self.assertEqual(r.returncode, 1)
        self.assertIn("Nothing is listening", r.stdout)

    @unittest.skipUnless(shutil.which("openssl"), "openssl not installed")
    def test_tls_port_answers(self):
        d = tempfile.mkdtemp()
        key, crt = os.path.join(d, "k.pem"), os.path.join(d, "c.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt,
                        "-days", "1", "-subj", "/CN=localhost"], check=True, capture_output=True)
        srv = HTTPServer(("127.0.0.1", 0), Quiet)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            r = probe(srv.server_address[1], timeout=4)
            self.assertEqual(r.returncode, 0, r.stdout)
            self.assertIn("TLS", r.stdout)
        finally:
            srv.shutdown()
            srv.server_close()
            shutil.rmtree(d)


class LogstreamTests(unittest.TestCase):
    def setUp(self):
        self.ls = load("logstream", "logstream.py")
        self.d = tempfile.mkdtemp()
        self.lines = []

    def tearDown(self):
        shutil.rmtree(self.d)

    def emit(self, tag, raw):
        self.lines.append((tag, raw.decode()))

    def write(self, name, text, mode="a"):
        with open(os.path.join(self.d, name), mode) as f:
            f.write(text)

    def test_follows_from_end_then_rotation_and_truncation(self):
        self.write("a.log", "old line\n", "w")
        f = self.ls.Follower("fbserver", os.path.join(self.d, "a.log"))
        f.poll(self.emit)
        self.assertEqual(self.lines, [])            # what was there at start stays in the file
        self.write("a.log", "one\ntwo\npart")
        f.poll(self.emit)
        self.assertEqual([l for _, l in self.lines], ["one", "two"])
        self.write("a.log", "ial\n")
        f.poll(self.emit)
        self.assertEqual(self.lines[-1][1], "partial")
        os.rename(os.path.join(self.d, "a.log"), os.path.join(self.d, "a.log.1"))   # rotation
        self.write("a.log", "after rotation\n", "w")
        f.poll(self.emit)
        self.assertEqual(self.lines[-1][1], "after rotation")
        self.write("a.log", "x\n", "w")             # truncated in place
        f.poll(self.emit)
        self.assertEqual(self.lines[-1][1], "x")

    def test_file_that_appears_later_is_read_from_start(self):
        f = self.ls.Follower("mysqld", os.path.join(self.d, "late.log"))
        f.poll(self.emit)
        self.write("late.log", "first\n", "w")
        f.poll(self.emit)
        self.assertEqual(self.lines, [("mysqld", "first")])

    def test_secrets_are_redacted(self):
        pw = os.path.join(self.d, "pw.txt")
        eve = os.path.join(self.d, "eve.properties")
        self.write("pw.txt", "S3cr3t!Pass^%=", "w")
        self.write("eve.properties", "dbName=acme\nlicenseKey=ABCD-EFGH-1234\nwebPort=2456\nmysqlPassword=hunter22\n", "w")
        self.ls.SECRET_SOURCES = {"password_file": pw, "web_code": "/nonexistent", "props": [eve]}
        secrets = self.ls.load_secrets()
        text = "pw S3cr3t!Pass^%= key ABCD-EFGH-1234 other hunter22 db acme port 2456"
        out = self.ls.redact(text, secrets)
        for s in ("S3cr3t!Pass^%=", "ABCD-EFGH-1234", "hunter22"):
            self.assertNotIn(s, out)
        self.assertIn("acme", out)
        self.assertIn("2456", out)

    def test_whole_program_tags_and_timestamps(self):
        path = os.path.join(self.d, "s.log")
        self.write("s.log", "", "w")
        p = subprocess.Popen([sys.executable, "-I", "-u", os.path.join(LIB, "logstream.py"), "fbserver=" + path],
                             stdout=subprocess.PIPE, text=True)
        try:
            time.sleep(1)
            self.write("s.log", "java.lang.Exception: boom\n\tat x.y(Z.java:1)\n")
            time.sleep(1.5)
        finally:
            p.terminate()
            out, _ = p.communicate(timeout=5)
        got = out.strip().splitlines()
        self.assertEqual(len(got), 2, out)
        for line in got:
            self.assertRegex(line, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \[fbserver\] ")
        self.assertTrue(got[1].endswith("\tat x.y(Z.java:1)"))


class AdoptiumRepoTests(unittest.TestCase):
    def setUp(self):
        self.m = load("adoptium_repo", "adoptium-repo.py")
        self.d = tempfile.mkdtemp()
        self.out = os.path.join(self.d, "adoptium.repo")

    def tearDown(self):
        shutil.rmtree(self.d)

    def run_main(self, own, available, release=""):
        self.m.fedora_release = lambda: own
        self.m.tree_exists = lambda r, arch, timeout=30: r in available
        sys.argv = ["adoptium-repo.py", "--out", self.out, "--release", release]
        return self.m.main()

    def test_uses_own_release_when_published(self):
        self.assertEqual(self.run_main(45, {43, 44, 45}), 0)
        text = open(self.out).read()
        self.assertIn("/fedora/45/$basearch", text)
        self.assertIn("enabled=1", text)
        self.assertIn("gpgcheck=1", text)
        self.assertIn("includepkgs=temurin-21-jdk temurin-21-jre", text)

    def test_falls_back_to_previous_release(self):
        self.assertEqual(self.run_main(45, {44}), 0)
        self.assertIn("/fedora/44/$basearch", open(self.out).read())

    def test_stops_when_nothing_is_published(self):
        self.assertEqual(self.run_main(45, set()), 1)
        self.assertFalse(os.path.exists(self.out))

    def test_forced_release(self):
        self.assertEqual(self.run_main(45, {44, 45}, release="44"), 0)
        self.assertIn("/fedora/44/$basearch", open(self.out).read())
        self.assertEqual(self.run_main(45, {44}, release="45"), 1)


if __name__ == "__main__":
    unittest.main()
