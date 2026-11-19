#!/usr/bin/env python3
"""Does Fishbowl Server answer on its client port, or does the port only accept?

    python3 -I probe.py [--host 127.0.0.1] [--port 2456] [--timeout 5]

A plain TCP connect isn't enough to tell: the kernel completes the connection
for a Java process that is frozen or deadlocked, because the port stays open.
This sends a small HTTP request (HEAD /) and waits for the first bytes of any
answer. Any status counts, 404 and 400 included: what matters is that Fishbowl
Server's own threads replied. When the port speaks TLS (Server Administration's
Secure Connection), the plain request gets no answer, so it tries again over TLS
without checking the certificate.

Prints one line and exits 0 when Fishbowl Server answered, 1 when it didn't,
2 on a usage error. Used by the watchdog in fishbowl-entrypoint and by
fishbowl-healthcheck. Never sends anything secret.
"""

import argparse
import socket
import ssl
import sys
import time

REQUEST = b"HEAD / HTTP/1.1\r\nHost: localhost\r\nUser-Agent: fishbowl-watchdog\r\nConnection: close\r\n\r\n"


def first_bytes(sock, deadline):
    sock.sendall(REQUEST)
    left = deadline - time.monotonic()
    if left <= 0:
        raise socket.timeout("no answer")
    sock.settimeout(left)
    return sock.recv(64)  # b"" when the peer closed without answering


def plain(host, port, deadline):
    with socket.create_connection((host, port), timeout=max(0.1, deadline - time.monotonic())) as s:
        return first_bytes(s, deadline)


def tls(host, port, deadline):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with socket.create_connection((host, port), timeout=max(0.1, deadline - time.monotonic())) as raw:
        with ctx.wrap_socket(raw, server_hostname="localhost") as s:
            return first_bytes(s, deadline)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=2456)
    ap.add_argument("--timeout", type=float, default=5.0)
    try:
        a = ap.parse_args()
    except SystemExit:
        return 2
    deadline = time.monotonic() + a.timeout
    why = ""
    try:
        data = plain(a.host, a.port, deadline)
        if data:
            print("Fishbowl Server answered on port %d" % a.port)
            return 0
        why = "closed the connection without answering"
    except (socket.timeout, TimeoutError):
        print("Fishbowl Server accepted a connection on port %d but didn't answer within %gs" % (a.port, a.timeout))
        return 1
    except ConnectionRefusedError:
        print("Nothing is listening on port %d" % a.port)
        return 1
    except OSError as e:
        why = str(e) or e.__class__.__name__
    # A TLS port either closes on a plain request or resets it: try TLS with the time left.
    try:
        data = tls(a.host, a.port, deadline)
        if data:
            print("Fishbowl Server answered over TLS on port %d" % a.port)
            return 0
        why = "closed the TLS connection without answering"
    except (socket.timeout, TimeoutError):
        why = "no answer within %gs" % a.timeout
    except (OSError, ssl.SSLError) as e:
        why = "%s; over TLS: %s" % (why, e)
    print("Fishbowl Server didn't answer on port %d (%s)" % (a.port, why))
    return 1


if __name__ == "__main__":
    sys.exit(main())
