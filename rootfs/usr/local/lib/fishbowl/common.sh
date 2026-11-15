# shellcheck shell=bash
# shellcheck disable=SC2034  # constants and state used by the scripts that source this file
# Shared helpers for the Fishbowl container scripts. Sourced, never executed.
#
# Secrets rule for every script in this image: the License Key and the MySQL
# root password are read without echo, never passed on a command line, never
# exported, never logged. Temporary files that hold them live in /dev/shm
# (RAM), mode 0600, and are deleted by a trap.

set -o errexit -o nounset -o pipefail
set +o histexpand  # passwords may contain '!'
umask 022          # `docker exec` sessions can inherit umask 0000; MySQL ignores world-writable config

readonly FB_HOME=/opt/Fishbowl
readonly FB_BIN=/opt/Fishbowl/server/bin
readonly FB_EVE=/opt/Fishbowl/server/bin/eve.properties
readonly FB_SERVICE_LAUNCHER="/opt/Fishbowl/server/bin/Fishbowl Server Service"
readonly FB_ADMIN_LAUNCHER="/opt/Fishbowl/server/bin/Fishbowl Server Administration"
readonly FB_SERVER_LOG=/opt/Fishbowl/logs/fbserver.log
readonly MYSQL_DATA=/var/lib/mysql
readonly MYSQL_SOCKET=/var/lib/mysql/mysql.sock
readonly MYSQL_RUN=/run/mysqld
readonly MYSQL_CNF_DIR=/etc/my.cnf.d
readonly FB_MYCNF_DST=/etc/my.cnf.d/50-fishbowl-server.cnf
readonly DATA_DIR=/var/lib/fishbowl
readonly STATE_DIR=/var/lib/fishbowl/state
readonly BACKUP_DIR=/var/lib/fishbowl/backups
readonly LOG_DIR=/var/lib/fishbowl/logs
readonly HOMES_DIR=/var/lib/fishbowl/home
readonly IMPORT_DIR=/var/lib/fishbowl/import   # drop .sql files here for the Restore tab
readonly PENDING_EVE=/var/lib/fishbowl/state/pending-eve.properties
readonly INSTALLER_TMP=/var/lib/fishbowl/tmp
readonly RUN_DIR=/run/fishbowl
readonly STATUS_FILE=/run/fishbowl/status
readonly INSTALLER_DIR=/opt/fishbowl-installer
readonly JAVA21_HOME=/usr/lib/jvm/temurin-21-jdk
readonly FB_USER=fishbowl
readonly LIB_DIR=/usr/local/lib/fishbowl
readonly PROMPT_TIMEOUT="${FISHBOWL_PROMPT_TIMEOUT:-1800}"   # seconds per answer
# "Press Enter" presence check: catches `docker run -t` without -i (output but no input).
readonly FIRST_PROMPT_TIMEOUT="$(( PROMPT_TIMEOUT < 300 ? PROMPT_TIMEOUT : 300 ))"

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
log()  { printf '%s [fishbowl] %s\n' "$(_ts)" "$*"; }
note() { printf '%s\n' "$*"; }
warn() { printf '%s [warning] %s\n' "$(_ts)" "$*" >&2; }
# fail <exit-code> <message...>
fail() {
  local code="$1"; shift
  printf '\n%s [error] %s\n\n' "$(_ts)" "$*" >&2
  exit "$code"
}
set_status() { mkdir -p "$RUN_DIR"; printf '%s\n' "$*" > "$STATUS_FILE"; }
hr() { printf '%s\n' "------------------------------------------------------------------------"; }

is_interactive() { [ -t 0 ] && [ -t 1 ]; }

# ----------------------------------------------------------- prompting ------
# All prompts time out so a terminal that shows output but can't send input
# (`docker run -t` without -i) never hangs the container.
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

# --------------------------------------------------------- run commands -----
as_user() {  # as_user <user> <cmd...>   (keeps the environment we pass explicitly)
  local user="$1"; shift
  setpriv --reuid="$user" --regid="$user" --init-groups --inh-caps=-all -- "$@"
}

ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }

secret_dir() {  # prints a fresh 0700 directory in /dev/shm (RAM)
  local d
  [ -d /dev/shm ] && [ -w /dev/shm ] || fail 1 "/dev/shm is not available; secrets would have to touch disk. Run the container with Docker's default /dev/shm."
  d="$(mktemp -d /dev/shm/fishbowl.XXXXXX)"
  chmod 0700 "$d"
  printf '%s\n' "$d"
}

