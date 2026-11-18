#!/usr/bin/env bash
#
# fishbowl-maintain.sh: the weekly maintenance for Fishbowl in Docker Compose
# (Linux and macOS; fishbowl-maintain.ps1 is the Windows version).
#
#   bash fishbowl-maintain.sh                  in the folder that holds compose.yaml
#   bash fishbowl-maintain.sh --dir ~/fishbowl
#
# Updates must not stall waiting for someone to run them, so a scheduled task
# runs this every week (README section 12, "Weekly maintenance"). In order:
#
#   1. Builds a new image with every package update published so far, tagged
#      fishbowl:candidate. The running container isn't touched, and a failed
#      build changes nothing.
#   2. If the container isn't running (stopped on purpose, say), the candidate
#      becomes the image its next `docker compose up -d` uses, and that's all.
#   3. Backs up every MySQL database inside the running container
#      (fishbowl-backup --label weekly-maintenance --keep 4). No backup, no change.
#   4. Keeps the image the container runs now as fishbowl:previous, makes the
#      candidate the fishbowl image, and recreates the container on the same
#      volumes.
#   5. Waits until the container is back where it was: healthy if it was healthy
#      before, otherwise in the same state on the Fishbowl page. It waits up to
#      FB_MAINTAIN_TIMEOUT seconds (default 1200).
#   6. If it doesn't get there, it saves the failed container's log next to
#      compose.yaml, tags the new image fishbowl:failed, puts fishbowl:previous
#      back and recreates the container again.
#
# It never runs during a first-time setup or a Fishbowl upgrade, and two runs
# never overlap.
#
# Exit status: 0 = done, or nothing to do; 1 = stopped before anything changed;
# 2 = the new image failed and the previous one runs again; 3 = the previous
# image didn't come back either. For 3, restore from the backup this run names
# (README section 12, "If something goes wrong").
#
# Settings (environment): FB_MAINTAIN_TIMEOUT (seconds, default 1200),
# FB_MAINTAIN_KEEP (maintenance backups kept, default 4), FB_MAINTAIN_PULL
# (1: also fetch a newer base image; 0 when the build uses a base image that
# only exists on this computer).

set -uo pipefail

# Docker Desktop on macOS puts docker in /usr/local/bin, which cron's PATH lacks.
PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"

CONTAINER=fishbowl
SERVICE=fishbowl
IMAGE=fishbowl
LABEL_SOURCE="https://github.com/cesiumskater/Docker_Testing"
TIMEOUT="${FB_MAINTAIN_TIMEOUT:-1200}"
KEEP="${FB_MAINTAIN_KEEP:-4}"
PULL=(--pull)
[ "${FB_MAINTAIN_PULL:-1}" = 0 ] && PULL=()
DIR=.
BACKUP="(none taken)"

say()  { printf '%s [maintain] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() { local rc="$1"; shift; say "STOPPED: $*"; exit "$rc"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || fail 1 "--dir needs a folder"; DIR="$2"; shift 2 ;;
    -h|--help) sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail 1 "Unknown option $1 (usage: fishbowl-maintain.sh [--dir FOLDER])" ;;
  esac
done
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || fail 1 "FB_MAINTAIN_TIMEOUT must be a number of seconds."
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || fail 1 "FB_MAINTAIN_KEEP must be a number from 1 up."
cd "$DIR" 2>/dev/null || fail 1 "No such folder: $DIR"
[ -f compose.yaml ] || fail 1 "No compose.yaml in $(pwd). Run this in the folder you start Fishbowl from, or pass --dir."
docker info >/dev/null 2>&1 || fail 1 "Docker isn't running. (On macOS and Windows, Docker Desktop has to be running, which needs someone signed in.)"
docker compose version >/dev/null 2>&1 || fail 1 "Docker Compose isn't available: 'docker compose version' failed."

# One run at a time. mkdir is atomic everywhere; flock isn't on macOS.
LOCK=.fishbowl-maintain.lock
mkdir "$LOCK" 2>/dev/null ||
  fail 1 "Another maintenance run holds $(pwd)/$LOCK. If none is running (a crash left it behind), delete that folder."
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

