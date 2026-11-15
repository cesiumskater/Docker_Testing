#!/usr/bin/env python3
"""Create a Fishbowl company database through Server Administration over VNC.

This is the step a person does in the browser (noVNC). The test does the same
clicks over plain VNC with the session's one-time password, using vncdotool
(pip install vncdotool). Coordinates match the 1280x800 virtual screen that
fishbowl-admin starts. Defaults in Fishbowl's wizard are kept (United States,
Average Costing): fine for a throwaway test database, not for real use.

usage: gui_create_db.py --vnc 127.0.0.1::15900 --vnc-password XXXXXXXX
                        --db NAME --mysql-password PW --container NAME --shots DIR
"""
import argparse
import os
import subprocess
import sys
import time


def vncdo(server, password, *cmds):
    exe = os.environ.get("VNCDO", "vncdo")
    subprocess.run([exe, "-s", server, "-p", password, *cmds], check=True, timeout=120)


def table_count(container, mysql_password, db):
    r = subprocess.run(
        ["docker", "exec", "-e", "MYSQL_PWD=" + mysql_password, container,
         "mysql", "--protocol=tcp", "-h127.0.0.1", "-uroot", "-N", "-B", "-e",
         f"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='{db}'"],
        capture_output=True, text=True)
    try:
        return int(r.stdout.strip() or 0)
    except ValueError:
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vnc", required=True)
    ap.add_argument("--vnc-password", required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--mysql-password", required=True)
    ap.add_argument("--container", required=True)
    ap.add_argument("--shots", required=True)
    a = ap.parse_args()
    os.makedirs(a.shots, exist_ok=True)
    shot = lambda n: os.path.join(a.shots, n)
    v = lambda *c: vncdo(a.vnc, a.vnc_password, *c)

    # Wait for the Server Administration window to be drawn.
    time.sleep(15)
    v("capture", shot("01-admin.png"))
    v("move", "955", "213", "click", "1", "pause", "3", "capture", shot("02-add-form.png"))
    v("move", "660", "270", "click", "1", "pause", "0.5", "type", a.db)
    v("move", "660", "369", "click", "1", "pause", "0.5", "key", "ctrl-a", "key", "bsp")
    v("type", a.mysql_password, "pause", "0.5", "capture", shot("03-filled.png"))
    v("move", "659", "578", "click", "1", "pause", "20", "capture", shot("04-wizard.png"))
    v("move", "734", "600", "click", "1")
    deadline = time.time() + 900
    n = 0
    while time.time() < deadline:
        time.sleep(10)
        n = table_count(a.container, a.mysql_password, a.db)
        if n >= 300:
            break
    print(f"database {a.db}: {n} tables", flush=True)
    if n < 300:
        v("capture", shot("05-timeout.png"))
        sys.exit("database creation did not finish")
    time.sleep(20)
    v("capture", shot("05-created.png"))
    v("move", "788", "649", "click", "1", "pause", "6", "capture", shot("06-saved.png"))
    try:  # "Database Connection has been changed" dialog; the session may already be closing
        v("move", "640", "426", "click", "1", "pause", "3")
    except subprocess.CalledProcessError:
        pass


if __name__ == "__main__":
    main()
