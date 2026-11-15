#!/usr/bin/env bash
# Build-time gate: the image must carry MySQL 8.4.x and Java 21, nothing else.
# Fishbowl Server rejects MySQL 9.x / MariaDB, and its installer rejects any Java but 21.
set -euo pipefail

die() { printf '\nBUILD STOPPED: %s\n\n' "$*" >&2; exit 1; }

mysqld_ver="$(mysqld --version 2>&1 || true)"
[[ "$mysqld_ver" =~ Ver[[:space:]]+8\.4\.[0-9]+ ]] ||
  die "mysqld must be MySQL 8.4.x; this build got: ${mysqld_ver:-nothing}"
[[ "$mysqld_ver" != *MariaDB* ]] || die "mysqld is MariaDB, which Fishbowl rejects: $mysqld_ver"

client_ver="$(mysql --version 2>&1 || true)"
[[ "$client_ver" =~ 8\.4\.[0-9]+ ]] || die "the mysql client must be 8.4.x; got: ${client_ver:-nothing}"
command -v mysqldump >/dev/null || die "mysqldump is missing"

java_bin=/usr/lib/jvm/temurin-21-jdk/bin/java
[ -x "$java_bin" ] || die "$java_bin is missing"
java_ver="$("$java_bin" -version 2>&1 | head -n 1)"
[[ "$java_ver" =~ \"21(\.[0-9]+)*\" ]] || die "Java must be 21; $java_bin reports: $java_ver"
path_java="$(java -version 2>&1 | head -n 1)"
[[ "$path_java" =~ \"21(\.[0-9]+)*\" ]] || die "java on PATH must be 21; it reports: $path_java"

echo "Runtime check passed: ${mysqld_ver##*/} | $java_ver"
