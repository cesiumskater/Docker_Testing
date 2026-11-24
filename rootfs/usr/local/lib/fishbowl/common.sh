# shellcheck shell=bash
# shellcheck disable=SC2034  # constants and state used by the scripts that source this file
# Shared helpers for the Fishbowl container scripts. Sourced, never executed.
#
# Secrets rule for every script in this image: the License Key and any MySQL
# root password someone types are read without echo, never passed on a command
# line, never exported, never logged. (The image's own MySQL root password is read from
# mysql-root-password.txt only inside the container: it is never printed, logged, shown
# on the Fishbowl page or sent to a browser. Fishbowl fills it into Server
# Administration's Password fields by itself, masked.) Temporary files that hold them live in /dev/shm
# (RAM), mode 0600, and are deleted as soon as they have been read.

set -o errexit -o nounset -o pipefail
set +o histexpand  # passwords may contain '!'
umask 022          # `docker exec` sessions can inherit umask 0000; MySQL ignores world-writable config

readonly FB_HOME=/opt/Fishbowl
readonly FB_BIN=/opt/Fishbowl/server/bin
readonly FB_EVE=/opt/Fishbowl/server/bin/eve.properties
readonly FB_SERVICE_LAUNCHER="/opt/Fishbowl/server/bin/Fishbowl Server Service"
readonly FB_ADMIN_LAUNCHER="/opt/Fishbowl/server/bin/Fishbowl Server Administration"
readonly FB_CLIENT_LAUNCHER="/opt/Fishbowl/client/bin/Fishbowl Client"
readonly FB_SERVER_LOG=/opt/Fishbowl/logs/fbserver.log
readonly MYSQL_DATA=/var/lib/mysql
readonly MYSQL_SOCKET=/var/lib/mysql/mysql.sock
readonly MYSQL_RUN=/run/mysqld
readonly MYSQL_CNF_DIR=/etc/my.cnf.d
# Fishbowl's MySQL tuning is written here at every start, so the image itself can
# stay read-only: /etc/my.cnf.d/50-fishbowl-tuning.cnf includes this folder.
readonly FB_MYCNF_DIR=/run/fishbowl-mysql.d
readonly FB_MYCNF_DST="$FB_MYCNF_DIR/50-fishbowl-server.cnf"
# MySQL in its own container (the Compose stack, README "The Compose stack"):
# FISHBOWL_DB_HOST names it, its root password comes from a file (a Compose
# secret), and Fishbowl's tuning goes to a folder the database container reads.
# Without FISHBOWL_DB_HOST, MySQL runs inside this container as always.
readonly DB_HOST="${FISHBOWL_DB_HOST:-127.0.0.1}"
readonly DB_CONF_DIR="${FISHBOWL_DB_CONF_DIR:-}"
readonly DATA_DIR=/var/lib/fishbowl
readonly STATE_DIR=/var/lib/fishbowl/state
readonly BACKUP_DIR=/var/lib/fishbowl/backups
readonly LOG_DIR=/var/lib/fishbowl/logs
readonly HOMES_DIR=/var/lib/fishbowl/home
readonly IMPORT_DIR=/var/lib/fishbowl/import   # .sql files for the Restore tab (uploaded on the page or copied in)
readonly PENDING_EVE=/var/lib/fishbowl/state/pending-eve.properties
readonly INSTALLER_TMP=/var/lib/fishbowl/tmp
readonly RUN_DIR=/run/fishbowl
readonly SERVER_PORT_FILE=$RUN_DIR/server-port   # the client port Fishbowl Server read at its last start
readonly UPDATE_LOCK="$RUN_DIR/update.lock"   # held while update-all.sh changes packages; setup and upgrades wait for it
readonly STATUS_FILE=/run/fishbowl/status
readonly MESSAGE_FILE=/run/fishbowl/message          # the longer text that goes with the status
readonly INFO_FILE=/run/fishbowl/info                # facts for the page (versions, database name); nothing secret
readonly LAST_ERROR_FILE=/run/fishbowl/last-error    # why the last setup/upgrade/start attempt failed
readonly PENDING_FLAG=/run/fishbowl/pending-settings # settings changed in Server Administration wait for a restart
readonly INSTALLER_DIR=/opt/fishbowl-installer
# Java 21: the JDK in the single container, the JRE in the Compose stack's images
# (each image sets JAVA_HOME).
readonly JAVA21_HOME="${JAVA_HOME:-/usr/lib/jvm/temurin-21-jdk}"
readonly FB_USER=fishbowl
readonly LIB_DIR=/usr/local/lib/fishbowl
readonly BIN_DIR=/usr/local/bin
readonly PROMPT_TIMEOUT="${FISHBOWL_PROMPT_TIMEOUT:-1800}"   # seconds per answer
# "Press Enter" presence check: catches a terminal that shows output but can't send input.
readonly FIRST_PROMPT_TIMEOUT="$(( PROMPT_TIMEOUT < 300 ? PROMPT_TIMEOUT : 300 ))"

# The Fishbowl page: a small web server (portal.py) that runs as its own user.
readonly WEB_USER=fbweb
readonly WEB_PORT=6080
# The role this container plays (README, "The Compose stack"): all (the single
# container: everything, started as root), or one part of the split stack, each
# started as its own user: server (Fishbowl Server, setup, upgrades), page (the
# Fishbowl page) or desktop (the Server Administration and Client windows). The
# parts share /run/fishbowl, a small in-memory volume: status, requests, sockets.
readonly ROLE="${FISHBOWL_ROLE:-all}"
case "$ROLE" in all|server|page|desktop) ;; *) echo "FISHBOWL_ROLE must be all, server, page or desktop (it's '$ROLE')." >&2; exit 2 ;; esac
split_role() { [ "$ROLE" != all ]; }
if [ "$ROLE" = all ]; then
  readonly WEB_SPOOL=/dev/shm/fishbowl-web           # requests from the page to this script (RAM only)
else
  readonly WEB_SPOOL=/run/fishbowl/spool             # the same, on the shared in-memory volume
fi
readonly PAGE_DIR=/var/lib/fishbowl/page              # the page's own lasting state (split stack)
readonly HEARTBEAT_FILE=/run/fishbowl/desktop-alive   # the desktop's loop touches it (split stack)
readonly WEB_CODE_FILE=/var/lib/fishbowl/state/web-code
readonly WEB_CODE_RUN=/run/fishbowl/web-code         # copy only the page's user can read
# Browser windows (fishbowl-session): private sockets, no TCP ports.
readonly X_DIR=/run/fishbowl/x                       # VNC sockets, fishbowl only
readonly WS_DIR=/run/fishbowl/ws                     # WebSocket bridges, fishbowl + the page's user

# The five server launchers and two client launchers the installer writes -Xmx into.
readonly SERVER_VMOPTIONS=(
  "Fishbowl Server Service" "Fishbowl Server" "Fishbowl Server Console"
  "Fishbowl Server Administration" "Fishbowl"
)
readonly CLIENT_VMOPTIONS=("Fishbowl Client" "Checkout")
readonly SERVER_MEMORY_MB=8192
readonly CLIENT_MEMORY_MB=2048

# shellcheck source=/dev/null
. "$INSTALLER_DIR/installer.env"
readonly FISHBOWL_VERSION FISHBOWL_APP_VERSION FISHBOWL_INSTALLER FISHBOWL_EULA

