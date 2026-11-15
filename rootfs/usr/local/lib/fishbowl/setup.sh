# shellcheck shell=bash
# First-run setup: four questions, then an unattended install.
# Sourced by fishbowl-entrypoint (common.sh is already loaded).

SETUP_TRIAL=0
SETUP_COMPANY=""
SETUP_KEY=""
SETUP_PW=""
SETUP_SECRETS=""   # /dev/shm directory, removed by setup_cleanup

setup_cleanup() {
  SETUP_KEY=""; SETUP_PW=""
  if [ -n "$SETUP_SECRETS" ] && [ -d "$SETUP_SECRETS" ]; then
    rm -rf -- "$SETUP_SECRETS"
  fi
  SETUP_SECRETS=""
}

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

print_rerun_hint() {
  note ""
  note "Nothing was installed. When you're ready, run setup again at a terminal:"
  note ""
  print_setup_command
}

# ------------------------------------------------------------------ questions
collect_answers() {
  hr
  note " Fishbowl Advanced $FISHBOWL_APP_VERSION - first-time setup"
  hr
  note "Setup asks four things, then installs on its own:"
  note "  1. Accept Fishbowl's license agreement"
  note "  2. Your Fishbowl license key, or the 14 Day Trial"
  note "  3. Your company name (licensed installs only; trials register as \"Trial\")"
  note "  4. A password for MySQL's root user"
  note ""
  note "Set automatically: Server with Client install in /opt/Fishbowl, MySQL 8.4 on"
  note "localhost:3306, server memory ${SERVER_MEMORY_MB} MB, client memory ${CLIENT_MEMORY_MB} MB."
  note ""

  # 1. EULA -------------------------------------------------------------------
  local rc=0
  eula_accept "$FISHBOWL_VERSION" || rc=$?
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
    if [ "${#key}" -lt 5 ] || [[ "$key" =~ [^[:graph:]] ]]; then
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
    local name=""
    while :; do
      ask name "Company name: " || { print_rerun_hint; exit 3; }
      name="$(printf '%s' "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [ -z "$name" ]; then note "The company name can't be empty."; continue; fi
      if [[ "$name" =~ [[:cntrl:]] ]]; then note "The name contains control characters; type it again."; continue; fi
      if [ "${#name}" -gt 200 ]; then note "That's longer than 200 characters; type it again."; continue; fi
      break
    done
    SETUP_COMPANY="$name"
    note ""
  fi

  # 4. MySQL root password -----------------------------------------------------
  hr
  note "MySQL root password"
  note "Fishbowl's database runs in MySQL inside this container. Choose a password for"
  note "MySQL's root user; you'll type it again when you create the Fishbowl database in"
  note "Server Administration, and when upgrading. It isn't stored anywhere in plain text."
  note "Rules (MySQL MEDIUM policy): at least 8 characters, upper- and lower-case"
  note "letters, a digit, and a special character."
  local pw1="" pw2="" problems=""
  while :; do
    ask_secret pw1 "MySQL root password: " || { print_rerun_hint; exit 3; }
    problems="$(password_problems "$pw1")"
    if [ -n "$problems" ]; then
      note "That password is missing: ${problems//;/, }. Try again."
      continue
    fi
    ask_secret pw2 "Type it again: " || { print_rerun_hint; exit 3; }
    if [ "$pw1" != "$pw2" ]; then
      note "The two entries don't match. Try again."
      continue
    fi
    break
  done
  SETUP_PW="$pw1"; pw1=""; pw2=""

  note ""
  hr
  note "Ready to install. No more questions from here."
  if [ "$SETUP_TRIAL" = 1 ]; then
    note "  License:       14 Day Fishbowl Trial"
  else
    note "  License:       key ending in ...${SETUP_KEY: -4}"
    note "  Company name:  $SETUP_COMPANY"
  fi
  note "  MySQL root:    password set (not shown)"
  hr
}

