#!/usr/bin/env python3
"""Test helper, copied into a test container and run there as root.

Fishbowl's windows listen on private VNC sockets inside the container
(/run/fishbowl/x/admin.rfb and client.rfb); in normal use only the Fishbowl page
reaches them. The checks drive the windows with vncdotool, which needs a TCP
port, so this forwards one TCP port per socket:

    python3 -I vnc_bridge.py 5999=/run/fishbowl/x/admin.rfb 5998=/run/fishbowl/x/client.rfb

Only for throwaway test containers: the forwarded ports have no password.
"""
import socket
import sys
import threading


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()


def serve(port, path):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(8)
    while True:
        client, _ = srv.accept()
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            upstream.connect(path)
        except OSError:
            client.close()      # that window isn't open
            continue
        threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


def main():
    threads = []
    for arg in sys.argv[1:]:
        port, path = arg.split("=", 1)
        t = threading.Thread(target=serve, args=(int(port), path), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
