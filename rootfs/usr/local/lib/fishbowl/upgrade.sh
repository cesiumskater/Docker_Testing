# shellcheck shell=bash
# shellcheck disable=SC2034  # SETUP_* and UPG_PW are read by functions in setup.sh / the callers
# Upgrade an existing installation to the installer bundled in this image.
# Sourced by fishbowl-entrypoint, fishbowl-upgrade and fishbowl-backup
# (common.sh and setup.sh are already loaded).
#
# An upgrade never starts on its own. A newer image keeps running the Fishbowl
# version that is installed until someone accepts the new version's license
# agreement, on the Fishbowl page or with `fishbowl-upgrade` at a terminal. Only an
# installation made by an earlier version of this image, which asked for its own
# MySQL root password, has to give that password too (for the backup).

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
    MYSQL_PWD="${!pwvar}" mysqldump --protocol=tcp -h "$DB_HOST" -P 3306 -u root \
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
  # New installations use the image's own password, so try that before asking.
  UPG_PW="$(default_root_password)"
  if mysql_root UPG_PW -N -B -e 'SELECT 1' >/dev/null 2>&1; then
    return 0
  fi
  note "This installation was set up with a MySQL root password of its own (an earlier"
  note "version of this image asked for one). Type that password."
  for _attempt in 1 2 3; do
    ask_secret UPG_PW "MySQL root password: " || return 2
    if mysql_root UPG_PW -N -B -e 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    note "MySQL rejected that password."
  done
  return 1
}

# Seen with 26.9.1 -> 26.10: Fishbowl Server refuses to update a trial's database
# ("Trial accounts do not have access to update the database") and never opens its
# port. Every Fishbowl release so far has moved the database version, so a trial is
# not offered the upgrade unless FISHBOWL_ALLOW_TRIAL_UPGRADE=1 says the new version
# leaves the database alone. The installed version keeps running.
trial_upgrade_text() {  # trial_upgrade_text <installed-version>
  local inst="$1"
  note "This image carries Fishbowl $FISHBOWL_VERSION, but Fishbowl $inst in your volumes is a"
  note "trial installation, so it is not upgraded: Fishbowl Server doesn't update a"
  note "trial's database to a new version (it stops with \"Trial accounts do not have"
  note "access to update the database\"). Fishbowl $inst keeps running, and nothing was changed."
  note ""
  note "What you can do:"
  note "  - Licensed now? Enter your purchased license in Server Administration"
  note "    (License tab), then restart the container: the upgrade is offered then."
  note "  - Try $FISHBOWL_VERSION as a new trial on new, empty volumes (the old trial's"
  note "    data stays in the old volumes)."
  note "  - Keep things as they are: the image $(image_with_tag "$inst") matches what is installed."
}

upgrade_offer_text() {  # upgrade_offer_text <installed-version>
  note "This image carries Fishbowl $FISHBOWL_VERSION; your volumes have $1, which keeps"
  note "running. Upgrading needs you: accept the license agreement for $FISHBOWL_VERSION (the"
  note "database is backed up first). Do that on the Fishbowl page, or run:"
  note "  docker exec -it <container> fishbowl-upgrade"
}

upgrade_interrupted_text() {  # upgrade_interrupted_text <installed-version>
  note "An upgrade from Fishbowl $1 to $FISHBOWL_VERSION started earlier and did not finish, so"
  note "Fishbowl Server is not started (its program files may be half-updated). Run the"
  note "upgrade again on the Fishbowl page, or with:"
  note "  docker exec -it <container> fishbowl-upgrade"
  note "The database backup from the first attempt is in $BACKUP_DIR."
}

# The unattended part. Needs MySQL running and UPG_PW holding the root password;
# the license agreement has been accepted and recorded by the caller. Until the
# installer starts, a failure changes nothing (no upgrade.in-progress marker).
perform_upgrade() {  # perform_upgrade <installed-version>
  local from="$1" to="$FISHBOWL_VERSION" rc=0
  set_status upgrading
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
  # From here on /opt/Fishbowl is being changed: an interruption must be finished
  # (by running the upgrade again) before Fishbowl Server may start.
  write_state upgrade.in-progress "$(_ts) $from -> $to"
  log "Running Fishbowl's $to installer over the existing install (unattended)"
  rc=0; run_installer "$secrets/response.varfile" "$logfile" || rc=$?
  rm -f "$secrets/response.varfile"
  [ "$rc" = 0 ] || fail 1 "The Fishbowl installer exited with status $rc during the upgrade. Output: $logfile. Your database backup: $backup. Run the upgrade again (Fishbowl page, or fishbowl-upgrade); Fishbowl Server stays stopped until it finishes."

  # The database connection must survive the update; put it back if the installer reset it.
  if [ -z "$(eve_get dbName || true)" ] && props_get "$secrets/eve.properties.before" dbName >/dev/null 2>&1; then
    warn "The installer reset eve.properties; restoring the database connection settings from before the upgrade."
    cp -p "$secrets/eve.properties.before" "$FB_EVE"
    [ -f "$secrets/dbsettings.properties.before" ] && cp -p "$secrets/dbsettings.properties.before" "$FB_BIN/dbsettings.properties"
  fi

  restore_memory_settings "$secrets/vmoptions"
  log "Memory kept as before the upgrade: server $(xmx_of "$FB_BIN/Fishbowl Server Service.vmoptions"), client $(xmx_of "$FB_HOME/client/bin/Fishbowl Client.vmoptions")"
  fix_ownership

  write_state installed-version "$to"
  write_state installed-app-version "$FISHBOWL_APP_VERSION"
  write_state install-type "$([ "$SETUP_TRIAL" = 1 ] && echo trial || echo licensed)"
  rm -f "$STATE_DIR/upgrade.in-progress"
  setup_cleanup
  upgrade_cleanup
  log "Upgrade to Fishbowl $FISHBOWL_APP_VERSION finished. Backup kept at $backup"
}