# ---------------------------------------------------------------- output ----
_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
# log_tag TAG: copies lines from stdin to stdout, each with a UTC timestamp and
# [TAG] in front, the shape of every other line in `docker logs` (Fishbowl
# Server's own console output becomes [fbserver] lines). bash's own clock, so no
# process per line.
log_tag() {
  local line
  export TZ=UTC0
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%(%Y-%m-%dT%H:%M:%S)TZ [%s] %s\n' -1 "$1" "$line"
  done
}
log()  { printf '%s [fishbowl] %s\n' "$(_ts)" "$*"; }
# In the Compose stack's containers every line in `docker logs` starts with a UTC
# timestamp and a tag, so a log collector can read them one event per line
# (FISHBOWL_LOG_STAMPED, set by the entrypoint there and inherited by its jobs).
# The single container keeps its framed blocks of text for people to read, and
# `docker exec` sessions print plain text either way.
stamped() { [ "${FISHBOWL_LOG_STAMPED:-0}" = 1 ]; }
note() {
  if stamped; then
    [ -n "$*" ] || return 0
    printf '%s [fishbowl] %s\n' "$(_ts)" "$*"
  else
    printf '%s\n' "$*"
  fi
}
warn() { printf '%s [warning] %s\n' "$(_ts)" "$*" >&2; }
# fail <exit-code> <message...>
# When FAIL_NOTE_FILE is set (a setup or upgrade started from the page or a
# terminal command), the message is also left there for the page to show.
FAIL_NOTE_FILE=""
fail() {
  local code="$1"; shift
  if stamped; then printf '%s [error] %s\n' "$(_ts)" "$*" >&2
  else printf '\n%s [error] %s\n\n' "$(_ts)" "$*" >&2; fi
  if [ -n "$FAIL_NOTE_FILE" ]; then
    printf '%s\n' "$*" > "$FAIL_NOTE_FILE" 2>/dev/null || true
  fi
  exit "$code"
}
# set_status <word> [text for the page]
set_status() {
  mkdir -p "$RUN_DIR"
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2" > "$MESSAGE_FILE.tmp" && mv -f "$MESSAGE_FILE.tmp" "$MESSAGE_FILE"
  else
    rm -f "$MESSAGE_FILE"
  fi
  printf '%s\n' "$1" > "$STATUS_FILE.tmp" && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
}
current_status() { cat "$STATUS_FILE" 2>/dev/null || true; }
hr() { stamped || printf '%s\n' "------------------------------------------------------------------------"; }

is_interactive() { [ -t 0 ] && [ -t 1 ]; }

# ----------------------------------------------------------- prompting ------
# All prompts time out so a terminal that shows output but can't send input
# never hangs a command.
# ask <var> <prompt> [timeout]; returns 1 on EOF or timeout.
ask() {
  local __var="$1" __prompt="$2" __t="${3:-$PROMPT_TIMEOUT}" __v=""
  if ! IFS= read -r -t "$__t" -p "$__prompt" __v; then
    printf '\n'; return 1
  fi
  printf -v "$__var" '%s' "$__v"
}
# ask_secret <var> <prompt>; input is not echoed.
ask_secret() {
  local __var="$1" __prompt="$2" __v=""
  if ! IFS= read -r -s -t "$PROMPT_TIMEOUT" -p "$__prompt" __v; then
    printf '\n'; return 1
  fi
  printf '\n'
  printf -v "$__var" '%s' "$__v"
}

# The MySQL root password every new installation gets, so nobody has to choose
# one. It lives in one file that the shell scripts and the Fishbowl page both read.
# Installations made by earlier versions of this image may have a password of
# their own; ask_root_password_until_valid (upgrade.sh) tries this one first and
# asks only when MySQL turns it down.
default_root_password() {
  local f="${FISHBOWL_DB_ROOT_PASSWORD_FILE:-$LIB_DIR/mysql-root-password.txt}" pw=""
  [ -r "$f" ] || fail 1 "The MySQL root password file $f is missing (README, \"The MySQL root password\")."
  IFS= read -r pw < "$f" || [ -n "$pw" ] || true
  [ -n "$pw" ] || fail 1 "The MySQL root password file $f is empty."
  printf '%s' "$pw"
}
db_external() { [ -n "${FISHBOWL_DB_HOST:-}" ]; }

# A first-time setup or an upgrade must not run while update-all.sh is changing
# packages (MySQL and Java are among them). Call this at the start of such a job;
# the lock stays held (file descriptor 7) until the job's process ends.
wait_for_system_update() {
  mkdir -p "$RUN_DIR"
  exec 7>"$UPDATE_LOCK" || return 0
  if ! flock -n 7; then
    log "A system update is running; waiting for it to finish before going on (a few minutes at most)"
    flock -w 1800 7 || warn "The system update is taking very long; going on anyway."
  fi
}

# --------------------------------------------------------- run commands -----
as_user() {  # as_user <user> <cmd...>   (keeps the environment we pass explicitly)
  local user="$1"; shift
  if [ "$(id -u)" = "$(id -u "$user" 2>/dev/null)" ]; then "$@"; return; fi
  setpriv --reuid="$user" --regid="$user" --init-groups --inh-caps=-all -- "$@"
}
# drop_to USER: sets DROP to what goes in front of a command so it runs as USER:
# setpriv when this script runs as root (the single container), nothing when it
# already runs as that user (the split stack, where nothing starts as root).
DROP=()
drop_to() {
  if [ "$(id -u)" = 0 ]; then DROP=(setpriv --reuid="$1" --regid="$1" --init-groups --inh-caps=-all --)
  else DROP=(); fi
}
am_root() { [ "$(id -u)" = 0 ]; }

ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }

secret_dir() {  # prints a fresh 0700 directory in /dev/shm (RAM)
  local d
  [ -d /dev/shm ] && [ -w /dev/shm ] || fail 1 "/dev/shm is not available; secrets would have to touch disk. Run the container with Docker's default /dev/shm."
  d="$(mktemp -d /dev/shm/fishbowl.XXXXXX)"
  chmod 0700 "$d"
  printf '%s\n' "$d"
}

random_code() {  # random_code <length>: letters and digits that are hard to mix up
  LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' < /dev/urandom | head -c "$1" || true
}

# --------------------------------------------------- Java properties files --
props_get() { python3 -I "$LIB_DIR/props.py" get "$1" "$2"; }    # props_get FILE KEY
props_escape() { python3 -I "$LIB_DIR/props.py" escape; }          # value on stdin
props_set() { printf '%s' "$3" | python3 -I "$LIB_DIR/props.py" set "$1" "$2"; }   # props_set FILE KEY VALUE

eve_get() { [ -f "$FB_EVE" ] && props_get "$FB_EVE" "$1" 2>/dev/null; }
database_configured() { local n; n="$(eve_get dbName || true)"; [ -n "$n" ]; }
client_port() { local p; p="$(eve_get webPort || true)"; printf '%s\n' "${p:-2456}"; }
# The port Fishbowl Server serves Clients on now: the one it read at its last
# start, or, before it ever started, the one it will use.
server_port_now() {
  local p
  p="$(cat "$SERVER_PORT_FILE" 2>/dev/null || true)"
  [[ "$p" =~ ^[0-9]+$ ]] || p="$(client_port)"
  printf '%s\n' "$p"
}

# The Fishbowl Client in its window connects to Fishbowl Server by the address in
# client.properties: localhost in the single container, the server container's
# name (FISHBOWL_SERVER_HOST, default fishbowl) in the split stack.
client_point_server() {
  local f="$FB_HOME/client/bin/client.properties" want key cur
  [ -f "$f" ] || return 0
  if split_role; then want="${FISHBOWL_SERVER_HOST:-fishbowl}"; else want=localhost; fi
  for key in ServerAddress CheckoutServerAddress; do
    cur="$(props_get "$f" "$key" 2>/dev/null || true)"
    # Back in the single container, only the stack's own value is put back.
    if [ "$cur" != "$want" ] && { split_role || [ "$cur" = "${FISHBOWL_SERVER_HOST:-fishbowl}" ]; }; then
      props_set "$f" "$key" "$want"
    fi
  done
  # The port follows Server Administration's Port, as Fishbowl Server runs now
  # (Fishbowl itself leaves the Client's ports at 2456 when that Port changes).
  want="$(server_port_now)"
  for key in ServerPort CheckoutServerPort; do
    cur="$(props_get "$f" "$key" 2>/dev/null || true)"
    [ "$cur" = "$want" ] || props_set "$f" "$key" "$want"
  done
}

