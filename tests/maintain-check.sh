#!/usr/bin/env bash
#
# Checks tools/fishbowl-maintain.sh end to end, on a real Fishbowl container run
# by Compose, the way a scheduled task runs it:
#
#   1. a normal run: new image, backup, recreate, back in the same state;
#   2. a run whose new image never comes back: it rolls back to the previous image.
#
#   bash tests/maintain-check.sh --installer ~/Downloads/Fishbowl-2026.10.sh
#
# It uses the real names the script works with (container and image "fishbowl"),
# so it refuses to run where a container named fishbowl exists. It accepts
# Fishbowl's license agreement in a throwaway trial installation, as the other
# checks do. Needs a Linux Docker host, python3, and about 10 GB of free disk.
#
# Environment: FBCHECK_BUILD_ARGS as for run-checks.sh (only FEDORA_IMAGE is
# passed on, as FEDORA_IMAGE=...).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSTALLER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --installer) INSTALLER="${2:-}"; shift 2 ;;
    *) echo "usage: maintain-check.sh --installer FILE" >&2; exit 2 ;;
  esac
done
[ -f "$INSTALLER" ] || { echo "--installer FILE is required" >&2; exit 2; }
if docker inspect fishbowl >/dev/null 2>&1; then
  echo "A container named fishbowl exists here; this check would replace it. Stopping." >&2; exit 2
fi

