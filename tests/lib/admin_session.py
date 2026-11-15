#!/usr/bin/env python3
"""Run `docker exec -it <container> fishbowl-admin` and create a database through it.

usage: admin_session.py --name CONTAINER --password MYSQL_PW --db NAME --vnc-port 15900 --out DIR
"""
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from pty_session import Session  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--vnc-port", default="15900")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    s = Session(["docker", "exec", "-it", a.name, "fishbowl-admin"], os.path.join(a.out, "admin.transcript"))
    m = s.expect(r"Session password:\s+(\S{8})", 120)
    vnc_password = m.group(1).decode()
    subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "gui_create_db.py"),
                    "--vnc", f"127.0.0.1::{a.vnc_port}", "--vnc-password", vnc_password,
                    "--db", a.db, "--mysql-password", a.password, "--container", a.name,
                    "--shots", os.path.join(a.out, "shots")], check=True)
    s.expect(r"session ended", 120)
    rc = s.wait_exit(60)
    print(f"fishbowl-admin exited with {rc}")
    sys.exit(0 if rc == 0 else 1)


if __name__ == "__main__":
    main()