# Java's proxy settings for Fishbowl's own programs, when FISHBOWL_EGRESS_PROXY
# names the egress proxy (host:port, the Compose stack). JAVA_TOOL_OPTIONS reaches
# every Java that Fishbowl starts, its updater included, so they all go out
# through the proxy; the stack's own names (and this container) stay direct.
java_proxy_opts() {
  local p="${FISHBOWL_EGRESS_PROXY:-}" host port
  [ -n "$p" ] || return 0
  if ! [[ "$p" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]]; then
    warn "FISHBOWL_EGRESS_PROXY must be host:port; '$p' is ignored, so Fishbowl has no way out."
    return 0
  fi
  host="${p%:*}"; port="${p##*:}"
  printf -- '-Dhttp.proxyHost=%s -Dhttp.proxyPort=%s -Dhttps.proxyHost=%s -Dhttps.proxyPort=%s -Dhttp.nonProxyHosts=localhost|127.*|[::1]|%s|fishbowl|db|edge' \
    "$host" "$port" "$host" "$port" "$(hostname 2>/dev/null || echo fishbowl)"
}
# ---------------------------------------------- Fishbowl's own updates -----
# Fishbowl can update itself (Server Administration -> Server -> Auto Updates):
# it downloads update packages into updates/, stops, and its updater copies the
# new files in, then runs server/bin/eve.sh to start Fishbowl Server again. The
# container puts a stub in place of eve.sh (eve.sh.stub: it only leaves a request
# in NATIVE_DIR) and the supervisor does the rest: a backup before a package is
# applied, no start while the updater works, the server started the normal way.
readonly FB_UPDATES_DIR="$FB_HOME/updates"
readonly FB_APPLY_FILE="$FB_UPDATES_DIR/applyUpdates.tmp"
readonly FB_EVE_SH="$FB_BIN/eve.sh"
readonly NATIVE_DIR="$RUN_DIR/native"
readonly NATIVE_RESTART_FILE="$NATIVE_DIR/restart-requested"

# FISHBOWL_NATIVE_UPDATES=1: Fishbowl updating itself is expected here (no
# warning about it, and an image with an older installer isn't a downgrade).
native_updates_on() { [ "${FISHBOWL_NATIVE_UPDATES:-0}" = 1 ]; }
# FISHBOWL_CONTAINERIZED=1 passes Fishbowl's own container switch,
# FishbowlContainerized=true. Fishbowl reads it with Boolean.parseBoolean, so
# only "true" works ("1" would be off). With it on, Fishbowl refuses its own
# database backups and skips the one it takes before a database update, so it
# belongs with the stack's backup container (README, "Fishbowl's own updates").
containerized_value() { [ "${FISHBOWL_CONTAINERIZED:-0}" = 1 ] && echo true || echo false; }
# Update packages Fishbowl downloaded and hasn't applied yet.
native_update_zips() { find "$FB_UPDATES_DIR" -maxdepth 1 -type f -name '*.zip' 2>/dev/null | sort; }
native_update_pending() { [ -n "$(native_update_zips)" ]; }
# Fishbowl's updater (fb-updater-x.jar) at work, as Fishbowl's user.
native_updater_running() { pgrep -u "$FB_USER" -f 'fb-updater' >/dev/null 2>&1; }
# The Fishbowl version its program files carry now (eve-26.11.jar -> 26.11). The
# installer's record (installed_app_version) doesn't change when Fishbowl updates itself.
running_app_version() {
  find "$FB_HOME/lib" -maxdepth 1 -name 'eve-[0-9]*.jar' -printf '%f\n' 2>/dev/null |
    sed -n 's/^eve-\([0-9][0-9.]*[0-9]\)\.jar$/\1/p' | sort -V | tail -n 1
}
# Before every start of Fishbowl Server: the stub in place of eve.sh (an update
# may have brought the original back), and the folder the stub writes to.
native_prepare() {
  mkdir -p "$NATIVE_DIR"
  chown "$FB_USER:$FB_USER" "$NATIVE_DIR"
  chmod 0700 "$NATIVE_DIR"
  [ -d "$FB_BIN" ] || return 0
  if ! cmp -s "$LIB_DIR/eve.sh.stub" "$FB_EVE_SH"; then
    install -m 0755 -o "$FB_USER" -g "$FB_USER" "$LIB_DIR/eve.sh.stub" "$FB_EVE_SH" ||
      warn "Couldn't put the container's eve.sh in place; Fishbowl's own updates would start a second server."
  fi
}
# Fishbowl Server processes the supervisor didn't start (an update that brought
# back Fishbowl's own eve.sh and ran it): stopped, so the supervisor's start is
# the only one.
native_stray_servers() {  # prints their PIDs
  # Fishbowl Server's Java has "-ccom.evnt.eve.Eve" among its arguments, both from
  # the service launcher and from eve.sh; Server Administration's doesn't.
  pgrep -u "$FB_USER" -f '[-]ccom\.evnt\.eve\.Eve( |$)' 2>/dev/null || true
}

# Fishbowl's Linux service launcher starts Fishbowl Server with a Java debugger
# agent (JDWP) listening on 127.0.0.1:7770. Anything that can reach that port can
# run code as Fishbowl's user, and nothing in Fishbowl needs it, so it's taken
# out of the launcher before every start (an upgrade brings it back).
strip_debug_agent() {
  local f="$FB_SERVICE_LAUNCHER"
  [ -f "$f" ] || return 0
  grep -q 'Xrunjdwp' "$f" || return 0
  sed -i -e 's/ "-Xdebug"//g' -e 's/ "-Xnoagent"//g' -e 's/ "-Xrunjdwp:[^"]*"//g' "$f" ||
    { warn "Couldn't take the Java debugger agent (port 7770) out of $f."; return 0; }
  log "Took the Java debugger agent (JDWP, 127.0.0.1:7770) out of Fishbowl's service launcher."
}

# Fishbowl's installer registers a trial under the name "Trial" (26.9.1 wrote "TRIAL").
# Entering a purchased license in Server Administration replaces the name.
installed_is_trial() {
  local n; n="$(eve_get registerName || true)"
  [ -z "$n" ] || [ "$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')" = trial ]
}
# This image's name with another tag, for messages: image_with_tag 2026.9.1
image_with_tag() {
  local img="${FISHBOWL_IMAGE:-fishbowl}"
  [[ "${img##*/}" == *:* ]] && img="${img%:*}"
  printf '%s:%s\n' "$img" "$1"
}

