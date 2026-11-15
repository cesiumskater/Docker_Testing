#!/usr/bin/env python3
"""Drive an interactive first start end to end, like a person would:
EULA -> license key or trial -> company name -> MySQL root password ->
unattended install -> create the database in Server Administration (over VNC)
-> Fishbowl Server running. Leaves the container running (detach with --detach).

usage: first_run.py --image IMG --name NAME --vol PREFIX --password PW
                    [--key KEY --company NAME] [--db NAME] --out DIR
"""
import argparse
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from pty_session import Session  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--vol", required=True, help="volume name prefix: <vol>-mysql, <vol>-app, <vol>-data")
    ap.add_argument("--password", required=True)
    ap.add_argument("--key", default="")
    ap.add_argument("--company", default="")
    ap.add_argument("--db", default="fbtest")
    ap.add_argument("--client-port", default="12456")
    ap.add_argument("--novnc-port", default="16080")
    ap.add_argument("--vnc-port", default="15900")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    argv = ["docker", "run", "-it", "--rm", "--name", a.name,
            "-p", f"127.0.0.1:{a.client_port}:2456",
            "-p", f"127.0.0.1:{a.novnc_port}:6080",
            "-p", f"127.0.0.1:{a.vnc_port}:5900",
            "-v", f"{a.vol}-mysql:/var/lib/mysql",
            "-v", f"{a.vol}-app:/opt/Fishbowl",
            "-v", f"{a.vol}-data:/var/lib/fishbowl",
            a.image]
    t0 = time.time()
    s = Session(argv, os.path.join(a.out, "first-run.transcript"))
    prompts = []

    def step(pattern, answer=None, timeout=120, secret=False):
        s.expect(pattern, timeout)
        prompts.append(pattern)
        if answer is not None:
            s.sendline(answer)

    step(r"Press Enter to open the license agreement", "")
    s.expect(r"SOFTWARE SUBSCRIPTION TERMS AND CONDITIONS", 30)
    s.expect(r"q when done", 30)
    s.send("q")
    step(r'Type "yes" to accept: ', "yes")
    if a.key:
        step(r"License key \(or trial\): ", a.key, secret=True)
        step(r"Is that right\? \[y/N\] ", "y")
        step(r"Company name: ", a.company)
    else:
        step(r"License key \(or trial\): ", "trial", secret=True)
        s.expect(r"Using the 14 Day Fishbowl Trial", 10)
    step(r"MySQL root password: ", a.password, secret=True)
    step(r"Type it again: ", a.password, secret=True)
    s.expect(r"Ready to install\. No more questions", 30)
    t_answers = time.time()
    s.expect(r"Fishbowl [0-9.]+ is installed\.", 900)
    t_installed = time.time()
    m = s.expect(r"Session password:\s+(\S{8})", 300)
    vnc_password = m.group(1).decode()
    print(f"answers done after {t_answers - t0:.0f}s; installed after {t_installed - t_answers:.0f}s more", flush=True)

    env = dict(os.environ)
    subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "gui_create_db.py"),
                    "--vnc", f"127.0.0.1::{a.vnc_port}", "--vnc-password", vnc_password,
                    "--db", a.db, "--mysql-password", a.password, "--container", a.name,
                    "--shots", os.path.join(a.out, "shots")], check=True, env=env)
    m = s.expect(r"Fishbowl Server is running \(heap ([0-9]+[MG]?)\)", 600)
    print(f"server running, heap {m.group(1).decode()}; total {time.time() - t0:.0f}s", flush=True)
    with open(os.path.join(a.out, "prompts.txt"), "w") as f:
        f.write("\n".join(prompts) + "\n")
    # Detach (Ctrl-P Ctrl-Q) so the container keeps running; closing the terminal
    # instead would hang it up, which stops the container (cleanly).
    s.send(b"\x10\x11")
    time.sleep(2)
    s.transcript.close()
    os._exit(0)


if __name__ == "__main__":
    main()
