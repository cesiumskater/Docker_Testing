#!/usr/bin/env bash
# tests/gates.sh: the validation gates (G1 to G7) from docs/container-blueprint.md,
# run on the production host against the Compose deployment.
#
#   bash tests/gates.sh --dir ~/fishbowl GATE...
#
# Run it in (or point --dir at) the folder that holds compose.yaml and .env, on
# the Linux host that runs Docker Engine. GATE is one or more of:
#
#   g1-arm     record the time, then reboot the host yourself (sudo systemctl reboot)
#   g1         after the reboot, over SSH, with nothing started by hand:
#              zero-touch start (healthy within FB_GATE_BOOT_LIMIT s of boot, default 600)
#   g2         data survives a destructive rebuild: image, build cache and
#              container deleted, `docker compose down --volumes` included; the
#              company database and settings files hash the same before and after.
#              Stops Fishbowl Server for a few minutes and rebuilds from GitHub.
#   g3         non-root, read-only, least privilege, no setuid files, Trivy (if installed)
#   g4         failover: crash and hang of Fishbowl Server, crash of MySQL, crash of
#              the container's main process; restart must begin within 60 s, five
#              trials each (FB_GATE_TRIALS). Disconnects Fishbowl Clients each time.
#   g5         deterministic logs: UTC timestamps, same sequence on two restarts, no secrets
#   g6         backups restore: a fresh backup verifies, restores into a throwaway
#              MySQL with no network, and matches the live database (Fishbowl
#              Server is stopped for the backup)
#   g7         only the approved ports and accounts (run nmap from another computer too)
#   safe       g3 g5 g7 (nothing is stopped or restarted)
#
# Exit status: 0 = every gate asked for passed; 1 = at least one failed; 2 = usage.
# Prints PASS / FAIL per check. Nothing here sends or prints a secret.

set -uo pipefail
C=fishbowl
DIR=.
TRIALS="${FB_GATE_TRIALS:-5}"
BOOT_LIMIT="${FB_GATE_BOOT_LIMIT:-600}"
FAILED=0
GATES=()
PW_FILE=/usr/local/lib/fishbowl/mysql-root-password.txt

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    safe) GATES+=(g3 g5 g7); shift ;;
    g1-arm|g1|g2|g3|g4|g5|g6|g7) GATES+=("$1"); shift ;;
    *) echo "Unknown gate: $1 (bash tests/gates.sh --help)"; exit 2 ;;
  esac
