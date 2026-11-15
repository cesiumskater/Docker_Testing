#!/usr/bin/env python3
"""Java .properties helper (eve.properties and install4j response files).

  props.py get FILE KEY   print the value of KEY (exit 1 if absent or empty)
  props.py escape         read a value on stdin, print it escaped for a .properties file

Values never travel on the command line: `escape` reads stdin, `get` prints to
stdout for the caller to capture.
"""
import sys


def _unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        i += 1
        if i >= len(s):
            break
        c = s[i]
        if c == "u" and i + 4 < len(s) + 1:
            try:
                out.append(chr(int(s[i + 1:i + 5], 16)))
                i += 5
                continue
            except ValueError:
                pass
        out.append({"t": "\t", "n": "\n", "r": "\r", "f": "\f"}.get(c, c))
        i += 1
    return "".join(out)


def _logical_lines(text):
    buf = ""
    for raw in text.splitlines():
        line = raw.lstrip() if not buf else raw.lstrip()
        if not buf and (not line or line[0] in "#!"):
            continue
        # A line continues if it ends with an odd number of backslashes.
        n = len(line) - len(line.rstrip("\\"))
        if n % 2 == 1:
            buf += line[:-1]
            continue
        yield buf + line
        buf = ""
    if buf:
        yield buf


def parse(path):
    with open(path, "rb") as f:
        text = f.read().decode("latin-1")
    props = {}
    for line in _logical_lines(text):
        key_end, i = None, 0
        while i < len(line):
            c = line[i]
            if c == "\\":
                i += 2
                continue
            if c in "=: \t\f":
                key_end = i
                break
            i += 1
        if key_end is None:
            key, value = line, ""
        else:
            key = line[:key_end]
            rest = line[key_end:].lstrip(" \t\f")
            if rest[:1] in ("=", ":"):
                rest = rest[1:].lstrip(" \t\f")
            value = rest
        props[_unescape(key)] = _unescape(value)
    return props


def escape(value):
    out = []
    for i, c in enumerate(value):
        if c == "\\":
            out.append("\\\\")
        elif c == "\n":
            out.append("\\n")
        elif c == "\r":
            out.append("\\r")
        elif c == "\t":
            out.append("\\t")
        elif c == " " and i == 0:
            out.append("\\ ")
        elif c in "#!=:" and i == 0:
            out.append("\\" + c)
        elif ord(c) < 0x20 or ord(c) > 0x7E:
            out.append("\\u%04x" % ord(c) if ord(c) <= 0xFFFF else
                       "".join("\\u%04x" % u for u in
                               (0xD800 + ((ord(c) - 0x10000) >> 10), 0xDC00 + ((ord(c) - 0x10000) & 0x3FF))))
        else:
            out.append(c)
    return "".join(out)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "get":
        value = parse(sys.argv[2]).get(sys.argv[3], "")
        if not value:
            sys.exit(1)
        sys.stdout.write(value + "\n")
    elif len(sys.argv) == 2 and sys.argv[1] == "escape":
        sys.stdout.write(escape(sys.stdin.read().rstrip("\n")))
    else:
        sys.stderr.write(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
