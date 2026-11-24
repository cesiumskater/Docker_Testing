#!/usr/bin/env bash
#
# Checks tools/fishbowl-maintain.sh end to end on the Compose stack, the way a
# scheduled task runs it:
#
#   1. a normal run: new images for every service, a backup, the containers
#      recreated, back in the same state;
#   2. a run whose new Fishbowl Server image never comes back: every image is
#      put back and the stack runs as before.
#
#   bash tests/maintain-check.sh --installer ~/Downloads/Fishbowl-2026.11.sh
#   bash tests/maintain-check.sh --installer ~/Downloads/Fishbowl-2026.11.sh \
#     --powershell mcr.microsoft.com/powershell:latest
#
# With --powershell IMAGE it runs the Windows version, fishbowl-maintain.ps1,
# instead: in PowerShell 7 from IMAGE, with this computer's docker command and
# Compose plugin. That checks the script's logic, not Windows PowerShell 5.1.
#
# It uses the stack's real names (containers fishbowl and fishbowl-*, volumes
# fishbowl-*, images fishbowl-*), so it refuses to run where any of them exists,
# and removes everything it made when it's done. It accepts Fishbowl's license
# agreement in a throwaway trial installation, as the other checks do. Needs a
# Linux Docker host with Docker Compose, python3, and about 15 GB of free disk.
# Takes about half an hour.
#
# Environment:
#   FBCHECK_BUILD_ARGS  as for run-checks.sh. The base images in it (FEDORA_IMAGE,
#                       UBI_IMAGE, DESKTOP_BASE_IMAGE, MYSQL_IMAGE, CADDY_IMAGE,
#                       HAPROXY_IMAGE, ALPINE_IMAGE) go to the stack's builds, and
#                       so does HTTPS_PROXY when it's set.
#   FB_MAINTAIN_PULL    0 when a base image only exists on this computer.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSTALLER=""
PWSH_IMAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --installer) INSTALLER="${2:-}"; shift 2 ;;
    --powershell) PWSH_IMAGE="${2:-}"; shift 2 ;;
    *) echo "usage: maintain-check.sh --installer FILE [--powershell IMAGE]" >&2; exit 2 ;;
  esac
done
[ -f "$INSTALLER" ] || { echo "--installer FILE is required" >&2; exit 2; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose isn't available ('docker compose version' failed)." >&2; exit 2; }
if [ -n "$PWSH_IMAGE" ]; then
  DOCKER_BIN="$(readlink -f "$(command -v docker)")"
  PLUGINS="$(docker info --format '{{range .ClientInfo.Plugins}}{{if eq .Name "compose"}}{{.Path}}{{end}}{{end}}' 2>/dev/null)"
  [ -n "$PLUGINS" ] || { echo "Can't find the Compose plugin's file (docker info)." >&2; exit 2; }
  PLUGINS="$(dirname "$(readlink -f "$PLUGINS")")"
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$DOCKER_BIN:/usr/local/bin/docker:ro" \
      -v "$PLUGINS:/usr/local/lib/docker/cli-plugins:ro" -e HOME=/tmp "$PWSH_IMAGE" \
      pwsh -NoProfile -Command '& docker compose version' >/dev/null 2>&1 ||
    { echo "PowerShell from $PWSH_IMAGE can't run this computer's docker compose." >&2; exit 2; }
fi

HELPERS="page desktop db backup edge edge-tcp egress"
IMAGES="fishbowl-server"; for s in $HELPERS; do IMAGES="$IMAGES fishbowl-$s"; done
VOLS="fishbowl-mysql fishbowl-app fishbowl-data fishbowl-backups fishbowl-dbconf fishbowl-edge"
found="$(docker ps -a --format '{{.Names}}' --filter name='^fishbowl'
         docker volume ls -q --filter name='^fishbowl[-_]'
         for i in $IMAGES; do docker image ls --format '{{.Repository}}:{{.Tag}}' "$i"; done)"
if [ -n "$found" ]; then
  echo "This computer already has a Fishbowl stack's containers, volumes or images, which this check would replace:" >&2
  printf '  %s\n' $found >&2
  echo "Run it on a test computer, or remove them first. Stopping." >&2
  exit 2
fi