image_id()   { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null; }
running()    { [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ]; }
health()     { docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER" 2>/dev/null; }
page_state() { docker exec "$CONTAINER" cat /run/fishbowl/status 2>/dev/null; }
drop_candidate() { docker image rm "$IMAGE:candidate" >/dev/null 2>&1 || true; }

# back_where_it_was: 0 once the container is back where it was before; 1 on a
# state that won't fix itself, or after TIMEOUT seconds.
back_where_it_was() {
  local deadline h="" s=""
  deadline=$(( $(date +%s) + TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if running; then
      h="$(health)"; s="$(page_state)"
      case "$s" in
        server-failed|upgrade-interrupted|foreign-data|downgrade|no-volumes)
          say "The container reports '$s'."; return 1 ;;
      esac
      [ "$h" = healthy ] && return 0
      [ "$BEFORE_HEALTH" != healthy ] && [ -n "$s" ] && [ "$s" = "$BEFORE_STATE" ] && return 0
    fi
    sleep 10
  done
  say "Not back after $TIMEOUT seconds (health: ${h:-none}, state: ${s:-unknown})."
  return 1
}

roll_back() {
  local saved
  saved="fishbowl-maintain-failed-$(date -u +%Y%m%dT%H%M%SZ).log"
  docker logs --tail 300 "$CONTAINER" > "$saved" 2>&1 || true
  say "The new image didn't come back ($1). Its container's log is saved in $(pwd)/$saved."
  docker tag "$IMAGE" "$IMAGE:failed" 2>/dev/null || true
  docker tag "$IMAGE:previous" "$IMAGE" ||
    fail 3 "Couldn't put $IMAGE:previous back. Your data is in the volumes; this run's backup: $BACKUP. Follow README section 12, \"If something goes wrong\"."
  say "Putting the previous image back and recreating the container."
  docker compose up -d --force-recreate --no-build "$SERVICE" || true
  if back_where_it_was; then
    say "Rolled back: the previous image runs again. The new one is kept as $IMAGE:failed for a look."
    exit 2
  fi
  fail 3 "The previous image didn't come back either. Your data is in the volumes, and this run's backup is $BACKUP. Follow README section 12, \"If something goes wrong\"."
}

# 1. Build. A new PACKAGES_REFRESH value makes Docker apply every package update
#    instead of reusing its cache; FB_IMAGE gives the build its own tag.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
say "Building a new image with every package update published so far. This takes a while."
FB_IMAGE="$IMAGE:candidate" docker compose build ${PULL[@]+"${PULL[@]}"} --build-arg "PACKAGES_REFRESH=$STAMP" "$SERVICE" ||
  { drop_candidate; fail 1 "The build failed (its output is above). Nothing changed; the container keeps its image."; }
[ -n "$(image_id "$IMAGE:candidate")" ] || fail 1 "The build reported success, but there's no $IMAGE:candidate image."

# 2. Not running: no backup, no recreate; the next start uses the new image.
if ! running; then
  current="$(image_id "$IMAGE")"
  [ -z "$current" ] || docker tag "$current" "$IMAGE:previous"
  docker tag "$IMAGE:candidate" "$IMAGE" && drop_candidate
  say "The container isn't running, so it was left alone. 'docker compose up -d' starts it on the new image."
  exit 0
fi

BEFORE_HEALTH="$(health)"
BEFORE_STATE="$(page_state)"
case "$BEFORE_STATE" in
  setup|upgrading|starting-up|starting|stopping-server)
    drop_candidate
    fail 1 "Fishbowl is busy ($BEFORE_STATE). Nothing changed; the next run tries again." ;;
esac
say "Before: health '${BEFORE_HEALTH:-none}', state '${BEFORE_STATE:-unknown}'."

# 3. Back up first. No backup, no change.
say "Backing up every MySQL database."
out="$(docker exec "$CONTAINER" fishbowl-backup --label weekly-maintenance --keep "$KEEP" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
if [ "$rc" != 0 ]; then
  drop_candidate
  [ "$rc" = 3 ] && fail 1 "This installation has a MySQL root password of its own, so an unattended backup can't run. Run this script by hand in a terminal after 'docker exec -it fishbowl fishbowl-backup', or see README section 12."
  fail 1 "The backup failed (above). Nothing changed."
fi
BACKUP="$(printf '%s\n' "$out" | tail -n 1)"

# 4. Swap and recreate on the same volumes.
docker tag "$(docker inspect --format '{{.Image}}' "$CONTAINER")" "$IMAGE:previous" ||
  { drop_candidate; fail 1 "Couldn't keep the current image as $IMAGE:previous. Nothing changed."; }
docker tag "$IMAGE:candidate" "$IMAGE" || { drop_candidate; fail 1 "Couldn't tag the new image. Nothing changed."; }
drop_candidate
say "Recreating the container on the new image (same volumes)."
docker compose up -d --force-recreate --no-build "$SERVICE" || roll_back "docker compose up failed"

# 5. Back where it was?
back_where_it_was || roll_back "it didn't get back to where it was"

# 6. Tidy up: earlier builds of this image that no tag points at any more.
docker image prune -f --filter "label=org.opencontainers.image.source=$LABEL_SOURCE" >/dev/null 2>&1 || true
say "Done. The container runs the new image (packages as of $(docker exec "$CONTAINER" cat /usr/local/share/fishbowl/image-built 2>/dev/null || echo unknown)). Backup: $BACKUP. The previous image stays as $IMAGE:previous until the next run."
exit 0