# -------------------------------------------------------------- automation --
mysql_initialize() {
  log "Initializing MySQL 8.4 with lower_case_table_names=1 already configured"
  mysql_prepare_dirs
  touch "$LOG_DIR/mysqld.log"; chown mysql:mysql "$LOG_DIR/mysqld.log"
  if ! mysqld --initialize-insecure --user=mysql --log-error="$LOG_DIR/mysqld.log" >/dev/null 2>&1; then
    tail -n 20 "$LOG_DIR/mysqld.log" >&2 || true
    fail 1 "MySQL could not initialize its data directory (messages above)."
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
    fail 1 "Could not log in to MySQL over TCP (127.0.0.1:3306) as root with the new password."
  IFS=$'\t' read -r version lctn mode <<<"$out"
  log "MySQL reports version $version, lower_case_table_names=$lctn, sql_mode=$mode"
  [[ "$version" == 8.4.* ]] || fail 1 "MySQL reports version $version; Fishbowl needs 8.4.x. Stopping before the Fishbowl installer runs."
  [ "$lctn" = 1 ] || fail 1 "MySQL reports lower_case_table_names=$lctn, but Fishbowl needs 1, and it can only be set when the data directory is created. Stopping before the Fishbowl installer runs. Start the container again: setup will wipe this unfinished MySQL data directory and start over."
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
# it is only ever written after the person typed "yes" above.
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

perform_install() {
  local logfile
  logfile="$LOG_DIR/setup-$(date -u +%Y%m%dT%H%M%SZ).log"
  set_status setup
  write_state setup.in-progress "$(_ts) $FISHBOWL_VERSION"

  SETUP_SECRETS="$(secret_dir)"
  mysql_initialize
  mysql_start
  log "MySQL is up; setting the root password you chose"
  mysql_set_root_password
  mysql_verify
  log "Securing MySQL (no anonymous users, no remote root, no test database)"
  mysql_secure

  log "Installing Fishbowl $FISHBOWL_APP_VERSION unattended (Server with Client, $FB_HOME); about a minute"
  seed_memory_settings
  write_varfile "$SETUP_SECRETS/response.varfile" "$SETUP_TRIAL"
  local rc=0
  run_installer "$SETUP_SECRETS/response.varfile" "$logfile" || rc=$?
  rm -f "$SETUP_SECRETS/response.varfile"
  [ "$rc" = 0 ] || fail 1 "The Fishbowl installer exited with status $rc. Its output is in $logfile (no secrets in it). Start the container again to retry setup from scratch."
  [ -f "$FB_EVE" ] && [ -x "$FB_SERVICE_LAUNCHER" ] ||
    fail 1 "The installer finished but $FB_EVE or the server launcher is missing. See $logfile."

  log "Post-install (guide Section 8): ownership, Fishbowl's my.cnf, MySQL restart"
  set_auto_updates_default
  fix_ownership
  apply_fishbowl_mycnf
  mysql_stop
  mysql_start
  mysql_verify
  mysql_stop

  verify_memory_settings ||
    fail 1 "Fishbowl's memory settings did not come out as ${SERVER_MEMORY_MB} MB server / ${CLIENT_MEMORY_MB} MB client (details above)."
  log "Memory settings verified: server -Xmx${SERVER_MEMORY_MB}M, client -Xmx${CLIENT_MEMORY_MB}M"

  write_state installed-version "$FISHBOWL_VERSION"
  write_state installed-app-version "$FISHBOWL_APP_VERSION"
  write_state install-type "$([ "$SETUP_TRIAL" = 1 ] && echo trial || echo licensed)"
  write_state setup.complete "$(_ts) Fishbowl $FISHBOWL_VERSION"
  rm -f "$STATE_DIR/setup.in-progress"
  setup_cleanup
  log "Fishbowl $FISHBOWL_APP_VERSION is installed."
}

run_first_setup() {   # the entrypoint's EXIT trap calls setup_cleanup and stops MySQL
  collect_answers
  perform_install
}
