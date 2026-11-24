# shellcheck shell=bash
# shellcheck disable=SC2034  # ANSWER_METHOD and UPG_PW are read by the scripts that source this file
# First-time setup: the questions, the answers file, and the unattended install.
# Sourced by fishbowl-entrypoint and fishbowl-setup (common.sh is already loaded).
#
# The questions are asked in one of two places: the setup form on the Fishbowl
# page, or `fishbowl-setup` at a terminal. Either way the answers reach the
# entrypoint as a small file in RAM (see write_answers / read_answers), and the
# same perform_install runs.

SETUP_TRIAL=0
SETUP_COMPANY=""
SETUP_KEY=""
SETUP_PW=""
SETUP_SECRETS=""   # /dev/shm directory, removed by setup_cleanup
ANSWER_METHOD=""   # how the license agreement was accepted, for the record kept on the data volume

setup_cleanup() {
  SETUP_KEY=""; SETUP_PW=""
  if [ -n "$SETUP_SECRETS" ] && [ -d "$SETUP_SECRETS" ]; then
    rm -rf -- "$SETUP_SECRETS"
  fi
  SETUP_SECRETS=""
}

# ---------------------------------------------------------------- the rules --
# MySQL 8.4 MEDIUM policy: length >= 8, upper and lower case, a digit, a special character.
password_problems() {
  local p="$1" missing=()
  [ "${#p}" -ge 8 ] || missing+=("at least 8 characters")
  [[ "$p" =~ [[:upper:]] ]] || missing+=("an upper-case letter")
  [[ "$p" =~ [[:lower:]] ]] || missing+=("a lower-case letter")
  [[ "$p" =~ [0-9] ]] || missing+=("a digit")
  [[ "$p" =~ [^[:alnum:]] ]] || missing+=("a special character (for example ! # % - _ .)")
  if [[ "$p" =~ [[:cntrl:]] ]]; then missing+=("no control characters"); fi
  if [ "${#missing[@]}" -gt 0 ]; then
    local IFS=';'; printf '%s' "${missing[*]}"
  fi
}
key_looks_valid() { [ "${#1}" -ge 5 ] && ! [[ "$1" =~ [^[:graph:]] ]]; }
company_problem() {
  if [ -z "$1" ]; then printf "The company name can't be empty."
  elif [[ "$1" =~ [[:cntrl:]] ]]; then printf 'The company name contains control characters.'
  elif [ "${#1}" -gt 200 ]; then printf 'The company name is longer than 200 characters.'
  fi
}

# ----------------------------------------------------- questions (terminal) --
print_rerun_hint() {
  note ""
  note "Nothing was installed. When you're ready, run fishbowl-setup again, or use"
  note "the setup form on the Fishbowl page."
}

