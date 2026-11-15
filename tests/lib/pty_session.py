"""Minimal expect-style driver for interactive commands (standard library only).

Runs a command in a pseudo-terminal so `docker run -it` behaves exactly as it
does for a person at a keyboard, then waits for prompts and types answers.
Everything the terminal shows is appended to a transcript file.
"""
import os
import pty
import re
import select
import signal
import time

ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][A-Za-z0-9]|\x1b[=>]|\r")


class Timeout(Exception):
    pass


class Session:
    def __init__(self, argv, transcript, cols=100, rows=40):
        self.transcript = open(transcript, "ab")
        self.buffer = b""          # everything seen so far (ANSI stripped)
        self.cursor = 0            # expect() searches from here
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm"
            os.environ["COLUMNS"], os.environ["LINES"] = str(cols), str(rows)
            os.execvp(argv[0], argv)
        import fcntl, struct, termios
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.exitstatus = None

    def _read(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return False
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            data = b""
        if not data:
            raise EOFError
        self.transcript.write(data)
        self.transcript.flush()
        self.buffer += ANSI.sub(b"", data)
        return True

    def expect(self, pattern, timeout=60):
        """Wait until regex `pattern` appears after the previous match; return the match."""
        rx = re.compile(pattern.encode() if isinstance(pattern, str) else pattern)
        deadline = time.time() + timeout
        while True:
            m = rx.search(self.buffer, self.cursor)
            if m:
                self.cursor = m.end()
                return m
            left = deadline - time.time()
            if left <= 0:
                tail = self.buffer[-1500:].decode(errors="replace")
                raise Timeout(f"timed out after {timeout}s waiting for {pattern!r}; last output:\n{tail}")
            try:
                self._read(min(left, 1.0))
            except EOFError:
                tail = self.buffer[-1500:].decode(errors="replace")
                raise Timeout(f"process ended while waiting for {pattern!r}; last output:\n{tail}")

    def seen(self, pattern):
        return re.search(pattern.encode(), self.buffer) is not None

    def send(self, text):
        os.write(self.fd, text.encode() if isinstance(text, str) else text)

    def sendline(self, text=""):
        self.send(text + "\r")

    def wait_exit(self, timeout=300):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                self._read(0.5)
            except EOFError:
                break
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.exitstatus = os.waitstatus_to_exitcode(status)
                return self.exitstatus
        pid, status = os.waitpid(self.pid, 0 if time.time() < deadline else os.WNOHANG)
        if pid:
            self.exitstatus = os.waitstatus_to_exitcode(status)
        return self.exitstatus

    def interrupt(self):
        self.send(b"\x03")

    def close(self):
        try:
            os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        self.transcript.close()