# --------------------------------------------------- Java properties files --
props_get() { python3 -I "$LIB_DIR/props.py" get "$1" "$2"; }    # props_get FILE KEY
props_escape() { python3 -I "$LIB_DIR/props.py" escape; }          # value on stdin

eve_get() { [ -f "$FB_EVE" ] && props_get "$FB_EVE" "$1" 2>/dev/null; }
database_configured() { local n; n="$(eve_get dbName || true)"; [ -n "$n" ]; }
client_port() { local p; p="$(eve_get webPort || true)"; printf '%s\n' "${p:-2456}"; }
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
write_state() {  # write_state FILE CONTENT  (atomic)
  local f="$STATE_DIR/$1"
  printf '%s\n' "$2" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# -------------------------------------------------------------- MySQL -------
MYSQLD_PID=""
mysql_prepare_dirs() {
  mkdir -p "$MYSQL_RUN"
  chown mysql:mysql "$MYSQL_RUN" "$MYSQL_DATA"
  chmod 0750 "$MYSQL_DATA"
  # MySQL silently ignores world-writable option files; make sure ours aren't.
  chmod 0644 "$MYSQL_CNF_DIR"/*.cnf /etc/my.cnf
}

mysql_start() {  # starts mysqld in its own session; waits until it accepts connections
  mysql_prepare_dirs
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
  [ -n "$MYSQLD_PID" ] || return 0
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

# mysql_root <password-var-name> <mysql args...>  -- runs the client as root over TCP,
# the way Fishbowl connects. The password goes through MYSQL_PWD for this one
# process only (no command line, no disk).
mysql_root() {
  local __pwvar="$1"; shift
  MYSQL_PWD="${!__pwvar}" mysql --protocol=tcp -h 127.0.0.1 -P 3306 -u root "$@"
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
  local src="$FB_BIN/my.cnf" tmp
  if [ ! -f "$src" ]; then
    rm -f "$FB_MYCNF_DST"
    warn "Fishbowl's server/bin/my.cnf was not found; MySQL runs without Fishbowl's tuning."
    return 0
  fi
  tmp="$(mktemp)"
  python3 -I "$LIB_DIR/mycnf.py" "$src" > "$tmp"
  install -m 0644 -o root -g root "$tmp" "$FB_MYCNF_DST"
  rm -f "$tmp"
}

# --------------------------------------------------------- Fishbowl ---------
FB_PID=""
fishbowl_env() {
  env -i PATH="$JAVA21_HOME/bin:/usr/local/bin:/usr/bin:/bin" \
    HOME="$HOMES_DIR/$FB_USER" USER="$FB_USER" LOGNAME="$FB_USER" LANG="${LANG:-C.UTF-8}" \
    TZ="${TZ:-UTC}" JAVA_HOME="$JAVA21_HOME" \
    INSTALL4J_JAVA_HOME_OVERRIDE="$JAVA21_HOME" INSTALL4J_JAVA_HOME="$JAVA21_HOME" "$@"
}

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

# Memory: the installer reads "prior memory settings" from these files at start
# and writes -Xmx${memoryServer}M / -Xmx${memoryClient}M back into them. Seeding
# them before a first install makes the installer itself apply 8192/2048.
# Fishbowl Server writes eve.properties back from memory when it stops (seen with
# 26.10), so settings changed in Server Administration while it runs would be lost
# at the next restart. fishbowl-admin keeps a copy of the changed file; the next
# start of the container puts it back before Fishbowl Server reads it.
save_pending_settings() {
  ( umask 077; cp "$FB_EVE" "$PENDING_EVE.tmp" ) && mv -f "$PENDING_EVE.tmp" "$PENDING_EVE"
}
apply_pending_settings() {
  [ -f "$PENDING_EVE" ] || return 0
  install -m 0600 -o "$FB_USER" -g "$FB_USER" "$PENDING_EVE" "$FB_EVE"
  rm -f "$PENDING_EVE"
  log "Applied the settings changed in Server Administration (company database: $(eve_get dbName || echo unknown))"
}

# A drop folder for .sql files to restore in Server Administration (Restore tab).
# `docker cp` delivers files owned by root, and Server Administration runs as
# fishbowl, so they're handed over. A link in fishbowl's home puts the folder one
# click away in Fishbowl's file chooser. Only plain files and folders are touched.
prepare_import_dir() {
  mkdir -p "$IMPORT_DIR" "$HOMES_DIR/$FB_USER"
  find "$IMPORT_DIR" -xdev \( -type f -o -type d \) \( ! -user "$FB_USER" -o ! -group "$FB_USER" \) \
    -exec chown "$FB_USER:$FB_USER" {} + 2>/dev/null || true
  chmod 0750 "$IMPORT_DIR"
  if [ ! -e "$HOMES_DIR/$FB_USER/import" ] && [ ! -L "$HOMES_DIR/$FB_USER/import" ]; then
    ln -s "$IMPORT_DIR" "$HOMES_DIR/$FB_USER/import"
  fi
}

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
  local want have
  [ -f "$src" ] || return 0
  want="$(xmx_of "$src")"
  have="$(xmx_of "$dst")"
  [ -n "$want" ] && [ "$want" != "$have" ] || return 0
  if [ -f "$dst" ] && grep -qE '^-Xmx' "$dst"; then
    sed -i -E "s/^-Xmx.*/-Xmx${want}/" "$dst"
  else
    printf -- '-Xmx%s\n' "$want" >> "$dst"
  fi
  chown "$FB_USER:$FB_USER" "$dst"
  log "Server memory changed in Server Administration: now ${want} (was ${have:-unset})"
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
# Output goes to the log file only (it contains no secrets, but keeps the terminal clean).
clear_installer_tmp() {
  mkdir -p "$INSTALLER_TMP"
  chmod 0700 "$INSTALLER_TMP"
  find "$INSTALLER_TMP" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
}

run_installer() {  # run_installer <varfile> <logfile>
  local varfile="$1" logfile="$2" rc=0
  # The installer unpacks into <temp>/<name>.<PID>.dir. PIDs repeat in a fresh
  # container, so leftovers from an interrupted run must go first, or gunzip
  # stops to ask whether to overwrite them.
  clear_installer_tmp
  mkdir -p "$HOMES_DIR/root"
  chmod 0700 "$HOMES_DIR/root"
  (
    cd "$INSTALLER_TMP"
    # HOME on the data volume keeps install4j's own records (previous install
    # location, JVM cache) across container re-creation, like /root on a host.
    # stdin is /dev/null: nothing inside the installer may wait on the terminal.
    exec env -i PATH="$JAVA21_HOME/bin:/usr/local/bin:/usr/bin:/bin" HOME="$HOMES_DIR/root" \
      LANG="${LANG:-C.UTF-8}" TZ="${TZ:-UTC}" INSTALL4J_TEMP="$INSTALLER_TMP" \
      INSTALL4J_JAVA_HOME_OVERRIDE="$JAVA21_HOME" INSTALL4J_JAVA_HOME="$JAVA21_HOME" \
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

print_setup_command() {
  note "  docker run -it --rm --name fishbowl --stop-timeout 180 \\"
  note "    -p 2456:2456 -p 127.0.0.1:6080:6080 \\"
  note "    -v $(volume_name_for "$MYSQL_DATA" fishbowl-mysql):/var/lib/mysql \\"
  note "    -v $(volume_name_for "$FB_HOME" fishbowl-app):/opt/Fishbowl \\"
  note "    -v $(volume_name_for "$DATA_DIR" fishbowl-data):/var/lib/fishbowl \\"
  note "    ${FISHBOWL_IMAGE:-fishbowl}"
  note ""
  note "or, with this repository's compose.yaml:"
  note "  docker compose run --rm --service-ports fishbowl"
  note ""
  note "(If your image has another name, use it in place of ${FISHBOWL_IMAGE:-fishbowl}.)"
}

# ---------------------------------------------------------------- EULA ------
# Shows the license text the installer shows, then requires a typed "yes".
# Returns 0 only on an explicit yes. Anything else, EOF or timeout: returns 1.
eula_accept() {
  local version="$1" answer=""
  hr
  note "FISHBOWL LICENSE AGREEMENT (Fishbowl $FISHBOWL_APP_VERSION)"
  note ""
  note "Before anything is installed you need to read and accept Fishbowl's"
  note "license agreement. This is the same text Fishbowl's installer displays."
  note "It opens in a pager: Space or PgDn scrolls, q closes it."
  note ""
  local enter=""
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
  [ "$answer" = "yes" ] || return 1
  mkdir -p "$STATE_DIR/eula"
  {
    printf 'accepted_at=%s\n' "$(_ts)"
    printf 'fishbowl_version=%s\n' "$version"
    printf 'eula_file=%s\n' "$(basename "$FISHBOWL_EULA")"
    printf 'eula_sha256=%s\n' "$(sha256sum "$FISHBOWL_EULA" | cut -d' ' -f1)"
    printf 'method=typed "yes" at an interactive terminal\n'
  } > "$STATE_DIR/eula/accepted-$version"
  return 0
}