# Asks the four questions at a terminal and leaves the answers in SETUP_*.
# Exits 1 when the license agreement is declined, 3 when nobody answers.
collect_answers() {
  hr
  note " Fishbowl Advanced $FISHBOWL_APP_VERSION - first-time setup"
  hr
  note "Setup asks four things, then installs on its own:"
  note "  1. Accept Fishbowl's license agreement"
  note "  2. Your Fishbowl license key, or the 14 Day Trial"
  note "  3. Your company name (licensed installs only; trials register as \"Trial\")"
  note "  4. The time zone, as a GMT offset (for example GMT +5 or GMT -7)"
  note ""
  note "Set automatically: Server with Client install in /opt/Fishbowl, MySQL 8.4 on"
  note "localhost:3306, server memory ${SERVER_MEMORY_MB} MB, client memory ${CLIENT_MEMORY_MB} MB,"
  note "and MySQL's root password (this image sets it; it is never shown)."
  note ""

  # 1. EULA -------------------------------------------------------------------
  local rc=0
  eula_accept || rc=$?
  if [ "$rc" = 2 ]; then
    note ""
    note "No answer came from the terminal, so setup stopped without accepting anything."
    print_rerun_hint
    exit 3
  elif [ "$rc" != 0 ]; then
    note ""
    note "You did not accept Fishbowl's license agreement (only a typed \"yes\" counts),"
    note "so Fishbowl was not installed and nothing was changed."
    print_rerun_hint
    exit 1
  fi
  note "License agreement accepted."
  note ""

  # 2. License key or trial ---------------------------------------------------
  hr
  note "Fishbowl license"
  note "Paste your Fishbowl License Key. It won't be shown while you type."
  note "No key yet? Type: trial    (starts the 14 Day Fishbowl Trial)"
  local key="" confirm=""
  while :; do
    ask_secret key "License key (or trial): " || { note "No answer; stopping."; print_rerun_hint; exit 3; }
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    if [ "$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" = "trial" ]; then
      SETUP_TRIAL=1; SETUP_KEY=""
      note "Using the 14 Day Fishbowl Trial."
      break
    fi
    if ! key_looks_valid "$key"; then
      note "That doesn't look like a license key. Paste the whole key, or type trial."
      continue
    fi
    ask confirm "The key you entered ends in ...${key: -4}. Is that right? [y/N] " || { print_rerun_hint; exit 3; }
    case "$confirm" in
      [yY]|[yY][eE][sS]) SETUP_TRIAL=0; SETUP_KEY="$key"; break ;;
      *) note "OK, enter it again." ;;
    esac
  done
  key=""
  note ""

  # 3. Company name (licensed installs) ---------------------------------------
  if [ "$SETUP_TRIAL" = 0 ]; then
    hr
    note "Company name, exactly as it appears on your Fishbowl license."
    local name="" problem=""
    while :; do
      ask name "Company name: " || { print_rerun_hint; exit 3; }
      name="$(printf '%s' "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      problem="$(company_problem "$name")"
      if [ -n "$problem" ]; then note "$problem Type it again."; continue; fi
      break
    done
    SETUP_COMPANY="$name"
    note ""
  fi

  # 4. Time zone ----------------------------------------------------------------
  hr
  note "Time zone"
  note "This container is on $(tz_describe "${TZ:-UTC}"). Fishbowl dates orders,"
  note "receipts and reports in its time zone. Type the GMT offset to use, for example"
  note "+5 or -7, or press Enter to keep ${TZ:-UTC}. A GMT offset stays the same all"
  note "year; it doesn't change for daylight saving time."
  local tz="" n="" rc=0
  while :; do
    ask tz "GMT offset (Enter keeps ${TZ:-UTC}): " || { print_rerun_hint; exit 3; }
    if [ -z "$(printf '%s' "$tz" | tr -d '[:space:]')" ]; then
      SETUP_TZ="$(time_zone_kept)"
      break
    fi
    rc=0; n="$(tz_parse_offset "$tz")" || rc=$?
    case "$rc" in
      0) SETUP_TZ="$(tz_offset_name "$n")"; break ;;
      2) n="$(printf '%s' "$tz" | tr -d '[:space:]')"; note "Type it with its sign: +$n or -$n." ;;
      3) note "That's outside GMT -12 to GMT +14. Type it again." ;;
      *) note "Type a whole-hour GMT offset such as +5 or -7, or press Enter to keep ${TZ:-UTC}." ;;
    esac
  done
  note "Time zone: $(tz_describe "$SETUP_TZ")."
  note ""

  # 5. MySQL root password: none to choose. Every new installation uses the
  # password in mysql-root-password.txt (see default_root_password).
  SETUP_PW="$(default_root_password)"

  note ""
  hr
  note "Ready to install. No more questions from here."
  if [ "$SETUP_TRIAL" = 1 ]; then
    note "  License:       14 Day Fishbowl Trial"
  else
    note "  License:       key ending in ...${SETUP_KEY: -4}"
    note "  Company name:  $SETUP_COMPANY"
  fi
  note "  Time zone:     $(tz_describe "$SETUP_TZ")"
  note "  MySQL root:    set by this image (not shown anywhere)"
  hr
}

# The container's own time zone (TZ from docker run -e TZ, or FB_TZ), when setup
# keeps it; UTC when it has none, or none this image knows.
time_zone_kept() {
  if time_zone_valid "${TZ:-}"; then printf '%s\n' "$TZ"; else printf 'UTC\n'; fi
}