# --------------------------------------------------------------- state ------
setup_complete() { [ -f "$STATE_DIR/setup.complete" ]; }
installed_version() { cat "$STATE_DIR/installed-version" 2>/dev/null || true; }
installed_app_version() {  # what /opt/Fishbowl itself says it is (e.g. 26.10)
  grep -o 'applicationVersion="[^"]*"' "$FB_HOME/.install4j/i4jparams.conf" 2>/dev/null | head -n 1 | cut -d'"' -f2 || true
}
write_state() {  # write_state FILE CONTENT  (atomic)
  local f="$STATE_DIR/$1"
  printf '%s\n' "$2" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# --------------------------------------------------------------- time zone ---
# First-time setup asks for the time zone as a GMT offset (GMT +5, GMT -7) or
# keeps the container's own TZ (docker run -e TZ, FB_TZ in the stack). The answer
# is kept in the data volume as a zone name and applies to MySQL and Fishbowl's
# programs at every start. A GMT offset is an Etc/GMT zone, whose sign is the
# other way round (GMT -7 is Etc/GMT+7) and which never changes for daylight
# saving time.
readonly TIME_ZONE_FILE="$STATE_DIR/timezone"
time_zone_valid() {  # a zone name this image has data for
  [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$ ]] && [ -f "/usr/share/zoneinfo/$1" ]
}
tz_offset_name() {  # tz_offset_name N (-12..14) -> Etc/GMT zone name
  if [ "$1" = 0 ]; then echo Etc/GMT
  elif [ "$1" -gt 0 ]; then echo "Etc/GMT-$1"
  else echo "Etc/GMT+${1#-}"
  fi
}
# tz_parse_offset TEXT -> N for "+5", "-7", "GMT -7", "UTC+05:00", "0". Status 1:
# not an offset; 2: a sign is missing; 3: outside GMT -12 .. GMT +14.
tz_parse_offset() {
  local t sign n
  t="$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  t="${t#GMT}"; t="${t#UTC}"
  [[ "$t" =~ ^([+-]?)0*([0-9]{1,2})(:00)?$ ]] || return 1
  sign="${BASH_REMATCH[1]}"; n=$((10#${BASH_REMATCH[2]}))
  if [ "$n" = 0 ]; then echo 0; return 0; fi
  [ -n "$sign" ] || return 2
  [ "$sign" = - ] && n=$((-n))
  { [ "$n" -ge -12 ] && [ "$n" -le 14 ]; } || return 3
  echo "$n"
}
tz_gmt_now() {  # tz_gmt_now ZONE -> "GMT -7", "GMT +5:30", "GMT +0" as of now
  local z
  z="$(TZ="${1:-UTC}" date +%z)"
  printf 'GMT %s%d' "${z:0:1}" "$((10#${z:1:2}))"
  [ "${z:3:2}" = 00 ] || printf ':%s' "${z:3:2}"
  printf '\n'
}
tz_describe() {  # tz_describe ZONE -> "GMT -7" or "America/Denver (GMT -7 now)"
  case "${1:-UTC}" in
    Etc/GMT*) tz_gmt_now "$1" ;;
    *)        printf '%s (%s now)\n' "${1:-UTC}" "$(tz_gmt_now "${1:-UTC}")" ;;
  esac
}
# apply_time_zone [--log]: TZ from the setup's answer, for everything started
# after it; --log says which one in the container log (once per start).
apply_time_zone() {
  local tz=""
  [ -f "$TIME_ZONE_FILE" ] || return 0
  IFS= read -r tz < "$TIME_ZONE_FILE" || true
  if time_zone_valid "$tz"; then
    export TZ="$tz"
    [ "${1:-}" != --log ] || log "Time zone: $(tz_describe "$TZ") (chosen at setup)"
  else
    warn "The time zone chosen at setup ('$tz' in $TIME_ZONE_FILE) isn't one this image knows; Fishbowl keeps ${TZ:-UTC}."
  fi
}
# db_time_zone_sync: the database container keeps its own TZ (FB_TZ), so a GMT
# offset chosen at setup goes into MySQL itself; SET PERSIST keeps it in MySQL's
# data directory. Only for the Compose stack: the single container's MySQL
# starts with TZ. Needs the root password variable's name.
db_time_zone_sync() {
  local pwvar="$1" want sql have
  db_external || return 0
  case "${TZ:-}" in
    Etc/GMT*) want="$(TZ="$TZ" date +%:z)"; sql="SET PERSIST time_zone = '$want'" ;;
    # A named zone is the database container's own FB_TZ (the one setup offers
    # to keep): MySQL follows its system clock again.
    *)        want=SYSTEM; sql="RESET PERSIST IF EXISTS time_zone; SET GLOBAL time_zone = 'SYSTEM'" ;;
  esac
  have="$(mysql_root "$pwvar" -N -B -e 'SELECT @@GLOBAL.time_zone' 2>/dev/null)" || return 0
  [ "$have" = "$want" ] && return 0
  if mysql_root "$pwvar" -e "$sql" 2>/dev/null; then
    log "MySQL's time zone is now $want ($(tz_describe "${TZ:-UTC}"), chosen at setup)"
  else
    warn "MySQL's time zone couldn't be set to $want; dates MySQL stamps itself may differ from Fishbowl's."
  fi
}