FEDORA="$(printf '%s\n' "${FBCHECK_BUILD_ARGS:-}" | grep -oE 'FEDORA_IMAGE=[^ ]+' | cut -d= -f2)"
WORK="$(mktemp -d /tmp/fbmaint.XXXXXX)"
PORT=47900
PASSED=0; FAILED=0
pass() { echo "PASS  $*"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL  $*"; FAILED=$((FAILED + 1)); }

cleanup() {
  (cd "$WORK/site" 2>/dev/null && docker compose down -t 60 >/dev/null 2>&1)
  docker volume rm -f fbmaint-mysql fbmaint-app fbmaint-data >/dev/null 2>&1
  docker image rm -f fishbowl fishbowl:previous fishbowl:failed fishbowl:candidate >/dev/null 2>&1
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# The installer, served the way GitHub's release would serve it.
mkdir -p "$WORK/one" "$WORK/site"
ln -s "$INSTALLER" "$WORK/one/$(basename "$INSTALLER")"
python3 -I "$HERE/lib/mock_github.py" --assets "$WORK/one" --port "$PORT" >/dev/null 2>&1 &
MOCK_PID=$!
sleep 1

# The repository's compose.yaml, built from this checkout instead of GitHub, on
# volumes of its own and ports that stay off the usual ones.
python3 -I - "$REPO/compose.yaml" "$WORK/site/compose.yaml" "$REPO" "$PORT" "$FEDORA" <<'PY'
import sys
src, dst, repo, port, fedora = sys.argv[1:6]
s = open(src).read()
build = ("build:\n      context: %s\n      network: host\n      args:\n"
         "        GITHUB_API_URL: http://127.0.0.1:%s\n" % (repo, port))
if fedora:
    build += "        FEDORA_IMAGE: %s\n" % fedora
s = s.replace("build: https://github.com/cesiumskater/Docker_Testing.git#main\n", build)
for v in ("mysql", "app", "data"):
    s = s.replace("name: fishbowl-%s\n" % v, "name: fbmaint-%s\n" % v)
assert "context:" in s and "fbmaint-mysql" in s
open(dst, "w").write(s)
PY
cat > "$WORK/site/.env" <<'EOF'
FB_LAN_IP=127.0.0.1
FB_CLIENT_PORT=47901
FB_API_PORT=47902
FB_PAGE_PORT=47903
EOF
cp "$REPO/tools/fishbowl-maintain.sh" "$WORK/site/"
cd "$WORK/site" || exit 2

echo "== starting Fishbowl with Compose (builds the image)"
# compose.yaml's volumes are external: created once, never by Compose.
for v in mysql app data; do docker volume create "fbmaint-$v" >/dev/null; done
docker compose up -d > "$WORK/up.log" 2>&1 || { tail -n 30 "$WORK/up.log"; fail "docker compose up"; exit 1; }
python3 -I - "$HERE/lib" <<'PY' || { fail "setup on the page"; exit 1; }
import sys, time
sys.path.insert(0, sys.argv[1])
from page import Page, access_code
for _ in range(60):
    try:
        page = Page("http://127.0.0.1:47903"); page.sign_in(access_code("fishbowl")); break
    except Exception:
        time.sleep(3)
page.wait_state("needs-setup", 180)
page.setup()
page.wait_state("awaiting-database", 900)
PY
pass "Compose start and setup: waiting for a database (MySQL running, health not 'healthy')"

image_id()  { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null; }
running_image() { docker inspect --format '{{.Image}}' fishbowl 2>/dev/null; }
state()     { docker exec fishbowl cat /run/fishbowl/status 2>/dev/null; }
built()     { docker exec fishbowl cat /usr/local/share/fishbowl/image-built 2>/dev/null; }

# ---- 1. a normal run
before_image="$(running_image)"; before_built="$(built)"
sleep 2   # image-built has one-second resolution
FB_MAINTAIN_PULL="${FB_MAINTAIN_PULL:-1}" bash fishbowl-maintain.sh > "$WORK/run1.log" 2>&1; rc=$?
sed 's/^/      /' "$WORK/run1.log" | tail -n 12
[ "$rc" = 0 ] && pass "a normal run ends with status 0" || fail "a normal run ended with status $rc"
after_image="$(running_image)"
[ -n "$after_image" ] && [ "$after_image" != "$before_image" ] && [ "$after_image" = "$(image_id fishbowl)" ] &&
  pass "the container runs the new image" || fail "the container's image didn't change ($before_image -> $after_image)"
[ "$(image_id fishbowl:previous)" = "$before_image" ] && pass "the old image is kept as fishbowl:previous" ||
  fail "fishbowl:previous isn't the old image"
[ "$(state)" = awaiting-database ] && pass "back in the same state on the page (awaiting-database)" ||
  fail "state after the run: $(state)"
[ "$(built)" \> "$before_built" ] && pass "the new image's packages are newer ($before_built -> $(built))" ||
  fail "image-built didn't move: $before_built -> $(built)"
docker exec fishbowl sh -c 'ls /var/lib/fishbowl/backups/weekly-maintenance-*.sql.gz' >/dev/null 2>&1 &&
  pass "it took a backup first (weekly-maintenance-*.sql.gz)" || fail "no weekly-maintenance backup"
[ -z "$(image_id fishbowl:candidate)" ] && [ ! -d .fishbowl-maintain.lock ] &&
  pass "no candidate tag and no lock left behind" || fail "a candidate tag or the lock was left behind"

# ---- 2. a new image that never comes back: roll back
good_image="$(running_image)"
cat > Dockerfile.broken <<'EOF'
FROM fishbowl
ARG PACKAGES_REFRESH=
ENTRYPOINT ["sleep", "infinity"]
EOF
python3 -I - <<'PY'
s = open("compose.yaml").read()
s = s.replace("      network: host\n", "      network: host\n      dockerfile: %s/Dockerfile.broken\n" % __import__("os").getcwd())
open("compose.yaml", "w").write(s)
PY
FB_MAINTAIN_PULL=0 FB_MAINTAIN_TIMEOUT=90 bash fishbowl-maintain.sh > "$WORK/run2.log" 2>&1; rc=$?
sed 's/^/      /' "$WORK/run2.log" | tail -n 8
[ "$rc" = 2 ] && pass "a new image that doesn't come back: status 2" || fail "the failing run ended with status $rc"
[ "$(running_image)" = "$good_image" ] && pass "the previous image runs again" || fail "the container doesn't run the previous image"
for _ in $(seq 1 60); do [ "$(state)" = awaiting-database ] && break; sleep 5; done
[ "$(state)" = awaiting-database ] && pass "and it's back in the same state" || fail "state after the rollback: $(state)"
[ -n "$(image_id fishbowl:failed)" ] && ls fishbowl-maintain-failed-*.log >/dev/null 2>&1 &&
  pass "the failed image is kept as fishbowl:failed, its container's log saved next to compose.yaml" ||
  fail "fishbowl:failed or the saved log is missing"

echo "== maintenance checks: $PASSED passed, $FAILED failed"
[ "$FAILED" = 0 ]
