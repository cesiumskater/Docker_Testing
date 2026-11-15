# shellcheck shell=bash
# shellcheck disable=SC2034  # SETUP_* and UPG_PW are read by functions in setup.sh / the callers
# Upgrade an existing installation to the installer bundled in this image.
# Sourced by fishbowl-entrypoint (common.sh and setup.sh are already loaded).

UPG_PW=""

upgrade_cleanup() { UPG_PW=""; }

# backup_databases <password-var-name> <label>  -> prints the backup path
# Logical backup of every database (mysqldump, consistent snapshot), gzipped,
# owner-only, into the data volume.
backup_databases() {
  local pwvar="$1" label="$2" out need avail
  mkdir -p "$BACKUP_DIR"; chmod 0700 "$BACKUP_DIR"
  out="$BACKUP_DIR/${label}-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
  need="$(mysql_root "$pwvar" -N -B -e 'SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables')" ||
    fail 1 "Could not query MySQL to size the backup."
  avail="$(df -P -B1 "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
  if [ "${avail:-0}" -lt "${need:-0}" ]; then
    fail 1 "Not enough free space for a backup in $BACKUP_DIR (need up to $((need/1048576)) MiB, have $((avail/1048576)) MiB)."
  fi
  log "Backing up all MySQL databases to $out" >&2
  ( umask 077
    MYSQL_PWD="${!pwvar}" mysqldump --protocol=tcp -h 127.0.0.1 -P 3306 -u root \
      --all-databases --single-transaction --routines --events --triggers \
      --hex-blob --flush-privileges --set-gtid-purged=OFF --max-allowed-packet=1G | gzip -6 > "$out.part"
  ) || { rm -f "$out.part"; fail 1 "mysqldump failed; no backup was written and nothing was changed."; }
  if ! gzip -dc "$out.part" | tail -n 1 | grep -q '^-- Dump completed'; then
    rm -f "$out.part"
    fail 1 "The backup file is incomplete (no '-- Dump completed' trailer); nothing was changed."
  fi
  mv -f "$out.part" "$out"
  chmod 0600 "$out"
  printf '%s\n' "$out"
}

ask_root_password_until_valid() {  # sets UPG_PW; MySQL must be running
  local _attempt
  for _attempt in 1 2 3; do
    ask_secret UPG_PW "MySQL root password: " || return 2
    if mysql_root UPG_PW -N -B -e 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    note "MySQL rejected that password."
  done
  return 1
}

print_upgrade_command() {
  note "  docker run -it --rm --name fishbowl --stop-timeout 180 \\"
  note "    -p 2456:2456 -p 127.0.0.1:6080:6080 \\"
  note "    -v $(volume_name_for "$MYSQL_DATA" fishbowl-mysql):/var/lib/mysql \\"
  note "    -v $(volume_name_for "$FB_HOME" fishbowl-app):/opt/Fishbowl \\"
  note "    -v $(volume_name_for "$DATA_DIR" fishbowl-data):/var/lib/fishbowl \\"
  note "    ${FISHBOWL_IMAGE:-fishbowl}"
  note ""
  note "or, with Docker Compose (stop the running service first):"
  note "  docker compose run --rm --service-ports fishbowl"
}