# Facts the page shows next to the status. Written whenever they change.
INFO_UPGRADE_TO=""        # a newer Fishbowl in this image, waiting for the license agreement
INFO_UPGRADE_BLOCKED=""   # "trial": Fishbowl won't update a trial's database
INFO_VOLUMES=named        # "unnamed": Docker's anonymous volumes (container started without -v)
publish_info() {
  local tmp="$INFO_FILE.tmp" kind="" db="" rootpw=""
  mkdir -p "$RUN_DIR"
  if setup_complete; then
    if installed_is_trial; then kind=trial; else kind=licensed; fi
    db="$(eve_get dbName || true)"
    # Set up by this image's own password, or by an earlier version that asked for one?
    if [ -f "$STATE_DIR/mysql-root-password" ]; then rootpw=image; else rootpw=own; fi
  fi
  {
    printf 'image_version=%s\n' "$FISHBOWL_VERSION"
    printf 'image_app_version=%s\n' "$FISHBOWL_APP_VERSION"
    printf 'installed_version=%s\n' "$(installed_version)"
    printf 'install_type=%s\n' "$kind"
    printf 'database=%s\n' "$(printf '%s' "$db" | tr -d '[:cntrl:]')"
    printf 'client_port=%s\n' "$(client_port | tr -dc '0-9')"
    printf 'upgrade_to=%s\n' "$INFO_UPGRADE_TO"
    printf 'upgrade_blocked=%s\n' "$INFO_UPGRADE_BLOCKED"
    printf 'volumes=%s\n' "$INFO_VOLUMES"
    printf 'root_password=%s\n' "$rootpw"
    printf 'image_built=%s\n' "$(image_built | tr -dc '0-9TZ:-')"
    printf 'image_max_age_days=%s\n' "$(image_max_age_days)"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$INFO_FILE"
}

# ------------------------------------------------------------ image age -----
# Decision 4: updates must not quietly stall. Every image build applies every
# package update published so far (update-all.sh --build) and writes when it did
# that here; the weekly maintenance rebuilds. The container log and the page
# say so when an image gets older than FISHBOWL_IMAGE_MAX_AGE_DAYS (14).
readonly IMAGE_BUILT_FILE=/usr/local/share/fishbowl/image-built
image_built() { head -n 1 "$IMAGE_BUILT_FILE" 2>/dev/null || true; }
image_max_age_days() {
  local max="${FISHBOWL_IMAGE_MAX_AGE_DAYS:-14}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=14
  printf '%s\n' "$max"
}
image_age_days() {  # whole days since the image's packages were brought up to date; nothing if unknown
  local built secs
  built="$(image_built)"
  [ -n "$built" ] || return 0
  secs="$(date -u -d "$built" +%s 2>/dev/null)" || return 0
  printf '%s\n' "$(( ( $(date -u +%s) - secs ) / 86400 ))"
}
image_age_check() {  # one warning line when the image is too old; quiet otherwise
  local age max
  age="$(image_age_days)"
  max="$(image_max_age_days)"
  [ -n "$age" ] || return 0
  [ "$age" -gt "$max" ] || return 0
  warn "This image's system packages are $age days old (brought up to date $(image_built)). Security fixes only arrive with a rebuild: let the weekly maintenance run (tools/fishbowl-maintain.sh or .ps1, README section 12) or rebuild the image now."
}

# -------------------------------------------------------------- MySQL -------
MYSQLD_PID=""
mysql_prepare_dirs() {
  mkdir -p "$MYSQL_RUN"
  chown mysql:mysql "$MYSQL_RUN" "$MYSQL_DATA"
  chmod 0750 "$MYSQL_DATA"
  # MySQL silently ignores world-writable option files. The image ships them 0644; on a
  # writable container, put back any that drifted (a read-only one can't drift).
  find /etc/my.cnf "$MYSQL_CNF_DIR" -maxdepth 1 -name '*.cnf' -perm /022 -exec chmod 0644 {} + 2>/dev/null || true
}

mysql_start() {  # starts mysqld in its own session; waits until it accepts connections
  if db_external; then db_wait_external; return 0; fi
  mysql_prepare_dirs
  # A mysqld that was killed (power loss, docker rm -f, a crash) leaves its socket
  # lock files behind. They hold its old process number, and when that number
  # belongs to some other process in this container, MySQL refuses to start
  # ("Another process with pid N is using unix socket file"; seen in testing).
  # Nothing else can be using this data directory: this container holds the lock
  # on the volumes, and its own mysqld is not running.
  if ! pgrep -x mysqld >/dev/null 2>&1; then
    rm -f "$MYSQL_SOCKET" "$MYSQL_SOCKET.lock" "$MYSQL_DATA/mysqlx.sock" "$MYSQL_DATA/mysqlx.sock.lock"
  fi
  # Container-specific options on the command line (they override option files):
  # error log on the data volume, and MySQL reachable only from inside the
  # container (Fishbowl connects over TCP to localhost:3306).
  setsid mysqld --user=mysql --log-error="$LOG_DIR/mysqld.log" \
    --bind-address=127.0.0.1 --mysqlx-bind-address=127.0.0.1 &
  MYSQLD_PID=$!
  local i
  for i in $(seq 1 180); do
    if mysqladmin --protocol=socket --socket="$MYSQL_SOCKET" ping --silent >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$MYSQLD_PID" 2>/dev/null; then
      MYSQLD_PID=""
      tail -n 25 "$LOG_DIR/mysqld.log" >&2 || true
      fail 1 "MySQL exited during startup (its log is above, full log: $LOG_DIR/mysqld.log). If it mentions lower_case_table_names, see Troubleshooting in the README."
    fi
    sleep 1
  done
  fail 1 "MySQL did not accept connections within 180 seconds (log: $LOG_DIR/mysqld.log)."
}

mysql_stop() {  # clean shutdown (SIGTERM is MySQL's normal shutdown signal)
  [ -n "${MYSQLD_PID:-}" ] || return 0
  if kill -0 "$MYSQLD_PID" 2>/dev/null; then
    kill -TERM "$MYSQLD_PID" 2>/dev/null || true
    for _ in $(seq 1 120); do
      kill -0 "$MYSQLD_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$MYSQLD_PID" 2>/dev/null; then
      warn "MySQL did not stop within 120 s; forcing it."
      kill -KILL "$MYSQLD_PID" 2>/dev/null || true
    fi
  fi
  wait "$MYSQLD_PID" 2>/dev/null || true
  MYSQLD_PID=""
}

mysql_is_up() {
  if db_external; then
    # Without credentials: mysqladmin ping answers 0 for a running server even when
    # it turns the sign-in down, so this never needs the password.
    mysqladmin --protocol=tcp -h "$DB_HOST" -P 3306 --connect-timeout=3 ping --silent >/dev/null 2>&1
  else
    mysqladmin --protocol=socket --socket="$MYSQL_SOCKET" ping --silent >/dev/null 2>&1
  fi
}

# The connection id MySQL hands a new connection, read from its greeting (no
# sign-in). It only grows while MySQL runs and starts again from a few after every
# start, so a smaller number than last time means MySQL restarted in between,
# even when it was back too fast for a check to see it gone. Prints nothing when
# MySQL doesn't greet (not up, or busy refusing connections).
db_conn_id() {
  python3 -I - "$DB_HOST" 2>/dev/null <<'PY'
import socket, struct, sys
s = socket.create_connection((sys.argv[1], 3306), timeout=3)
s.settimeout(3)
data = b""
while len(data) < 4 or len(data) < 4 + int.from_bytes(data[:3], "little"):
    chunk = s.recv(512)
    if not chunk:
        break
    data += chunk
s.close()
p = data[4:]
if not p or p[0] != 10:   # protocol 10 greeting; 0xff would be an error packet
    sys.exit(1)
end = p.index(b"\0", 1)
print(struct.unpack("<I", p[end + 1:end + 5])[0])
PY
}

# MySQL in its own container: wait for it (it may still be starting, or restarting
# after a crash), then point Fishbowl at it. No time limit: without the database
# there's nothing to start, and the page says what's going on.
db_wait_external() {
  local waited=0 db_pw="" _
  MYSQLD_PID=""
  if ! mysql_is_up; then
    log "Waiting for the database container ($DB_HOST:3306) to accept connections"
    while ! mysql_is_up; do
      sleep 2
      waited=$((waited + 2))
      if [ $((waited % 120)) = 0 ]; then
        warn "The database container ($DB_HOST:3306) still isn't answering after ${waited}s: docker compose ps db; docker logs fishbowl-db"
      fi
    done
  fi
  # On a data directory from the single container, the database container adds
  # root's account for its network a moment after MySQL starts; until then MySQL
  # answers but turns root down, and Fishbowl Server would start only to be
  # refused. So wait (up to a minute) until root can sign in. An installation with
  # a root password of its own never can with this one: it just goes on.
  if [ -r "${FISHBOWL_DB_ROOT_PASSWORD_FILE:-}" ]; then
    db_pw="$(default_root_password)"
    for _ in $(seq 1 30); do
      mysql_root db_pw -N -B -e 'SELECT 1' >/dev/null 2>&1 && break
      sleep 2
    done
    db_time_zone_sync db_pw   # a GMT offset chosen at setup holds in MySQL too
    db_pw=""
  fi
  db_point_fishbowl
}

# Fishbowl keeps the database host in eve.properties and, per database, in
# dbsettings.properties; Server Administration writes "localhost" there. In the
# stack it's the database container, set before every start of Fishbowl Server.
db_point_fishbowl() {
  local want="$DB_HOST"
  if ! db_external; then
    # Back in the single container after the Compose stack: only the stack's own
    # value (db) is put back to this container's MySQL.
    [ -f "$FB_EVE" ] && [ "$(props_get "$FB_EVE" dbHost 2>/dev/null || true)" = db ] || return 0
    want=localhost
    log "Fishbowl's settings pointed at the Compose stack's database container; pointing them at this container's MySQL (localhost)"
  fi
  if [ -f "$FB_EVE" ] && [ "$(props_get "$FB_EVE" dbHost 2>/dev/null || true)" != "$want" ]; then
    props_set "$FB_EVE" dbHost "$want"
  fi
  if [ -f "$FB_BIN/dbsettings.properties" ]; then
    python3 -I - "$FB_BIN/dbsettings.properties" "$want" <<'PY' || warn "Couldn't set the database host in dbsettings.properties."
import json, os, sys
path, host = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    text = f.read()
data = json.loads(text) if text.strip() else []
if isinstance(data, list) and any(isinstance(d, dict) and d.get("host") != host for d in data):
    for d in data:
        if isinstance(d, dict):
            d["host"] = host
    st = os.stat(path)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"))
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, path)
PY
  fi
}

# mysql_root <password-var-name> <mysql args...>  -- runs the client as root over TCP,
# the way Fishbowl connects. The password goes through MYSQL_PWD for this one
# process only (no command line, no disk).
mysql_root() {
  local __pwvar="$1"; shift
  MYSQL_PWD="${!__pwvar}" mysql --protocol=tcp -h "$DB_HOST" -P 3306 -u root "$@"
}