done
[ "${#GATES[@]}" -gt 0 ] || { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
cd "$DIR" || { echo "No such folder: $DIR"; exit 2; }
[ -f compose.yaml ] || { echo "No compose.yaml in $(pwd)"; exit 2; }

ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
say()  { printf '%s %s\n' "$(ts)" "$*"; }
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
health() { docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$C" 2>/dev/null; }
status() { docker exec "$C" cat /run/fishbowl/status 2>/dev/null; }
wait_for() {  # wait_for SECONDS COMMAND...: 0 when COMMAND succeeds in time
  local limit="$1" t=0; shift
  until "$@"; do t=$((t + 2)); [ "$t" -ge "$limit" ] && return 1; sleep 2; done
}
is_healthy() { [ "$(health)" = healthy ]; }
is_status() { [ "$(status)" = "$1" ]; }
company_db() { docker exec "$C" python3 -I /usr/local/lib/fishbowl/props.py get /opt/Fishbowl/server/bin/eve.properties dbName 2>/dev/null; }
# The company database as SQL, without the lines that change on every dump, hashed.
db_hash() {
  local db="$1" host="${2:-$C}"
  docker exec "$host" sh -c "MYSQL_PWD=\"\$(cat $PW_FILE)\" mysqldump --protocol=tcp -h 127.0.0.1 -u root \
    --databases '$db' --single-transaction --routines --events --triggers --hex-blob \
    --order-by-primary --skip-dump-date --set-gtid-purged=OFF" | grep -v '^-- ' | sha256sum | cut -d' ' -f1
}
settings_hash() {
  docker exec "$C" sh -c 'cd /opt/Fishbowl/server/bin && sha256sum eve.properties dbsettings.properties 2>/dev/null' | sort
}

# ------------------------------------------------------------------- G1 -----
g1_arm() {
  say "G1: arming. Check that Docker starts at boot, then reboot the host yourself."
  check "docker.service is enabled (starts at boot, before anyone signs in)" \
    bash -c '[ "$(systemctl is-enabled docker 2>/dev/null)" = enabled ]'
  check "the container's restart policy is 'always'" \
    bash -c "[ \"\$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' $C)\" = always ]"
  say "Now: sudo systemctl reboot. After it, sign in over SSH, start nothing, and run: bash tests/gates.sh g1"
}
g1() {
  local boot now waited
  say "G1: zero-touch start after a host reboot (limit ${BOOT_LIMIT}s from boot)"
  boot="$(date -d "$(uptime -s)" +%s)"
  wait_for "$BOOT_LIMIT" is_healthy || true
  now="$(date +%s)"; waited=$((now - boot))
  check "healthy ${waited}s after boot, without anyone signing in or starting anything" \
    bash -c "[ \"$(health)\" = healthy ] && [ $waited -le $BOOT_LIMIT ]"
  check "it started on its own: the container's start is after the boot" \
    bash -c "[ \$(date -d \"\$(docker inspect --format '{{.State.StartedAt}}' $C)\" +%s) -ge $boot ]"
}

# ------------------------------------------------------------------- G2 -----
g2() {
  local db before_db before_set after_db after_set
  say "G2: data survives a destructive rebuild"
  db="$(company_db)"
  [ -n "$db" ] || { fail "a company database is selected (none: G2 needs one)"; return; }
  docker exec "$C" fishbowl-server stop --wait >/dev/null || { fail "Fishbowl Server stopped for the snapshot"; return; }
  before_db="$(db_hash "$db")"; before_set="$(settings_hash)"
  [ -n "$before_db" ] || { fail "hash of '$db' before"; return; }
  say "  before: $db $before_db"
  docker compose down --rmi all --volumes --remove-orphans
  docker builder prune --all --force >/dev/null
  check "all three volumes still exist after 'down --volumes'" \
    bash -c '[ "$(docker volume ls -q --filter name=^fishbowl- | grep -cE "^fishbowl-(mysql|app|data)$")" = 3 ]'
  say "  rebuilding from scratch (several minutes)"
  docker compose build --pull --no-cache || { fail "rebuild"; return; }
  # "admin": MySQL starts, Fishbowl Server doesn't, so nothing writes to the database meanwhile.
  FB_START_MODE="admin" docker compose up -d
  wait_for 600 is_status paused || { fail "the new container came up (status: $(status))"; return; }
  after_db="$(db_hash "$db")"; after_set="$(settings_hash)"
  check "company database '$db' is identical (sha256 $after_db)" [ "$before_db" = "$after_db" ]
  check "eve.properties and dbsettings.properties are identical" [ "$before_set" = "$after_set" ]
  docker compose up -d --force-recreate
  check "back to healthy, without asking for setup" wait_for 900 is_healthy
}

# ------------------------------------------------------------------- G3 -----
g3() {
  local out root
  say "G3: non-root processes, least privilege, minimal surface"
  out="$(docker inspect --format 'ro={{.HostConfig.ReadonlyRootfs}} priv={{.HostConfig.Privileged}} drop={{.HostConfig.CapDrop}} add={{.HostConfig.CapAdd}} sec={{.HostConfig.SecurityOpt}} pids={{.HostConfig.PidsLimit}}' "$C")"
  echo "    $out"
  check "read-only root filesystem" grep -q 'ro=true' <<<"$out"
  check "not privileged" grep -q 'priv=false' <<<"$out"
  check "all capabilities dropped, only the six documented ones added" \
    bash -c "grep -q 'drop=\[ALL\]' <<<'$out' && [ \"\$(grep -o 'add=\[[^]]*\]' <<<'$out' | tr -d '[]' | cut -d= -f2 | tr ' ' '\n' | sed 's/^CAP_//' | sort | tr '\n' ' ')\" = 'CHOWN DAC_OVERRIDE FOWNER KILL SETGID SETUID ' ]"
  check "no-new-privileges" grep -q 'no-new-privileges' <<<"$out"
  check "a PIDs limit" bash -c "! grep -qE 'pids=(0|-1|<nil>)$' <<<'$out'"
  check "MySQL runs as mysql" bash -c "docker top $C -eo user,comm | awk '\$2==\"mysqld\"' | grep -qv '^root'"
  check "Fishbowl Server (java) runs as fishbowl" bash -c "docker top $C -eo uid,comm | awk '\$2==\"java\" && \$1!=0' | grep -q ."
  check "no java process runs as root" bash -c "! docker top $C -eo uid,comm | awk '\$2==\"java\" && \$1==0' | grep -q ."
  check "the page's web server runs as fbweb" bash -c "docker top $C -eo user,args | grep 'portal.py' | grep -qv '^root'"
  # The supervisor family is the one declared deviation (CIS 4.1): tini, the entrypoint
  # and its helpers start as root to hand everyone else their user.
  root="$(docker top "$C" -eo uid,comm | awk 'NR>1 && $1==0 {print $2}' | sort -u |
          grep -vxE 'tini|bash|fishbowl-entryp|fishbowl-health|fishbowl-backup|sleep|python3|flock|setsid|timeout|nice|cat|mysqladmin|mysqldump|gzip|sh|tail|head|sed|grep|awk|stat|date|find|sort|xargs|pgrep|pkill|tr|cut|seq' || true)"
  check "root runs only the supervisor and its helpers${root:+ (also: $root)}" [ -z "$root" ]
  check "no setuid or setgid files in the image" \
    bash -c "[ -z \"\$(docker run --rm --entrypoint find fishbowl / -xdev -perm /6000 -type f 2>/dev/null)\" ]"
  if command -v trivy >/dev/null 2>&1; then
    check "no fixable High or Critical vulnerability (trivy)" \
      trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 fishbowl
  else
    say "  (trivy isn't installed here: skipped the vulnerability scan; CI runs it on every build)"
  fi
}

# ------------------------------------------------------------------- G4 -----
# Time from a fault until the restart begins: a new Fishbowl Server process
# (its pid file changes), a new mysqld, or a new container start.
fb_pid()    { docker exec "$C" cat /run/fishbowl/fishbowl-server.pid 2>/dev/null; }
mysqld_pid() { docker exec "$C" pgrep -x mysqld 2>/dev/null | head -n 1; }
started()   { docker inspect --format '{{.State.StartedAt}}' "$C"; }
ms_since()  { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
trial() {  # trial NAME
  local name="$1" t0 before ms limit=60000
  wait_for 900 is_healthy || { fail "$name: healthy before the trial"; return; }
  case "$name" in
    crash)
      before="$(fb_pid)"; t0=$(date +%s%N)
      # Fishbowl Server's whole process group (the launcher and its Java), not the windows' Java.
      docker exec "$C" sh -c "kill -KILL -- -\$(cat /run/fishbowl/fishbowl-server.pid)"
      wait_for 120 bash -c "p=\$(docker exec $C cat /run/fishbowl/fishbowl-server.pid 2>/dev/null); [ -n \"\$p\" ] && [ \"\$p\" != '$before' ]" ;;
    hang)
      before="$(fb_pid)"; t0=$(date +%s%N)
      # Freeze Fishbowl Server's whole process group: the port still accepts, nothing answers.
      docker exec "$C" sh -c "kill -STOP -- -\$(cat /run/fishbowl/fishbowl-server.pid)"
      wait_for 120 bash -c "p=\$(docker exec $C cat /run/fishbowl/fishbowl-server.pid 2>/dev/null); [ -n \"\$p\" ] && [ \"\$p\" != '$before' ]" ;;
    mysql)
      before="$(mysqld_pid)"; t0=$(date +%s%N)
      docker exec "$C" sh -c "pkill -KILL -x mysqld"
      wait_for 120 bash -c "p=\$(docker exec $C pgrep -x mysqld 2>/dev/null | head -n1); [ -n \"\$p\" ] && [ \"\$p\" != '$before' ]" ;;
    container)
      before="$(started)"; t0=$(date +%s%N)
      sudo kill -KILL "$(docker inspect --format '{{.State.Pid}}' "$C")"
      wait_for 120 bash -c "[ \"\$(docker inspect --format '{{.State.StartedAt}}' $C)\" != '$before' ]" ;;
  esac
  ms="$(ms_since "$t0")"
  check "$name: restart began ${ms} ms after the fault (limit $limit)" [ "$ms" -le "$limit" ]
  check "$name: healthy again with no command" wait_for 900 is_healthy
}
FAULTS=()   # when the faults in this container's life happened (the crash-loop guard counts them)
guard_room() {  # the guard holds Fishbowl Server at the 4th fault within 10 minutes: wait if needed
  local now keep=() t wait_s
  now=$(date +%s)
  for t in ${FAULTS[@]+"${FAULTS[@]}"}; do [ $((now - t)) -lt 600 ] && keep+=("$t"); done
  FAULTS=(${keep[@]+"${keep[@]}"})
  if [ "${#FAULTS[@]}" -ge 3 ]; then
    wait_s=$(( 600 - (now - FAULTS[0]) + 5 ))
    say "  waiting ${wait_s}s so the crash-loop guard (4 faults in 10 minutes) doesn't hold Fishbowl Server"
    sleep "$wait_s"
    FAULTS=("${FAULTS[@]:1}")
  fi
}
g4() {
  local n kind
  say "G4: failover in under a minute ($TRIALS trials each; Clients are disconnected each time)"
  for kind in crash hang mysql container; do
    for n in $(seq 1 "$TRIALS"); do
      guard_room
      say "  $kind, trial $n"
      trial "$kind"
      if [ "$kind" = container ]; then FAULTS=(); else FAULTS+=("$(date +%s)"); fi   # a new container starts counting afresh
    done
  done
}

