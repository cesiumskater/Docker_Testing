#!/usr/bin/env bash
# Runs the acceptance checks for this image and prints PASS/FAIL for each.
#
#   bash tests/run-checks.sh --installer ~/Downloads/Fishbowl-2026.10.sh
#   bash tests/run-checks.sh --image fishbowl --only runtime
#
# Options
#   --installer FILE  A Fishbowl Linux installer. A local stand-in for the GitHub
#                     release serves it, so the build and upgrade checks run
#                     without touching GitHub. Needed unless --only runtime
#                     together with --image.
#   --image IMAGE     Test this image instead of building one (runtime checks).
#   --only GROUP      unit | build | runtime | update | upgrade | reference
#                     (default: all). "unit" needs neither Docker nor an
#                     installer: the watchdog's probe, the log streaming and the
#                     Java repository file, in plain Python.
#   --reference-sql FILE
#                     A known-good backup made by Fishbowl (a .sql from Backup
#                     Database or the Schedule module). The reference checks
#                     restore it through the page and Server Administration, the
#                     way a person would, and compare the result with a direct
#                     load of the same file. Without it they're skipped. The
#                     file is only read; it stays out of the repository.
#   --keep            Keep the test containers, volumes, images and logs afterwards.
#
# Environment
#   FBCHECK_BUILD_ARGS  extra `docker build` arguments, e.g. a different
#                       FEDORA_IMAGE behind a TLS-intercepting proxy
#   FBCHECK_RUN_ARGS    extra `docker run` arguments for every test container
#                       that runs the image normally, e.g. the README's hardened
#                       set (--read-only, the three --tmpfs, --cap-drop ALL and
#                       the six --cap-add, no-new-privileges, --pids-limit)
#   VNCDO               path to vncdotool's vncdo (default: the one on PATH)
#   FBCHECK_PYTHON      the Python that has vncdotool and Pillow (default: the
#                       python3 next to vncdo, else python3)
#
# Needs: a Linux Docker host (the build checks use `docker build --network
# host`), python3, and vncdotool for the steps inside Fishbowl Server
# Administration (pip install vncdotool). About 15 GB free disk and 12 GB RAM.
# Takes roughly 25 minutes.
#
# What the checks do: they start throwaway containers named fbcheck-* the way
# the README does (detached, no terminal), fill in the Fishbowl page's forms
# over HTTP, and click through Server Administration over VNC. They accept
# Fishbowl's license agreement in those throwaway trial installations on your
# behalf; run them only if that is acceptable to you. The clicks use positions
# measured in Fishbowl 26.10's Server Administration; a future Fishbowl version
# may move them (see tests/lib/gui.py).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$HERE/lib"
INSTALLER="" IMAGE="" ONLY="all" KEEP=0 REFERENCE_SQL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --installer) INSTALLER="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --reference-sql) REFERENCE_SQL="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
case "$ONLY" in all|unit|build|runtime|update|upgrade|reference) ;; *) echo "--only takes unit, build, runtime, update, upgrade or reference" >&2; exit 2 ;; esac
if [ -n "$REFERENCE_SQL" ] && [ ! -f "$REFERENCE_SQL" ]; then echo "--reference-sql: no such file: $REFERENCE_SQL" >&2; exit 2; fi
if [ "$ONLY" = reference ] && [ -z "$REFERENCE_SQL" ]; then echo "--only reference needs --reference-sql FILE" >&2; exit 2; fi
export VNCDO="${VNCDO:-$(command -v vncdo || true)}"
PYTHON="${FBCHECK_PYTHON:-}"
if [ -z "$PYTHON" ] && [ -n "$VNCDO" ] && [ -x "$(dirname "$VNCDO")/python3" ]; then PYTHON="$(dirname "$VNCDO")/python3"; fi
PYTHON="${PYTHON:-python3}"
WORK="$(mktemp -d /tmp/fbcheck.XXXXXX)"
PASSES=0 FAILS=0
RESULTS=()
# The image sets MySQL's root password itself (nobody chooses one); the checks read
# it from the same file the image does. It holds ^ $ % ! = on purpose.
PW="$(cat "$REPO/rootfs/usr/local/lib/fishbowl/mysql-root-password.txt")"
PORT_BASE=47000
MOCK_PIDS=()

