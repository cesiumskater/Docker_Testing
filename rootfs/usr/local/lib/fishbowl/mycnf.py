#!/usr/bin/env python3
"""Print Fishbowl's server/bin/my.cnf ready to load as a MySQL option file.

Keeps Fishbowl's tuning (buffer pool, connections, packet size, ...) but
comments out the two settings the install guide controls, which live in
/etc/my.cnf.d/90-fishbowl.cnf:

  * sql-mode                -> the guide's STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION
  * lower_case_table_names  -> must stay 1 (fixed when the data directory was created)

It also reports, on stderr, what Fishbowl's file asked for, and refuses
NO_AUTO_CREATE_USER outright (MySQL 8 will not start with it).
"""
import re
import sys

GUIDE_KEYS = {"sql-mode", "sql_mode", "lower_case_table_names", "lower-case-table-names"}


def main(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    out = [
        "# Generated at container start from /opt/Fishbowl/server/bin/my.cnf",
        "# (Fishbowl's MySQL tuning). sql-mode and lower_case_table_names are",
        "# commented out: the install guide's values in 90-fishbowl.cnf apply.",
        "",
    ]
    for line in lines:
        m = re.match(r"\s*([A-Za-z0-9_-]+)\s*(?:=\s*(.*))?$", line)
        key = m.group(1).lower() if m else ""
        if key in GUIDE_KEYS:
            value = (m.group(2) or "").strip().strip('"').strip("'")
            if "NO_AUTO_CREATE_USER" in value.upper():
                sys.stderr.write("[mycnf] Fishbowl's my.cnf lists NO_AUTO_CREATE_USER in sql-mode; "
                                 "MySQL 8 refuses that, so it is not loaded.\n")
            if key.startswith("lower") and value not in ("", "1"):
                sys.stderr.write(f"[mycnf] Fishbowl's my.cnf sets lower_case_table_names={value}; "
                                 "the container keeps 1.\n")
            out.append("# (guide controls this) " + line)
        else:
            out.append(line)
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