# ------------------------------------------------------------------- G5 -----
g5() {
  local run t pw code
  say "G5: deterministic logs"
  for run in 1 2; do
    t="$(ts)"
    docker compose restart >/dev/null
    wait_for 900 is_healthy || { fail "healthy after restart $run"; return; }
    docker logs --since "$t" "$C" > "gate-g5-run$run.log" 2>&1
    grep -E '\[(fishbowl|watchdog)\]' "gate-g5-run$run.log" | sed -E 's/^[^ ]+ //; s/[0-9]+/N/g' > "gate-g5-seq$run.txt"
  done
  check "every line starts with a UTC timestamp" \
    bash -c "! grep -vqE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z |^-+$|^ |^$' gate-g5-run1.log gate-g5-run2.log"
  check "the same sequence of [fishbowl] lines on both restarts" diff -q gate-g5-seq1.txt gate-g5-seq2.txt
  check "Fishbowl Server's and MySQL's own lines are in docker logs (FB_LOG_STREAM=1)" \
    bash -c "grep -q '\[mysqld\]' gate-g5-run1.log gate-g5-run2.log"
  pw="$(docker exec "$C" cat $PW_FILE)"; code="$(docker exec "$C" cat /var/lib/fishbowl/state/web-code 2>/dev/null)"
  check "the MySQL root password is in no log line" bash -c "! docker logs $C 2>&1 | grep -qF -- \"\$1\"" _ "$pw"
  check "the page's access code is only in its own link lines" \
    bash -c "! docker logs $C 2>&1 | grep -F -- \"\$1\" | grep -vq 'code='" _ "$code"
  check "log rotation is set (json-file, 10m, 5)" \
    bash -c "docker inspect --format '{{.HostConfig.LogConfig}}' $C | grep -q 'max-file:5' && docker inspect --format '{{.HostConfig.LogConfig}}' $C | grep -q 'max-size:10m'"
  rm -f gate-g5-run1.log gate-g5-run2.log gate-g5-seq1.txt gate-g5-seq2.txt
}