pass() { PASSES=$((PASSES+1)); RESULTS+=("PASS  $*"); echo "PASS  $*"; }
fail() { FAILS=$((FAILS+1)); RESULTS+=("FAIL  $*"); echo "FAIL  $*"; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
want() { [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]; }

cleanup() {
  local p
  for p in "${MOCK_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  if [ "$KEEP" = 0 ] && [ "$ONLY" = unit ]; then
    rm -rf "$WORK"
  elif [ "$KEEP" = 0 ]; then
    docker ps -aq --filter name=fbcheck- | xargs -r docker rm -f -v >/dev/null 2>&1
    docker volume ls -q --filter name=fbcheck- | xargs -r docker volume rm >/dev/null 2>&1
    docker images -q --filter reference='fbcheck/*' | sort -u | xargs -r docker image rm -f >/dev/null 2>&1
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

mock() {  # mock <port> <assets-dir> [extra args]
  local port="$1" dir="$2"; shift 2
  python3 -I "$LIB/mock_github.py" --assets "$dir" --port "$port" "$@" >/dev/null 2>&1 &
  MOCK_PIDS+=("$!"); sleep 1
}
build() {  # build <tag> <mock-port> [--target installer]
  local tag="$1" port="$2"; shift 2
  # shellcheck disable=SC2086  # FBCHECK_BUILD_ARGS is a list of arguments
  docker build --network host --progress=plain --build-arg GITHUB_API_URL="http://127.0.0.1:$port" \
    ${FBCHECK_BUILD_ARGS:-} "$@" -t "$tag" "$REPO" > "$WORK/build-${tag//[:\/]/_}.log" 2>&1
}
# The checks that need a running container are in tests/lib/scenarios.py; it
# prints one PASS/FAIL line per check.
scenarios() {  # scenarios runtime|upgrade [extra args]
  local group="$1" line; shift
  while IFS= read -r line; do
    case "$line" in
      "PASS  "*) pass "${line#PASS  }" ;;
      "FAIL  "*) fail "${line#FAIL  }" ;;
      *) echo "$line" ;;
    esac
  done < <("$PYTHON" "$LIB/scenarios.py" "$group" --image "$IMAGE" --password "$PW" \
             --port $((PORT_BASE+10)) --work "$WORK/$group" "$@" 2>"$WORK/$group.stderr")
}

# ---------------------------------------------------------------- unit -----
if want unit; then
  echo "== unit checks (no Docker)"
  if python3 -I -m unittest discover -s "$HERE/unit" -t "$HERE/unit" > "$WORK/unit.log" 2>&1; then
    pass "unit checks: probe.py, logstream.py, adoptium-repo.py"
  else
    tail -n 20 "$WORK/unit.log"
    fail "unit checks (python3 -I -m unittest discover -s tests/unit -v shows which)"
  fi
  [ "$ONLY" = unit ] && { echo "passed: $PASSES  failed: $FAILS"; [ "$FAILS" = 0 ]; exit; }
fi

# ---------------------------------------------------------------- build ----
if want build || want upgrade || [ -z "$IMAGE" ]; then
  { [ -n "$INSTALLER" ] && [ -f "$INSTALLER" ]; } || { echo "--installer FILE is required (build and upgrade checks, or no --image)" >&2; exit 2; }
  VER="$(basename "$INSTALLER" | sed -E 's/^Fishbowl-(.*)\.sh$/\1/')"
  mkdir -p "$WORK/one" "$WORK/zero" "$WORK/two" "$WORK/next"
  ln -sf "$INSTALLER" "$WORK/one/Fishbowl-$VER.sh"
  echo "not an installer" > "$WORK/zero/README.txt"
  ln -sf "$INSTALLER" "$WORK/two/Fishbowl-$VER.sh"; ln -sf "$INSTALLER" "$WORK/two/Fishbowl-0.1.sh"
  ln -sf "$INSTALLER" "$WORK/next/Fishbowl-$VER.1.sh"
  mock $((PORT_BASE+1)) "$WORK/one"; mock $((PORT_BASE+2)) "$WORK/zero"
  mock $((PORT_BASE+3)) "$WORK/two"; mock $((PORT_BASE+4)) "$WORK/next"