sql_quote() {  # escape for a single-quoted SQL string literal (sql_mode has no NO_BACKSLASH_ESCAPES)
  local s="${1//\\/\\\\}"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

# Fishbowl's own my.cnf carries MySQL tuning for Fishbowl. Load it, minus the two
# settings the guide controls (sql-mode and lower_case_table_names live in
# 90-fishbowl.cnf, which also sorts later so it would win anyway).
apply_fishbowl_mycnf() {
  local src="$FB_BIN/my.cnf" tmp dst="$FB_MYCNF_DST"
  # In the stack, the database container reads the file from a shared volume at
  # its next start (docker compose restart db after a Fishbowl upgrade).
  if db_external; then
    [ -n "$DB_CONF_DIR" ] || return 0
    dst="$DB_CONF_DIR/50-fishbowl-server.cnf"
  fi
  mkdir -p "$(dirname "$dst")"
  if [ ! -f "$src" ]; then
    rm -f "$dst"
    warn "Fishbowl's server/bin/my.cnf was not found; MySQL runs without Fishbowl's tuning."
    return 0
  fi
  tmp="$(mktemp)"
  python3 -I "$LIB_DIR/mycnf.py" "$src" > "$tmp"
  if ! cmp -s "$tmp" "$dst"; then
    if am_root; then install -m 0644 -o root -g root "$tmp" "$dst"; else install -m 0644 "$tmp" "$dst"; fi
    db_external && log "Fishbowl's MySQL tuning is in $dst; the database container uses it from its next start."
  fi
  rm -f "$tmp"
}

# --------------------------------------------------------- Fishbowl ---------
FB_PID=""

fix_ownership() {  # Section 8.1: the user that runs the server owns /opt/Fishbowl
  find "$FB_HOME" \( ! -user "$FB_USER" -o ! -group "$FB_USER" \) -exec chown -h "$FB_USER:$FB_USER" {} + 2>/dev/null || true
  # Files that hold the License Key (and Fishbowl's encrypted DB password): owner only.
  local f
  for f in "$FB_EVE" "$FB_BIN/dbsettings.properties" "$FB_HOME/installSettings" \
           "$FB_HOME/.install4j/response.varfile" "$FB_HOME/.install4j/installation.log"; do
    [ -e "$f" ] && chmod 0600 "$f"
  done
  mkdir -p "$HOMES_DIR/$FB_USER"
  chown "$FB_USER:$FB_USER" "$HOMES_DIR/$FB_USER"
  chmod 0700 "$HOMES_DIR/$FB_USER"
}

# Fishbowl Server writes eve.properties back from memory when it stops (seen with
# 26.10), so settings changed in Server Administration while it runs would be lost
# at the next restart. fishbowl-session keeps a copy of the changed file; the next
# start of Fishbowl Server puts it back before the server reads it.
save_pending_settings() {
  ( umask 077; cp "$FB_EVE" "$PENDING_EVE.tmp" ) && mv -f "$PENDING_EVE.tmp" "$PENDING_EVE"
  # For the page: which company database is selected after the restart.
  { eve_get dbName || true; } | tr -d '[:cntrl:]' > "$PENDING_FLAG.tmp"
  chmod 0644 "$PENDING_FLAG.tmp"
  mv -f "$PENDING_FLAG.tmp" "$PENDING_FLAG"
}
apply_pending_settings() {
  rm -f "$PENDING_FLAG"
  [ -f "$PENDING_EVE" ] || return 0
  install -m 0600 -o "$FB_USER" -g "$FB_USER" "$PENDING_EVE" "$FB_EVE"
  rm -f "$PENDING_EVE"
  log "Applied the settings changed in Server Administration (company database: $(eve_get dbName || echo none))"
}

# The drop folder for .sql files to restore in Server Administration (Restore
# tab). Files arrive two ways: uploaded on the page (owned by the page's user)
# or with `docker cp` (owned by root). Server Administration runs as fishbowl,
# so the folder belongs to fishbowl, the page's group may add and remove files,
# and nobody else gets in. A link in fishbowl's home puts the folder one click
# away in Fishbowl's file chooser. Only plain files and folders are touched.
prepare_import_dir() {
  mkdir -p "$IMPORT_DIR" "$HOMES_DIR/$FB_USER"
  # The split stack's page runs in Fishbowl's group (it has no root to chown with).
  if am_root; then
    find "$IMPORT_DIR" -xdev \( -type f -o -type d \) \( ! -user "$FB_USER" -o ! -group "$WEB_USER" \) \
      -exec chown "$FB_USER:$WEB_USER" {} + 2>/dev/null || true
  fi
  find "$IMPORT_DIR" -xdev -mindepth 1 -type f ! -perm -0640 -exec chmod u+rw,g+r {} + 2>/dev/null || true
  chmod 2770 "$IMPORT_DIR"
  if [ ! -e "$HOMES_DIR/$FB_USER/import" ] && [ ! -L "$HOMES_DIR/$FB_USER/import" ]; then
    ln -s "$IMPORT_DIR" "$HOMES_DIR/$FB_USER/import"
  fi
}

# Memory: the installer reads "prior memory settings" from these files at start
# and writes -Xmx${memoryServer}M / -Xmx${memoryClient}M back into them. Seeding
# them before a first install makes the installer itself apply 8192/2048.
seed_memory_settings() {
  local name
  mkdir -p "$FB_BIN" "$FB_HOME/client/bin"
  for name in "${SERVER_VMOPTIONS[@]}"; do
    [ -f "$FB_BIN/$name.vmoptions" ] || printf -- '-Xmx%sM\n' "$SERVER_MEMORY_MB" > "$FB_BIN/$name.vmoptions"
  done
  for name in "${CLIENT_VMOPTIONS[@]}"; do
    [ -f "$FB_HOME/client/bin/$name.vmoptions" ] || printf -- '-Xmx%sM\n' "$CLIENT_MEMORY_MB" > "$FB_HOME/client/bin/$name.vmoptions"
  done
}

# Upgrades keep whatever memory the launchers had before (8192/2048 from setup, or
# a value set later in Server Administration): put back any file the installer changed.
save_memory_settings() {  # save_memory_settings DIR
  mkdir -p "$1/server" "$1/client"
  cp -p "$FB_BIN"/*.vmoptions "$1/server/" 2>/dev/null || true
  cp -p "$FB_HOME"/client/bin/*.vmoptions "$1/client/" 2>/dev/null || true
}
restore_memory_settings() {  # restore_memory_settings DIR
  local f dest before after
  for f in "$1"/server/*.vmoptions "$1"/client/*.vmoptions; do
    [ -f "$f" ] || continue
    case "$f" in
      */server/*) dest="$FB_BIN/${f##*/}" ;;
      *)          dest="$FB_HOME/client/bin/${f##*/}" ;;
    esac
    before="$(grep -E '^-Xmx' "$f" | tail -n 1 || true)"
    after="$(grep -E '^-Xmx' "$dest" 2>/dev/null | tail -n 1 || true)"
    if [ "$before" != "$after" ]; then
      warn "The installer changed ${dest##*/} (${after:-no -Xmx}); putting back ${before:-the previous file}."
      cp -p "$f" "$dest"
    fi
  done
}
xmx_of() { grep -E '^-Xmx' "$1" 2>/dev/null | tail -n 1 | sed 's/^-Xmx//' || true; }