# ------------------------------------------------------------------- G6 -----
g6() {
  local db file live drill start secs
  say "G6: backups restore"
  check "the last scheduled backup is under 26 hours old" docker exec "$C" fishbowl-healthcheck --backup-age 26
  db="$(company_db)"
  [ -n "$db" ] || { fail "a company database is selected (none: G6 needs one)"; return; }
  docker exec "$C" fishbowl-server stop --wait >/dev/null || { fail "Fishbowl Server stopped for the backup"; return; }
  file="$(docker exec "$C" fishbowl-backup --label gate-g6 --keep 1 --with-settings </dev/null | tail -n 1)"
  live="$(db_hash "$db")"
  docker exec "$C" fishbowl-server start >/dev/null
  check "a fresh backup verifies (gzip, trailer, checksums)" docker exec "$C" fishbowl-backup --verify "$file"
  # Restore into a throwaway MySQL from the same image, with no network at all.
  docker rm -f fishbowl-drill >/dev/null 2>&1
  docker run -d --name fishbowl-drill --network none --entrypoint sleep fishbowl infinity >/dev/null
  docker exec fishbowl-drill sh -c 'mkdir -p /tmp/d /run/mysqld /run/fishbowl-mysql.d && chown mysql:mysql /tmp/d /run/mysqld &&
    mysqld --initialize-insecure --user=mysql --datadir=/tmp/d --log-error=/tmp/init.log >/dev/null 2>&1 &&
    (mysqld --user=mysql --datadir=/tmp/d --socket=/tmp/d/s.sock --bind-address=127.0.0.1 --log-error=/tmp/d/err.log &) ;
    for i in $(seq 1 120); do mysqladmin --socket=/tmp/d/s.sock -uroot ping --silent 2>/dev/null && exit 0; sleep 1; done; exit 1' ||
    { fail "throwaway MySQL started"; docker rm -f fishbowl-drill >/dev/null; return; }
  start=$(date +%s)
  docker exec "$C" cat "$file" | docker exec -i fishbowl-drill sh -c 'gzip -dc | mysql --socket=/tmp/d/s.sock -uroot --max-allowed-packet=1G' ||
    fail "the backup loaded"
  secs=$(( $(date +%s) - start ))
  # The dump restores mysql.user too, so root has the image's password from here on.
  drill="$(docker exec fishbowl-drill sh -c "MYSQL_PWD=\"\$(cat $PW_FILE)\" mysqldump --socket=/tmp/d/s.sock -u root \
    --databases '$db' --single-transaction --routines --events --triggers --hex-blob \
    --order-by-primary --skip-dump-date --set-gtid-purged=OFF" | grep -v '^-- ' | sha256sum | cut -d' ' -f1)"
  docker rm -f fishbowl-drill >/dev/null
  check "restored '$db' matches the live database (sha256 $drill)" [ -n "$drill" ] && [ "$drill" = "$live" ]
  check "the restore took ${secs}s (RTO for this step: 3600)" [ "$secs" -le 3600 ]
  say "  Also check by hand: the offsite copy's newest backup is as recent as its schedule promises."
  wait_for 900 is_healthy || fail "healthy again after the drill"
}

