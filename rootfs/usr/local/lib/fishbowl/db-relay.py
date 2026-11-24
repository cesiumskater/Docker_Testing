"""db-relay: MySQL on "localhost" in the Compose stack's desktop container.

Server Administration's new-database dialog fills in Host "localhost", as it
does on any single computer, and its Restore tab runs MySQL's own client against
the same host. In the stack, MySQL is the db container, so this relays
127.0.0.1:3306 (inside the desktop container only; nothing else can reach it) to
the database container, and Server Administration works exactly as in the single
container: leave Host as "localhost". Fishbowl's settings then say "localhost";
the entrypoint points them at the database container before Fishbowl Server
starts (db_point_fishbowl).

    python3 -I db-relay.py LISTEN_HOST LISTEN_PORT TARGET_HOST TARGET_PORT

Bytes are copied both ways, unchanged: MySQL's own sign-in and encryption pass
straight through. Standard library only.
"""
import socket
import sys
import threading
import time


def log(msg):
    sys.stdout.write("%s [db-relay] %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg))
    sys.stdout.flush()


def pipe(src, dst):
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


def serve(client, target):
    try:
        upstream = socket.create_connection(target, timeout=10)
        upstream.settimeout(None)
    except OSError as e:
        log("can't reach the database container at %s:%d: %s" % (target[0], target[1], e))
        client.close()
        return
    t = threading.Thread(target=pipe, args=(upstream, client), daemon=True)
    t.start()
    pipe(client, upstream)
    t.join()
    client.close()
    upstream.close()


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: db-relay.py LISTEN_HOST LISTEN_PORT TARGET_HOST TARGET_PORT")
    listen = (sys.argv[1], int(sys.argv[2]))
    target = (sys.argv[3], int(sys.argv[4]))
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(listen)
    srv.listen(32)
    log("MySQL on %s:%d is the database container (%s:%d)" % (listen + target))
    while True:
        client, _ = srv.accept()
        threading.Thread(target=serve, args=(client, target), daemon=True).start()


if __name__ == "__main__":
    main()