# ------------------------------------------------------------ answers file --
# One "name=value" per line; values never contain a line break (checked on both
# sides). The file lives in /dev/shm (RAM) for the moment between the question
# and the install, mode 0600.
#
#   fishbowl-answers 1
#   kind=setup | upgrade
#   via=page | terminal            where the license agreement was accepted
#   eula=accepted
#   eula_sha256=<SHA-256 of the license text that was shown>
#   license=trial | key            (setup)
#   key=...  company=...           (setup with a key)
#   timezone=keep | Etc/GMT[+-]N   (setup; keep, or absent: the container's own TZ)
#   password=<MySQL root password> (upgrade only, and only when the installation has one of
#                                  its own; empty or absent means the image's password)
write_answers() {  # write_answers FILE setup|upgrade   (from SETUP_* / UPG_PW; terminal commands only)
  local f="$1" kind="$2"
  (
    umask 077
    {
      printf 'fishbowl-answers 1\n'
      printf 'kind=%s\n' "$kind"
      printf 'via=terminal\n'
      printf 'eula=accepted\n'
      printf 'eula_sha256=%s\n' "$(eula_sha256)"
      if [ "$kind" = setup ]; then
        if [ "$SETUP_TRIAL" = 1 ]; then
          printf 'license=trial\n'
        else
          printf 'license=key\n'
          printf 'key=%s\n' "$SETUP_KEY"
          printf 'company=%s\n' "$SETUP_COMPANY"
        fi
        printf 'timezone=%s\n' "${SETUP_TZ:-keep}"
      else
        printf 'password=%s\n' "${UPG_PW:-}"
      fi
    } > "$f"
  )
}

# Reads an answers file into SETUP_* (setup) or UPG_PW (upgrade), checking every
# value again: the page's server is a separate, less trusted program. The file is
# removed as soon as it has been read, unless the third argument is "keep".
read_answers() {  # read_answers FILE setup|upgrade [keep]
  local file="$1" kind="$2" keep="${3:-}" line k v first=1 header="" problem
  local a_kind="" a_via="" a_eula="" a_sha="" a_license="" a_key="" a_company="" a_pw="" a_tz=""
  { [ -f "$file" ] && [ ! -L "$file" ]; } || fail 1 "The answers are missing; nothing was changed. Please try again."
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = 1 ]; then
      first=0
      header="$line"
      continue
    fi
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      kind) a_kind="$v" ;;
      via) a_via="$v" ;;
      eula) a_eula="$v" ;;
      eula_sha256) a_sha="$v" ;;
      license) a_license="$v" ;;
      key) a_key="$v" ;;
      company) a_company="$v" ;;
      password) a_pw="$v" ;;
      timezone) a_tz="$v" ;;
    esac
  done < "$file"
  [ "$keep" = keep ] || rm -f -- "$file"

  [ "$header" = "fishbowl-answers 1" ] || fail 1 "The answers arrived in a form this version doesn't understand; nothing was changed."
  [ "$a_kind" = "$kind" ] || fail 1 "These answers are for something else ($a_kind, not $kind); nothing was changed."
  # Only an explicit acceptance of the license text this image carries counts.
  [ "$a_eula" = accepted ] || fail 1 "Fishbowl's license agreement was not accepted, so nothing was changed."
  [ "$a_sha" = "$(eula_sha256)" ] ||
    fail 1 "The license agreement that was accepted is not the one in this image (the page may have been open since before an update). Reload the page, read the agreement shown there, and try again."
  case "$a_via" in
    terminal) ANSWER_METHOD='typed "yes" at a terminal (docker exec)' ;;
    *)        ANSWER_METHOD='ticked "I have read and accept" and submitted the form on the Fishbowl page' ;;
  esac
  if [[ "$a_pw" =~ [[:cntrl:]] ]]; then fail 1 "The MySQL root password contains control characters; nothing was changed."; fi

  if [ "$kind" = upgrade ]; then
    # Empty means "the image's password"; a value is the password an installation
    # from an earlier version of this image was set up with.
    if [ -n "$a_pw" ]; then UPG_PW="$a_pw"; else UPG_PW="$(default_root_password)"; fi
    a_pw=""
    return 0
  fi

  case "$a_license" in
    trial)
      SETUP_TRIAL=1; SETUP_KEY=""; SETUP_COMPANY="" ;;
    key)
      a_key="$(printf '%s' "$a_key" | tr -d '[:space:]')"
      key_looks_valid "$a_key" || fail 1 "That doesn't look like a license key. Nothing was installed."
      a_company="$(printf '%s' "$a_company" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      problem="$(company_problem "$a_company")"
      [ -z "$problem" ] || fail 1 "$problem Nothing was installed."
      SETUP_TRIAL=0; SETUP_KEY="$a_key"; SETUP_COMPANY="$a_company" ;;
    *) fail 1 "Choose a license key or the trial. Nothing was installed." ;;
  esac
  # The time zone: keep the container's own, or a whole-hour GMT offset.
  case "$a_tz" in
    ""|keep) SETUP_TZ="$(time_zone_kept)" ;;
    *)
      [[ "$a_tz" =~ ^Etc/GMT([+-]([1-9]|1[0-4]))?$ ]] && time_zone_valid "$a_tz" ||
        fail 1 "The time zone '$a_tz' isn't one setup offers (GMT -12 to GMT +14). Nothing was installed."
      SETUP_TZ="$a_tz" ;;
  esac
  SETUP_PW="$(default_root_password)"; a_pw=""; a_key=""
}