fi
if want build || [ -z "$IMAGE" ]; then
  echo "== building fbcheck/fishbowl:$VER (a few minutes)"
  if build "fbcheck/fishbowl:$VER" $((PORT_BASE+1)); then
    pass "build: one installer on the release -> image builds"
    # The gate is a RUN step, so a cached build doesn't print it again: run the
    # same script in the image, then with a wrong mysqld / java on PATH.
    gate() { docker run --rm --entrypoint bash "fbcheck/fishbowl:$VER" -c \
      "mkdir -p /tmp/stub && $1 PATH=/tmp/stub:\$PATH bash /usr/local/lib/fishbowl/verify-runtime.sh" 2>&1; }
    out="$(gate '')"
    # shellcheck disable=SC2016  # $1 expands in the inner bash
    check "build: image proves MySQL 8.4.x and Java 21" \
      bash -c '[[ "$1" =~ Runtime\ check\ passed:\ .*Ver\ 8\.4\.[0-9]+.*\"21 ]]' _ "$out"
    out="$(gate 'printf "#!/bin/sh\necho \"mysqld  Ver 9.7.0 for Linux on x86_64\"\n" > /tmp/stub/mysqld && chmod +x /tmp/stub/mysqld &&')"
    check "build gate stops on MySQL 9.x" grep -q "BUILD STOPPED: mysqld must be MySQL 8.4.x" <<<"$out"
    out="$(gate 'printf "#!/bin/sh\necho \"openjdk version \\\"17.0.12\\\"\" >&2\n" > /tmp/stub/java && chmod +x /tmp/stub/java &&')"
    check "build gate stops on Java other than 21" grep -q "BUILD STOPPED: java on PATH must be 21" <<<"$out"
    check "image reports its Fishbowl version for tagging" \
      test "$(docker run --rm "fbcheck/fishbowl:$VER" version 2>/dev/null)" = "$VER"
    check "image publishes ports 2456, 28192 and 6080 and declares its three volumes" bash -c \
      "docker inspect -f '{{json .Config.ExposedPorts}} {{json .Config.Volumes}}' 'fbcheck/fishbowl:$VER' | grep -q '2456/tcp.*28192/tcp.*6080/tcp.*/opt/Fishbowl.*/var/lib/fishbowl.*/var/lib/mysql'"
    # No database ships in the image: the folders that become the volumes hold no
    # files (Docker would copy them into a new volume), and the only .sql files
    # anywhere are the ones Fedora's own packages installed (rpm owns those).
    # shellcheck disable=SC2016  # expands inside the container
    check "image ships no database: its volume folders hold no files, and no .sql backup is in it" \
      docker run --rm --entrypoint bash "fbcheck/fishbowl:$VER" -c '
        f="$(find /var/lib/mysql /opt/Fishbowl /var/lib/fishbowl -mindepth 1 ! -type d 2>/dev/null | head -1)"
        [ -z "$f" ] || { echo "file in a volume folder: $f"; exit 1; }
        find / -xdev \( -path /proc -o -path /sys \) -prune -o -type f \( -iname "*.sql" -o -iname "*.sql.gz" \) -print 2>/dev/null |
          while IFS= read -r f; do rpm -qf "$f" >/dev/null 2>&1 || { echo "not from a package: $f"; exit 1; }; done'
  else
    fail "build: one installer on the release -> image builds (log: $WORK)"
  fi
  [ -z "$IMAGE" ] && IMAGE="fbcheck/fishbowl:$VER"
fi
if want build; then
  build fbcheck/fail $((PORT_BASE+2)) --target installer
  check "build: zero installers -> clear failure" grep -q "No Fishbowl installer found" "$WORK/build-fbcheck_fail.log"
  build fbcheck/fail $((PORT_BASE+3)) --target installer
  check "build: two installers -> clear failure" grep -q "Found 2 Fishbowl installers" "$WORK/build-fbcheck_fail.log"
  # Swapping the asset needs no Dockerfile edit: same command, new version.
  mv "$WORK/one/Fishbowl-$VER.sh" "$WORK/one/Fishbowl-$VER.9.sh"
  build fbcheck/swap $((PORT_BASE+1))
  check "build: replaced asset -> same command builds the new version" \
    test "$(docker run --rm --entrypoint cat fbcheck/swap /opt/fishbowl-installer/VERSION 2>/dev/null)" = "$VER.9"
  mv "$WORK/one/Fishbowl-$VER.9.sh" "$WORK/one/Fishbowl-$VER.sh"
  docker image rm fbcheck/swap fbcheck/fail >/dev/null 2>&1
fi

# ------------------------------------------------- runtime and upgrade -----
if want runtime || want update || want upgrade || want reference; then
  [ -n "$IMAGE" ] || { echo "no image to test" >&2; exit 2; }
  [ -n "$VNCDO" ] || { echo "vncdotool not found (pip install vncdotool, or set VNCDO)" >&2; exit 2; }
  "$PYTHON" -c 'import PIL' 2>/dev/null ||
    { echo "$PYTHON has no Pillow (it comes with vncdotool); set FBCHECK_PYTHON to the Python that has it" >&2; exit 2; }
  docker ps -aq --filter name=fbcheck- | xargs -r docker rm -f -v >/dev/null 2>&1
fi
if want runtime; then
  echo "== runtime checks on $IMAGE"
  docker volume ls -q --filter name=fbcheck- | xargs -r docker volume rm >/dev/null 2>&1
  scenarios runtime
fi
if want update; then
  echo "== system update checks (the last one needs the Fedora repositories, so network access)"
  scenarios update
fi
if want reference; then
  if [ -n "$REFERENCE_SQL" ]; then
    echo "== reference restore checks with $(basename "$REFERENCE_SQL")"
    scenarios reference --reference-sql "$REFERENCE_SQL"
  else
    echo "== reference restore checks skipped (no --reference-sql FILE)"
  fi
fi
if want upgrade; then
  echo "== upgrade checks"
  NEXT="fbcheck/fishbowl:next"
  if build "$NEXT" $((PORT_BASE+4)); then
    scenarios upgrade --next "$NEXT"
  else
    fail "build of the newer test image (log: $WORK)"
  fi
fi

echo
echo "================ summary ================"
printf '%s\n' "${RESULTS[@]}"
echo "passed: $PASSES  failed: $FAILS   (logs: $WORK$([ "$KEEP" = 0 ] && echo ', removed on exit; use --keep to keep them'))"
[ "$FAILS" = 0 ]