# ------------------------------------------------------------------- G7 -----
g7() {
  local ports users
  say "G7: only the approved ports and accounts"
  ports="$(docker port "$C" | sort)"
  echo "$ports" | sed 's/^/    /'
  check "published: 2456 and 28192, and 6080 on 127.0.0.1 only" \
    bash -c "[ \"\$(docker port $C | sed -E 's/ -> .*//' | sort -u | tr '\n' ' ')\" = '2456/tcp 28192/tcp 6080/tcp ' ] &&
             ! docker port $C 6080 | grep -vq '^127\.0\.0\.1:'"
  check "fishbowl-netcheck: nothing listens outside the allowlist, Fishbowl's servers reachable" \
    docker exec "$C" fishbowl-netcheck
  users="$(docker exec "$C" sh -c "MYSQL_PWD=\"\$(cat $PW_FILE)\" mysql --protocol=tcp -h 127.0.0.1 -u root -N -B -e \"SELECT host FROM mysql.user WHERE user='root'\"" | sort -u | tr '\n' ' ')"
  check "MySQL's root exists only for the container's own loopback (${users})" \
    bash -c "! tr ' ' '\n' <<<'$users' | grep -vxE 'localhost|127\.0\.0\.1|::1|' | grep -q ."
  say "  From another computer on the network: nmap -Pn -p- --open <this host>  (expect 2456 and 28192 only)"
}

for g in "${GATES[@]}"; do
  case "$g" in
    g1-arm) g1_arm ;;
    *) "$g" ;;
  esac
done
if [ "$FAILED" = 0 ]; then say "All checks passed: ${GATES[*]}"; else say "Some checks FAILED: ${GATES[*]}"; fi
exit "$FAILED"