# -------------------------------------------------------------- automation --
mysql_initialize() {
  log "Initializing MySQL 8.4 with lower_case_table_names=1 already configured"
  mysql_prepare_dirs
  touch "$LOG_DIR/mysqld.log"; chown mysql:mysql "$LOG_DIR/mysqld.log"
  if ! mysqld --initialize-insecure --user=mysql --log-error="$LOG_DIR/mysqld.log" >/dev/null 2>&1; then
    tail -n 20 "$LOG_DIR/mysqld.log" >&2 || true
    fail 1 "MySQL could not initialize its data directory (messages in the container log)."
  fi
}

mysql_set_root_password() {
  # Fresh data directory: root@localhost has no password yet (socket only).
  printf 'ALTER USER %s@%s IDENTIFIED BY %s;\n' "'root'" "'localhost'" "$(sql_quote "$SETUP_PW")" |
    mysql --protocol=socket --socket="$MYSQL_SOCKET" -u root ||
    fail 1 "Setting the MySQL root password failed."
}

# Guide Step 6: version must be 8.4.x and lower_case_table_names must be 1.
mysql_verify() {
  local out version lctn mode
  out="$(mysql_root SETUP_PW -N -B -e 'SELECT VERSION(), @@GLOBAL.lower_case_table_names, @@GLOBAL.sql_mode')" ||
    fail 1 "Could not log in to MySQL over TCP ($DB_HOST:3306) as root with $(db_external && echo "the password in ${FISHBOWL_DB_ROOT_PASSWORD_FILE:-the image}" || echo "the new password")."
  IFS=$'\t' read -r version lctn mode <<<"$out"
  log "MySQL reports version $version, lower_case_table_names=$lctn, sql_mode=$mode"
  [[ "$version" == 8.4.* ]] || fail 1 "MySQL reports version $version; Fishbowl needs 8.4.x. Stopping before the Fishbowl installer runs."
  [ "$lctn" = 1 ] || fail 1 "MySQL reports lower_case_table_names=$lctn, but Fishbowl needs 1, and it can only be set when the data directory is created. Stopping before the Fishbowl installer runs. Trying setup again wipes this unfinished MySQL data directory and starts over."
}

# Guide Step 7.
mysql_secure() {
  mysql_root SETUP_PW <<'SQL' || fail 1 "Securing MySQL (guide Step 7) failed."
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
}

# Fishbowl Server defaults to "Automatically download and apply updates". Here,
# updates come from new images (fresh EULA acceptance and a database backup
# first), so first setup selects "Never notify or update automatically"
# (autoUpdates=4, the value Server Administration writes for that choice).
# Only set when absent: a choice made later in Server Administration -> Server
# -> Auto Updates is never overwritten.
set_auto_updates_default() {
  grep -q '^autoUpdates=' "$FB_EVE" && return 0
  [ -z "$(tail -c 1 "$FB_EVE")" ] || printf '\n' >> "$FB_EVE"
  printf 'autoUpdates=4\n' >> "$FB_EVE"
  log "Fishbowl's own auto-update set to 'Never notify or update automatically' (updates come from new images)"
}