WORK="$(mktemp -d /tmp/fbmaint.XXXXXX)"
PORT=47900
PASSED=0; FAILED=0
pass() { echo "PASS  $*"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL  $*"; FAILED=$((FAILED + 1)); }

cleanup() {
  (cd "$WORK/site" 2>/dev/null && docker compose down -t 60 --remove-orphans >/dev/null 2>&1)
  for v in $VOLS fishbowl_fishbowl-ipc; do docker volume rm -f "$v" >/dev/null 2>&1; done
  for i in $IMAGES; do
    docker image ls --format '{{.Repository}}:{{.Tag}}' "$i" | xargs -r docker image rm -f >/dev/null 2>&1
  done
  docker image prune -f --filter "label=org.opencontainers.image.source=https://github.com/cesiumskater/Docker_Testing" >/dev/null 2>&1
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# The installer, served the way GitHub's release would serve it.
mkdir -p "$WORK/one" "$WORK/site/secrets" "$WORK/site/certs"
ln -s "$INSTALLER" "$WORK/one/$(basename "$INSTALLER")"
python3 -I "$HERE/lib/mock_github.py" --assets "$WORK/one" --port "$PORT" >/dev/null 2>&1 &
MOCK_PID=$!
sleep 1

# The repository's compose.yaml, built from this checkout instead of GitHub, on
# ports that stay off the usual ones. A compose.override.yaml hands the builds
# the stand-in release and the base images from FBCHECK_BUILD_ARGS.
cd "$WORK/site" || exit 2
cp "$REPO/compose.yaml" "$REPO/tools/fishbowl-maintain.sh" "$REPO/tools/fishbowl-maintain.ps1" .
cp "$REPO/rootfs/usr/local/lib/fishbowl/mysql-root-password.txt" secrets/
cat > .env <<EOF
FB_SOURCE=$REPO
FB_LAN_IP=127.0.0.1
FB_CLIENT_PORT=47901
FB_API_PORT=47902
FB_PAGE_PORT=47903
FB_HTTPS_PORT=47904
EOF
python3 -I - "$PORT" "${FBCHECK_BUILD_ARGS:-}" "${HTTPS_PROXY:-}" > compose.override.yaml <<'PY'
import re, sys
port, extra, proxy = sys.argv[1:4]
found = dict(re.findall(r"\b(FEDORA_IMAGE|UBI_IMAGE|DESKTOP_BASE_IMAGE|MYSQL_IMAGE|CADDY_IMAGE|HAPROXY_IMAGE|ALPINE_IMAGE)=(\S+)", extra))
fishbowl = ["FEDORA_IMAGE", "UBI_IMAGE", "DESKTOP_BASE_IMAGE", "MYSQL_IMAGE"]
wants = {"fishbowl": fishbowl, "page": fishbowl, "desktop": fishbowl,
         "db": ["MYSQL_IMAGE"], "backup": ["MYSQL_IMAGE"],
         "edge": ["CADDY_IMAGE"], "edge-tcp": ["HAPROXY_IMAGE"], "egress": ["ALPINE_IMAGE"]}
print("services:")
for svc, names in wants.items():
    args = {n: found[n] for n in names if n in found}
    if svc in ("fishbowl", "page", "desktop"):
        args["GITHUB_API_URL"] = "http://127.0.0.1:%s" % port
    if proxy:
        args["HTTPS_PROXY"] = args["https_proxy"] = proxy
    print("  %s:\n    build:\n      network: host" % svc)
    if args:
        print("      args:")
        for k, v in args.items():
            print('        %s: "%s"' % (k, v))
PY
for v in $VOLS; do docker volume create "$v" >/dev/null; done

echo "== starting the stack with Compose (builds every image; a while)"
docker compose up -d > "$WORK/up.log" 2>&1 || { tail -n 30 "$WORK/up.log"; fail "docker compose up"; exit 1; }
python3 -I - "$HERE/lib" <<'PY' || { fail "setup on the page"; exit 1; }
import sys, time
sys.path.insert(0, sys.argv[1])
from page import Page, access_code
page = Page("http://127.0.0.1:47903")
for _ in range(60):
    try:
        if page.sign_in(access_code("fishbowl")):
            break
    except Exception:
        pass
    time.sleep(3)
page.wait_state("needs-setup", 180)
page.setup()
page.wait_state("awaiting-database", 900)
PY
pass "the stack starts and setup runs on the page: waiting for a database"

image_id()      { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null; }
running_image() { docker inspect --format '{{.Image}}' "$1" 2>/dev/null; }
state()         { docker exec fishbowl cat /run/fishbowl/status 2>/dev/null; }
built()         { docker exec fishbowl cat /usr/local/share/fishbowl/image-built 2>/dev/null; }
container()     { [ "$1" = server ] && echo fishbowl || echo "fishbowl-$1"; }
# snapshot NAME: what each container runs now, as NAME_<service>
snapshot() { local s v; for s in server $HELPERS; do v="${s//-/_}"; printf -v "${1}_$v" '%s' "$(running_image "$(container "$s")")"; done; }
# compare A B: services whose image is the same in snapshots A and B
same_in() { local s v a b out=""; for s in server $HELPERS; do v="${s//-/_}"; a="${1}_$v"; b="${2}_$v"; [ "${!a}" = "${!b}" ] && out="$out $s"; done; echo "${out# }"; }

# maintain PULL TIMEOUT: one run of the weekly maintenance, the way the scheduled
# task runs it (fishbowl-maintain.ps1 in PowerShell with --powershell).
maintain() {
  if [ -z "$PWSH_IMAGE" ]; then
    FB_MAINTAIN_PULL="$1" FB_MAINTAIN_TIMEOUT="$2" bash fishbowl-maintain.sh
  else
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$DOCKER_BIN:/usr/local/bin/docker:ro" \
      -v "$PLUGINS:/usr/local/lib/docker/cli-plugins:ro" -v "$WORK:$WORK" -v "$REPO:$REPO:ro" \
      -w "$WORK/site" -e HOME=/tmp -e "FB_MAINTAIN_PULL=$1" -e "FB_MAINTAIN_TIMEOUT=$2" \
      "$PWSH_IMAGE" pwsh -NoProfile -File fishbowl-maintain.ps1
  fi
}
SCRIPT=fishbowl-maintain.sh; [ -n "$PWSH_IMAGE" ] && SCRIPT=fishbowl-maintain.ps1
echo "== the weekly maintenance: $SCRIPT"

# ---- 1. a normal run
snapshot before
before_built="$(built)"
sleep 2   # image-built has one-second resolution
maintain "${FB_MAINTAIN_PULL:-1}" 1200 > "$WORK/run1.log" 2>&1; rc=$?
sed 's/^/      /' "$WORK/run1.log" | tail -n 14
[ "$rc" = 0 ] && pass "a normal run ends with status 0" || fail "a normal run ended with status $rc"
snapshot after1
unchanged="$(same_in before after1)"
[ -z "$unchanged" ] && pass "every container runs a new image (fishbowl, $HELPERS)" ||
  fail "these still run their old image: $unchanged"
kept=""; for s in server $HELPERS; do v="before_${s//-/_}"; [ "$(image_id "fishbowl-$s:previous")" = "${!v}" ] || kept="$kept $s"; done
[ -z "$kept" ] && pass "every old image is kept as :previous" || fail "no right :previous for:$kept"
[ "$(state)" = awaiting-database ] && pass "back in the same state on the page (awaiting-database)" ||
  fail "state after the run: $(state)"
[ "$(built)" \> "$before_built" ] && pass "the new server image's packages are newer ($before_built -> $(built))" ||
  fail "image-built didn't move: $before_built -> $(built)"
docker exec fishbowl sh -c 'ls /var/lib/fishbowl/backups/weekly-maintenance-*.sql.gz' > "$WORK/backup.out" 2>&1 &&
  pass "it took a backup first ($(basename "$(tail -n 1 "$WORK/backup.out")"))" || fail "no weekly-maintenance backup: $(cat "$WORK/backup.out")"
[ -z "$(image_id fishbowl-server:candidate)" ] && [ ! -d .fishbowl-maintain.lock ] &&
  pass "no candidate tag and no lock left behind" || fail "a candidate tag or the lock was left behind"

# ---- 2. a new server image that never comes back: everything goes back
cat > "$WORK/Dockerfile.broken" <<'EOF'
FROM fishbowl-server AS server
ARG PACKAGES_REFRESH=
ENTRYPOINT ["sleep", "infinity"]
EOF
python3 -I - "$WORK/Dockerfile.broken" <<'PY'
import sys
s = open("compose.override.yaml").read()
old = "  fishbowl:\n    build:\n"
assert old in s
open("compose.override.yaml", "w").write(s.replace(old, old + "      dockerfile: %s\n" % sys.argv[1], 1))
PY
maintain 0 120 > "$WORK/run2.log" 2>&1; rc=$?
sed 's/^/      /' "$WORK/run2.log" | tail -n 10
[ "$rc" = 2 ] && pass "a new image that doesn't come back: status 2" || fail "the failing run ended with status $rc"
snapshot after2
changed=""; for s in server $HELPERS; do a="after1_${s//-/_}"; b="after2_${s//-/_}"; [ "${!a}" = "${!b}" ] || changed="$changed $s"; done
[ -z "$changed" ] && pass "every container runs the image it ran before this run" ||
  fail "these run something else after the rollback:$changed"
for _ in $(seq 1 60); do [ "$(state)" = awaiting-database ] && break; sleep 5; done
[ "$(state)" = awaiting-database ] && pass "and it's back in the same state" || fail "state after the rollback: $(state)"
[ -n "$(image_id fishbowl-server:failed)" ] && [ -n "$(image_id fishbowl-page:failed)" ] &&
  ls fishbowl-maintain-failed-*.log >/dev/null 2>&1 &&
  pass "the new images are kept as :failed, the containers' logs saved next to compose.yaml" ||
  fail "a :failed tag or the saved log is missing"

echo "== maintenance checks: $PASSED passed, $FAILED failed"
[ "$FAILED" = 0 ]