# Server Administration's "Server memory" (Server tab) writes the new -Xmx to
# "Fishbowl Server.vmoptions", "Fishbowl Server Console.vmoptions" and
# "Fishbowl_Server_Service.vmoptions" (the Windows service's file name), but not to
# "Fishbowl Server Service.vmoptions", which the service launcher used here reads.
# Carry the value over before each start so the setting takes effect.
sync_server_memory() {
  local src="$FB_BIN/Fishbowl_Server_Service.vmoptions" dst="$FB_BIN/Fishbowl Server Service.vmoptions"
  local want="" have why="Server Administration's setting"
  # FISHBOWL_SERVER_XMX (FB_SERVER_XMX in the Compose stack's .env), when set,
  # wins over Server Administration's memory field: it's written before every
  # start. Unset (again), Server Administration's value stands: the Windows-named
  # file once it has changed the memory, else "Fishbowl Server.vmoptions", which
  # setup and Server Administration both write.
  if [ -n "${FISHBOWL_SERVER_XMX:-}" ]; then
    if [[ "$FISHBOWL_SERVER_XMX" =~ ^[1-9][0-9]*[mMgG]$ ]]; then
      want="$FISHBOWL_SERVER_XMX"; why="set by FISHBOWL_SERVER_XMX"
    else
      warn "FISHBOWL_SERVER_XMX must look like 4096m or 6g; '$FISHBOWL_SERVER_XMX' is ignored."
    fi
  fi
  if [ -z "$want" ]; then
    if [ -f "$src" ]; then want="$(xmx_of "$src")"; else want="$(xmx_of "$FB_BIN/Fishbowl Server.vmoptions")"; fi
  fi
  [ -f "$dst" ] || return 0
  have="$(xmx_of "$dst")"
  [ -n "$want" ] && [ "$want" != "$have" ] || return 0
  if grep -qE '^-Xmx' "$dst"; then
    sed -i -E "s/^-Xmx.*/-Xmx${want}/" "$dst"
  else
    printf -- '-Xmx%s\n' "$want" >> "$dst"
  fi
  am_root && chown "$FB_USER:$FB_USER" "$dst"
  log "Server memory: now ${want} (was ${have:-unset}), $why"
}