# install4j response file. agreed=0 is "I have read and accept the agreement";
# it is only ever written after the person accepted the agreement themselves.
# shellcheck disable=SC2016  # "$Integer" / "$Boolean" are literal install4j type suffixes
write_varfile() {  # write_varfile <path> <trial 0|1> ; company/key come from SETUP_* vars
  local f="$1" trial="$2"
  {
    printf '# Generated by fishbowl-docker for one unattended run; deleted afterwards.\n'
    printf 'agreed$Integer=0\n'
    printf 'installMode$Integer=%s\n' "$([ "$trial" = 1 ] && echo 0 || echo 1)"
    printf 'clientMode$Integer=1\n'
    printf 'mySqlPath=/usr/bin\n'
    printf 'installMysql$Boolean=false\n'
    printf 'iconsDesktop$Boolean=false\n'
    printf 'loginServer$Boolean=false\n'
    printf 'loginClient$Boolean=false\n'
    printf 'loginCheckout$Boolean=false\n'
    printf 'sys.installationDir=%s\n' "$FB_HOME"
    printf 'sys.languageId=en\n'
    printf 'sys.component.filesClient$Boolean=true\n'
    printf 'sys.component.filesServer$Boolean=true\n'
    if [ "$trial" != 1 ]; then
      printf 'registerName='; printf '%s' "$SETUP_COMPANY" | props_escape; printf '\n'
      printf 'licenseKey='; printf '%s' "$SETUP_KEY" | props_escape; printf '\n'
    fi
  } > "$f"
  chmod 0600 "$f"
}

# Installs MySQL's data directory and Fishbowl from the answers in SETUP_*.
# Any failure exits (the caller's EXIT trap stops MySQL and clears the secrets);
# trying again starts from a clean slate.
perform_install() {
  local logfile
  logfile="$LOG_DIR/setup-$(date -u +%Y%m%dT%H%M%SZ).log"
  set_status setup
  write_state setup.in-progress "$(_ts) $FISHBOWL_VERSION"

  # The time zone first: MySQL (here, or its time_zone in the database container)
  # and Fishbowl's installer start with it.
  export TZ="$SETUP_TZ"
  log "Time zone: $(tz_describe "$TZ"), as chosen at setup"

  SETUP_SECRETS="$(secret_dir)"
  if db_external; then
    # The database container made its own data directory (root's password from
    # the Compose secret, root only from its data network); it just has to fit.
    mysql_start
    log "Checking the database container ($DB_HOST:3306)"
    mysql_verify
  else
    mysql_initialize
    mysql_start
    log "MySQL is up; setting its root password"
    mysql_set_root_password
    mysql_verify
    log "Securing MySQL (no anonymous users, no remote root, no test database)"
    mysql_secure
  fi

  log "Installing Fishbowl $FISHBOWL_APP_VERSION unattended (Server with Client, $FB_HOME); about a minute"
  seed_memory_settings
  write_varfile "$SETUP_SECRETS/response.varfile" "$SETUP_TRIAL"
  local rc=0
  run_installer "$SETUP_SECRETS/response.varfile" "$logfile" || rc=$?
  rm -f "$SETUP_SECRETS/response.varfile"
  if [ "$rc" != 0 ]; then
    local why=""
    if grep -q "Not enough disk space" "$logfile" 2>/dev/null; then
      why=" Docker is out of disk space: free some (docker system df shows what uses it) and try again."
    fi
    fail 1 "The Fishbowl installer exited with status $rc.$why Its output is in $logfile (no secrets in it)."
  fi
  { [ -f "$FB_EVE" ] && [ -x "$FB_SERVICE_LAUNCHER" ]; } ||
    fail 1 "The installer finished but $FB_EVE or the server launcher is missing. See $logfile."

  log "Post-install (guide Section 8): ownership, Fishbowl's my.cnf, MySQL restart"
  set_auto_updates_default
  fix_ownership
  apply_fishbowl_mycnf
  db_point_fishbowl
  if db_external; then
    mysql_verify   # its restart for Fishbowl's tuning: docker compose restart db (README)
  else
    mysql_stop
    mysql_start
    mysql_verify
    mysql_stop
  fi

  verify_memory_settings ||
    fail 1 "Fishbowl's memory settings did not come out as ${SERVER_MEMORY_MB} MB server / ${CLIENT_MEMORY_MB} MB client (details in the container log)."
  log "Memory settings verified: server -Xmx${SERVER_MEMORY_MB}M, client -Xmx${CLIENT_MEMORY_MB}M"

  write_state installed-version "$FISHBOWL_VERSION"
  write_state installed-app-version "$FISHBOWL_APP_VERSION"
  write_state install-type "$([ "$SETUP_TRIAL" = 1 ] && echo trial || echo licensed)"
  write_state mysql-root-password image   # the image's password (no secret in this file)
  write_state timezone "$SETUP_TZ"        # applied at every start (apply_time_zone)
  write_state setup.complete "$(_ts) Fishbowl $FISHBOWL_VERSION"
  rm -f "$STATE_DIR/setup.in-progress"
  setup_cleanup
  log "Fishbowl $FISHBOWL_APP_VERSION is installed."
}