run_upgrade() {
  local from="$1" to="$FISHBOWL_VERSION" rc=0
  hr
  note " Fishbowl upgrade: $from  ->  $to"
  hr
  note "This image carries Fishbowl $FISHBOWL_APP_VERSION (installer $to). Your volumes have $from."
  note "To upgrade: accept the license agreement for $to, then enter the MySQL root"
  note "password so the database can be backed up first. After that it runs on its own:"
  note "backup, then Fishbowl's installer updates /opt/Fishbowl in place. Your company"
  note "name, license key and data are kept, and MySQL is not re-initialized."
  note ""

  eula_accept "$to" || rc=$?
  if [ "$rc" = 2 ]; then
    note ""; note "No answer came from the terminal; nothing was changed."
    exit 3
  elif [ "$rc" != 0 ]; then
    note ""
    note "You did not accept the license agreement for $to, so nothing was upgraded or"
    note "changed. Fishbowl $from and its data are untouched. To keep running $from,"
    note "use the image $(image_with_tag "$from") instead of this one."
    exit 1
  fi
  note "License agreement for $to accepted."
  note ""

  apply_fishbowl_mycnf   # Fishbowl's max_allowed_packet etc. for mysqld and mysqldump
  mysql_start
  hr
  note "MySQL root password (the one chosen at first setup), for the pre-upgrade backup."
  rc=0; ask_root_password_until_valid || rc=$?
  if [ "$rc" != 0 ]; then
    note "Without the MySQL root password the backup can't run, so nothing was upgraded."
    exit "$([ "$rc" = 2 ] && echo 3 || echo 1)"
  fi
  note ""
  note "Upgrading now. No more questions."

  set_status upgrading
  write_state upgrade.in-progress "$(_ts) $from -> $to"
  local backup
  backup="$(backup_databases UPG_PW "pre-upgrade-${from}-to-${to}")"

  # Fishbowl's own settings files too (they hold the database connection and license).
  local cfg
  cfg="$BACKUP_DIR/pre-upgrade-${from}-to-${to}-config-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  (
    cd "$FB_HOME"
    shopt -s nullglob
    files=()
    for f in server/bin/eve.properties server/bin/dbsettings.properties \
             server/bin/*.vmoptions client/bin/*.vmoptions client/bin/client.properties; do
      [ -e "$f" ] && files+=("$f")
    done
    umask 077
    tar -czf "$cfg" -- "${files[@]}"
  ) || fail 1 "Could not save Fishbowl's settings files; nothing was changed."
  log "Saved Fishbowl's settings files to $cfg"

  # Same answers as the original install, read from Fishbowl's own settings.
  local name key secrets
  name="$(eve_get registerName || true)"
  key="$(eve_get licenseKey || true)"
  if installed_is_trial; then
    SETUP_TRIAL=1; SETUP_COMPANY=""; SETUP_KEY=""
    log "Installed copy is a trial; the upgrade keeps it a trial (FISHBOWL_ALLOW_TRIAL_UPGRADE=1)"
  else
    SETUP_TRIAL=0; SETUP_COMPANY="$name"; SETUP_KEY="$key"
    log "Keeping company name and license key from the installed copy"
  fi
  name=""; key=""

  secrets="$(secret_dir)"
  SETUP_SECRETS="$secrets"
  cp -p "$FB_EVE" "$secrets/eve.properties.before"
  [ -f "$FB_BIN/dbsettings.properties" ] && cp -p "$FB_BIN/dbsettings.properties" "$secrets/dbsettings.properties.before"
  write_varfile "$secrets/response.varfile" "$SETUP_TRIAL"
  save_memory_settings "$secrets/vmoptions"
  seed_memory_settings

  local logfile
  logfile="$LOG_DIR/upgrade-${from}-to-${to}-$(date -u +%Y%m%dT%H%M%SZ).log"
  log "Running Fishbowl's $to installer over the existing install (unattended)"
  rc=0; run_installer "$secrets/response.varfile" "$logfile" || rc=$?
  rm -f "$secrets/response.varfile"
  [ "$rc" = 0 ] || fail 1 "The Fishbowl installer exited with status $rc during the upgrade. Output: $logfile. Your database backup: $backup. Start the container again to retry the upgrade."

  # The database connection must survive the update; put it back if the installer reset it.
  if [ -z "$(eve_get dbName || true)" ] && props_get "$secrets/eve.properties.before" dbName >/dev/null 2>&1; then
    warn "The installer reset eve.properties; restoring the database connection settings from before the upgrade."
    cp -p "$secrets/eve.properties.before" "$FB_EVE"
    [ -f "$secrets/dbsettings.properties.before" ] && cp -p "$secrets/dbsettings.properties.before" "$FB_BIN/dbsettings.properties"
  fi

  restore_memory_settings "$secrets/vmoptions"
  log "Memory kept as before the upgrade: server $(xmx_of "$FB_BIN/Fishbowl Server Service.vmoptions"), client $(xmx_of "$FB_HOME/client/bin/Fishbowl Client.vmoptions")"
  fix_ownership
  apply_fishbowl_mycnf
  mysql_stop
  mysql_start
  mysql_stop

  write_state installed-version "$to"
  write_state installed-app-version "$FISHBOWL_APP_VERSION"
  write_state install-type "$([ "$SETUP_TRIAL" = 1 ] && echo trial || echo licensed)"
  rm -f "$STATE_DIR/upgrade.in-progress"
  setup_cleanup
  upgrade_cleanup
  log "Upgrade to Fishbowl $FISHBOWL_APP_VERSION finished. Backup kept at $backup"
}