# FISHBOWL_PORT and FISHBOWL_LEGACY_PORT (FB_CLIENT_PORT and FB_API_PORT in the
# Compose stack) name the two ports this container is published on. Docker
# reserves published ports on the computer whether anything listens behind them
# or not, so a container must publish only the pair its Fishbowl Server uses: a
# second Fishbowl on the same computer (2457 and 28193, say) can then have the
# others. When set, they're written into Server Administration's Port and Legacy
# Port (webPort and port in eve.properties) before every start, so that window
# always shows the ports that really run; a different value saved there is put
# back, with a log line saying how to move the container instead. Unset (a
# container from an earlier version of these instructions), Server
# Administration's values stand.
port_number_ok() { [[ "${1:-}" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }
sync_server_ports() {
  local key var want have
  [ -f "$FB_EVE" ] || return 0
  for key in webPort port; do
    if [ "$key" = webPort ]; then var=FISHBOWL_PORT; else var=FISHBOWL_LEGACY_PORT; fi
    want="${!var:-}"
    [ -n "$want" ] || continue
    if ! port_number_ok "$want" || [[ " 3306 33060 6080 7770 " == *" $want "* ]]; then
      warn "$var must be a free port number such as $([ "$key" = webPort ] && echo 2457 || echo 28193); '$want' is ignored, so Server Administration's setting stands."
      continue
    fi
    have="$(props_get "$FB_EVE" "$key" 2>/dev/null || true)"
    [ "$have" = "$want" ] && continue
    props_set "$FB_EVE" "$key" "$want"
    if [ -n "$have" ]; then
      log "Server Administration's $([ "$key" = webPort ] && echo Port || echo "Legacy Port") was $have; set to $want, the port this container is published on ($var). To use $have instead, start the container again with -p $have:$have and $var=$have (README, \"Two Fishbowl Servers on one computer\")."
    fi
  done
  return 0
}
# run_ports_text: the -p and -e options for this container's pair of ports, for
# the docker run commands the log prints.
run_ports_text() {
  local p l
  p="${FISHBOWL_PORT:-$(eve_get webPort || true)}"; p="${p:-2456}"
  l="${FISHBOWL_LEGACY_PORT:-$(eve_get port || true)}"; l="${l:-28192}"
  printf -- '-p %s:%s -p %s:%s -e FISHBOWL_PORT=%s -e FISHBOWL_LEGACY_PORT=%s' "$p" "$p" "$l" "$l" "$p" "$l"
}

verify_memory_settings() {  # fails if 8192 / 2048 did not take effect
  local name f bad=0
  for name in "${SERVER_VMOPTIONS[@]}"; do
    f="$FB_BIN/$name.vmoptions"
    if ! grep -qx -- "-Xmx${SERVER_MEMORY_MB}M" "$f" 2>/dev/null; then
      warn "$f does not set -Xmx${SERVER_MEMORY_MB}M"; bad=1
    fi
  done
  for name in "${CLIENT_VMOPTIONS[@]}"; do
    f="$FB_HOME/client/bin/$name.vmoptions"
    if ! grep -qx -- "-Xmx${CLIENT_MEMORY_MB}M" "$f" 2>/dev/null; then
      warn "$f does not set -Xmx${CLIENT_MEMORY_MB}M"; bad=1
    fi
  done
  if ! grep -q -- "-Xmx${CLIENT_MEMORY_MB}M" "$FB_HOME/client/bin/client.sh" 2>/dev/null; then
    warn "client/bin/client.sh does not set -Xmx${CLIENT_MEMORY_MB}M"; bad=1
  fi
  [ "$bad" = 0 ]
}

# Runs the bundled installer unattended with the given response file.
# Output goes to the log file only (it contains no secrets, but keeps the log clean).
clear_installer_tmp() {
  mkdir -p "$INSTALLER_TMP"
  chmod 0700 "$INSTALLER_TMP"
  find "$INSTALLER_TMP" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
}

run_installer() {  # run_installer <varfile> <logfile>
  local varfile="$1" logfile="$2" rc=0 vm_params=""
  # The installer unpacks into <temp>/<name>.<PID>.dir. PIDs repeat in a fresh
  # container, so leftovers from an interrupted run must go first, or gunzip
  # stops to ask whether to overwrite them.
  clear_installer_tmp
  mkdir -p "$HOMES_DIR/root"
  chmod 0700 "$HOMES_DIR/root"
  # Where the image points the installer's systemd unit file (see the Dockerfile).
  if [ -L /etc/systemd/system ]; then mkdir -p "$(readlink /etc/systemd/system)" 2>/dev/null || true; fi
  # Fishbowl's installer stops unless it runs as root ("You must be logged in as
  # root"), and all it looks at is Java's user.name (install4j's UnixUserInfo).
  # In the Compose stack nothing runs as root, so the installer is given the name
  # it wants: it still runs as Fishbowl's user and writes only where that user
  # can (Fishbowl's volumes and /tmp).
  am_root || vm_params="-Duser.name=root"
  (
    cd "$INSTALLER_TMP"
    # HOME on the data volume keeps install4j's own records (previous install
    # location, JVM cache) across container re-creation, like /root on a host.
    # stdin is /dev/null: nothing inside the installer may wait on a terminal.
    exec env -i PATH="$JAVA21_HOME/bin:/usr/local/bin:/usr/bin:/bin" HOME="$HOMES_DIR/root" \
      LANG="${LANG:-C.UTF-8}" TZ="${TZ:-UTC}" INSTALL4J_TEMP="$INSTALLER_TMP" \
      INSTALL4J_JAVA_HOME_OVERRIDE="$JAVA21_HOME" INSTALL4J_JAVA_HOME="$JAVA21_HOME" \
      ${vm_params:+"INSTALL4J_ADD_VM_PARAMS=$vm_params"} \
      sh "$FISHBOWL_INSTALLER" -q -varfile "$varfile" -dir "$FB_HOME" </dev/null
  ) >>"$logfile" 2>&1 || rc=$?
  clear_installer_tmp
  return "$rc"
}

# ------------------------------------------------- copy-paste commands ------
# Best effort: the Docker volume name mounted at a path (named volumes show up in
# mountinfo as .../volumes/<name>/_data). Falls back to the documented default.
volume_name_for() {
  local path="$1" default="$2" src
  src="$(awk -v p="$path" '$5 == p {print $4}' /proc/self/mountinfo 2>/dev/null | tail -n 1)"
  if [[ "$src" =~ /volumes/([^/]+)/_data$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$default"
  fi
}

print_run_command() {  # print_run_command [docker-only]
  note "  docker run -d --name fishbowl --restart always --stop-timeout 180 \\"
  note "    $(run_ports_text) -p 127.0.0.1:6080:6080 \\"
  note "    -v $(volume_name_for "$MYSQL_DATA" fishbowl-mysql):/var/lib/mysql \\"
  note "    -v $(volume_name_for "$FB_HOME" fishbowl-app):/opt/Fishbowl \\"
  note "    -v $(volume_name_for "$DATA_DIR" fishbowl-data):/var/lib/fishbowl \\"
  note "    ${FISHBOWL_IMAGE:-fishbowl}"
  if [ "${1:-}" != docker-only ]; then
    note ""
    note "or, with this repository's compose.yaml:"
    note "  docker compose up -d"
  fi
  note ""
  note "(If your image has another name, use it in place of ${FISHBOWL_IMAGE:-fishbowl}.)"
}

# ------------------------------------------------------ the Fishbowl page ---
# Whoever opens the page needs the access code. It is made once and kept on the
# data volume so links and browser sign-ins survive restarts; `fishbowl-link
# --new-code` replaces it. It only opens the page: MySQL and Fishbowl keep
# their own passwords.
web_code() { head -n 1 "$WEB_CODE_RUN" 2>/dev/null | tr -dc 'A-Z0-9-' || true; }
web_code_init() {  # web_code_init [new]: makes sure a code exists and the page's user can read it
  local code="" raw keep="$WEB_CODE_FILE"
  mkdir -p "$RUN_DIR"
  # The split stack's page keeps its code in its own folder and runs as itself: its
  # copy in /run/fishbowl is readable by Fishbowl's group too, for fishbowl-link.
  if split_role; then keep="$PAGE_DIR/web-code"; fi
  if [ "${1:-}" != new ] && [ -f "$keep" ]; then
    code="$(head -n 1 "$keep" | tr -dc 'A-Z0-9-' || true)"
  fi
  if ! [[ "$code" =~ ^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$ ]]; then
    raw="$(random_code 12)"
    [ "${#raw}" = 12 ] || fail 1 "Could not generate an access code for the Fishbowl page."
    code="${raw:0:4}-${raw:4:4}-${raw:8:4}"
    if [ -d "$(dirname "$keep")" ]; then
      ( umask 077; printf '%s\n' "$code" > "$keep.tmp" ) && mv -f "$keep.tmp" "$keep"
    fi
  fi
  ( umask 077; printf '%s\n' "$code" > "$WEB_CODE_RUN.tmp" )
  if am_root; then
    chown "$WEB_USER:$WEB_USER" "$WEB_CODE_RUN.tmp"
    chmod 0400 "$WEB_CODE_RUN.tmp"
  else
    chmod 0440 "$WEB_CODE_RUN.tmp"
  fi
  mv -f "$WEB_CODE_RUN.tmp" "$WEB_CODE_RUN"
}
page_url() {  # page_url [path]  ->  http://localhost:6080/<path>?code=...
  printf 'http://localhost:%s/%s?code=%s\n' "$WEB_PORT" "${1:-}" "$(web_code)"
}
# The page's address on your network, when the Compose stack's HTTPS edge serves
# it (FISHBOWL_PAGE_URL, for example https://fishbowl.example.com/); empty otherwise.
page_url_lan() {  # page_url_lan [path]
  local base="${FISHBOWL_PAGE_URL:-}"
  [ -n "$base" ] || return 0
  [[ "$base" =~ ^https?://[A-Za-z0-9.:-]+/?$ ]] || return 0
  base="${base%/}"
  base="${base%:443}"   # https://host:443 is https://host
  printf '%s/%s?code=%s\n' "$base" "${1:-}" "$(web_code)"
}
print_page_link() {
  hr
  note " The Fishbowl page: setup, Server Administration and the Fishbowl Client"
  note " in your browser. Open this on the computer that runs Docker:"
  note ""
  note "     $(page_url)"
  note ""
  note " (The link needs port $WEB_PORT published, as in the README and compose.yaml:"
  note "  -p 127.0.0.1:$WEB_PORT:$WEB_PORT. Show it again: docker exec <container> fishbowl-link)"
  hr
}

# Hands a request to the entrypoint, the same way the page does. For the
# terminal commands (fishbowl-setup, fishbowl-upgrade, fishbowl-admin).
web_request() {  # web_request NAME [FILE-WITH-CONTENT]
  local name="$1" src="${2:-}" tmp
  [ -d "$WEB_SPOOL" ] || fail 1 "The container isn't ready for requests yet. Is it running (docker ps)?"
  tmp="$(mktemp "$WEB_SPOOL/.req.XXXXXX")"
  chmod 0600 "$tmp"
  if [ -n "$src" ]; then cat "$src" > "$tmp"; fi
  mv -f "$tmp" "$WEB_SPOOL/$name"
}

# ---------------------------------------------------------------- EULA ------
eula_sha256() { sha256sum "$FISHBOWL_EULA" | cut -d' ' -f1; }

record_eula_acceptance() {  # record_eula_acceptance VERSION METHOD
  mkdir -p "$STATE_DIR/eula"
  {
    printf 'accepted_at=%s\n' "$(_ts)"
    printf 'fishbowl_version=%s\n' "$1"
    printf 'eula_file=%s\n' "$(basename "$FISHBOWL_EULA")"
    printf 'eula_sha256=%s\n' "$(eula_sha256)"
    printf 'method=%s\n' "$2"
  } > "$STATE_DIR/eula/accepted-$1"
}

# Terminal version: shows the license text the installer shows, then requires a
# typed "yes". Returns 0 only on an explicit yes; 1 on anything else; 2 when
# nobody answered (EOF or timeout). Records nothing: the entrypoint does that
# when it receives the answers.
eula_accept() {
  local answer="" enter=""
  hr
  note "FISHBOWL LICENSE AGREEMENT (Fishbowl $FISHBOWL_APP_VERSION)"
  note ""
  note "Before anything is installed you need to read and accept Fishbowl's"
  note "license agreement. This is the same text Fishbowl's installer displays."
  note "It opens in a pager: Space or PgDn scrolls, q closes it."
  note ""
  if ! ask enter "Press Enter to open the license agreement... " "$FIRST_PROMPT_TIMEOUT"; then
    return 2   # nobody at the keyboard
  fi
  if command -v less >/dev/null 2>&1 && [ -n "${TERM:-}" ] && [ "$TERM" != dumb ]; then
    LESSSECURE=1 less -R -P "Fishbowl license agreement (q when done) - %pB\%" "$FISHBOWL_EULA" || true
  else
    cat "$FISHBOWL_EULA"
  fi
  note ""
  note "The full text is also inside the image at $FISHBOWL_EULA"
  local v
  for v in ${FISHBOWL_EULA_VARIANTS:-}; do
    [ "$INSTALLER_DIR/eula/$v" = "$FISHBOWL_EULA" ] && continue
    note "The installer also contains another version of the terms: $INSTALLER_DIR/eula/$v"
  done
  note ""
  if ! ask answer 'Do you accept the Fishbowl license agreement? Type "yes" to accept: '; then
    return 2
  fi
  answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ "$answer" = "yes" ]
}
