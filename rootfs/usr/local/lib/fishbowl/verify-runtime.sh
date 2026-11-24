#!/usr/bin/env bash
# Build-time gate: the image must carry what its part of Fishbowl needs, at the
# versions Fishbowl accepts. Fishbowl Server rejects MySQL 9.x and MariaDB, and
# its installer rejects any Java but 21.
#
#   verify-runtime.sh [all|server|page|desktop]
#
#   all      the single container (default): MySQL 8.4 server and client, Java 21,
#            the browser-window pieces and noVNC
#   server   the Compose stack's Fishbowl Server: Java 21, the MySQL 8.4 client tools
#   page     the Compose stack's Fishbowl page: Python 3.9 or newer, noVNC
#   desktop  the Compose stack's windows: Java 21, the MySQL 8.4 client tools
#            (Server Administration's backups and restores use them), Xvnc,
#            openbox, websockify, the Client's web view libraries
#
# update-all.sh runs it after every package update, with the part from
# FISHBOWL_VERIFY_PART.
set -euo pipefail

die() { printf '\nBUILD STOPPED: %s\n\n' "$*" >&2; exit 1; }

part="${1:-all}"
case "$part" in all|server|page|desktop) ;; *) die "verify-runtime.sh: unknown part '$part' (all, server, page or desktop)" ;; esac

found=()

check_python() {
  local v
  v="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>&1 || true)"
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null ||
    die "python3 must be 3.9 or newer (the page's server and the settings helpers need it); got: ${v:-nothing}"
  found+=("Python $v")
}

check_mysqld() {
  local v
  v="$(mysqld --version 2>&1 || true)"
  [[ "$v" =~ Ver[[:space:]]+8\.4\.[0-9]+ ]] || die "mysqld must be MySQL 8.4.x; this build got: ${v:-nothing}"
  [[ "$v" != *MariaDB* ]] || die "mysqld is MariaDB, which Fishbowl rejects: $v"
  found+=("${v##*/}")
}

check_mysql_client() {
  local v ver tool
  v="$(mysql --version 2>&1 || true)"
  [[ "$v" =~ 8\.4\.[0-9]+ ]] || die "the mysql client must be 8.4.x; got: ${v:-nothing}"
  ver="${BASH_REMATCH[0]}"
  for tool in mysqldump mysqladmin; do
    "$tool" --version 2>&1 | grep -qE '8\.4\.[0-9]+' || die "$tool is missing or isn't 8.4.x"
  done
  found+=("mysql client $ver")
}

check_java() {
  local java_home="${JAVA_HOME:-/usr/lib/jvm/temurin-21-jdk}" v path_v
  [ -x "$java_home/bin/java" ] || die "$java_home/bin/java is missing (JAVA_HOME)"
  v="$("$java_home/bin/java" -version 2>&1 | head -n 1)"
  [[ "$v" =~ \"21(\.[0-9]+)*\" ]] || die "Java must be 21; $java_home/bin/java reports: $v"
  path_v="$(java -version 2>&1 | head -n 1)"
  [[ "$path_v" =~ \"21(\.[0-9]+)*\" ]] || die "java on PATH must be 21; it reports: $path_v"
  found+=("$v")
}

check_windows() {
  local tool lib
  for tool in Xvnc openbox websockify; do
    command -v "$tool" >/dev/null || die "$tool is missing (needed to show Fishbowl's windows in the browser)"
  done
  # The windows listen on Unix sockets only (fishbowl-session), which websockify
  # can do from 0.12.0 on.
  websockify --help 2>&1 | grep -q -- '--unix-listen-mode' ||
    die "websockify can't listen on a Unix socket (it needs 0.12.0 or newer): $(command -v websockify)"
  for lib in libgtk-3.so.0 libnss3.so libnspr4.so; do
    ldconfig -p | grep -q "$lib" || die "$lib is missing (the Fishbowl Client's built-in web view needs it)"
  done
  found+=("Xvnc, openbox, websockify")
}

check_novnc() {
  [ -f /usr/share/novnc/core/rfb.js ] || die "noVNC's core/rfb.js is missing from /usr/share/novnc (the novnc package changed its layout?)"
  found+=("noVNC")
}

case "$part" in
  all)     check_mysqld; check_mysql_client; check_java; check_windows; check_novnc; check_python ;;
  server)  check_java; check_mysql_client; check_python ;;
  page)    check_python; check_novnc ;;
  desktop) check_java; check_mysql_client; check_windows; check_python ;;
esac

# The single image's line stays as it always was; the stack's images name their part.
if [ "$part" = all ]; then printf 'Runtime check passed: '; else printf 'Runtime check passed (%s image): ' "$part"; fi
( IFS='|'; printf '%s\n' "${found[*]}" ) | sed 's/|/ | /g'
