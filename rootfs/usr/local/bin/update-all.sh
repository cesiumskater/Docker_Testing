#!/usr/bin/env bash
#
# update-all.sh (container edition)
#
# Brings the system inside a Fishbowl image up to date: the OS packages, MySQL
# 8.4, Java 21 (Eclipse Temurin), the VNC and browser-window pieces. The single
# container is Fedora (dnf); the Compose stack's images are UBI 9 (microdnf:
# server, page) and AlmaLinux 9 (dnf: desktop), and each checks its own part
# afterwards (FISHBOWL_VERIFY_PART, see verify-runtime.sh). Three ways it runs:
#
#   update-all.sh --build        in the Dockerfile, so every image build (the
#                                weekly maintenance rebuild included) ships with
#                                every update published so far. Fails the build
#                                if a repository can't be read or a check fails.
#   update-all.sh --at-start     by the container, in the background, at every
#                                start. On a read-only root filesystem (the
#                                hardened setup) packages can't change, so it
#                                only reports how old the image's packages are.
#   docker exec fishbowl update-all.sh     by hand, on a writable container.
#
# What it never does:
#   * restart the container, MySQL, Fishbowl Server or anything else, or ask you
#     to. Files on disk change; programs that are already running keep using the
#     old ones, and the new ones are used the next time the container starts.
#   * ask a question (no prompts anywhere; dnf runs with -y and no input).
#   * upgrade Fishbowl itself. That needs someone to accept the new version's
#     license agreement, so it stays on the Fishbowl page (or fishbowl-upgrade).
#   * move MySQL off 8.4 or Java off 21 (Fishbowl Server rejects anything else):
#     an update to either is skipped if it would.
#
# Modeled on the host script this came from. The host-only sections (firmware,
# flatpak, snap, toolbox, distrobox, nix, brew, pip, npm, cargo, gem, podman,
# docker images) are left out because none of those exist in the container, and
# so are `dnf autoremove` (it could remove something the image needs) and the
# reboot reminder (a container has no reboot to ask for).
#
# Environment:
#   FISHBOWL_UPDATE_TIMEOUT   seconds before dnf is given up on (default 1800)
#
# Exit status: 0 = updated or nothing to do, 1 = could not update (offline, a
# repository down; nothing is broken, it tries again next start), 2 = updated
# but the runtime check failed (see the log). With --build, anything but 0
# stops the image build.

set -uo pipefail
# NOTE: intentionally NOT using -e. One failed step shouldn't skip the steps
# after it; each section handles its own errors.

LIB=/usr/local/lib/fishbowl
AT_START=0
BUILD=0
case "${1:-}" in
    --at-start) AT_START=1 ;;
    --build)    BUILD=1 ;;
    "")         ;;
    *) echo "Usage: update-all.sh [--build | --at-start]" >&2; exit 2 ;;
esac

# common.sh turns on errexit for the scripts that source it; this one doesn't want it.
if [ -r "$LIB/common.sh" ]; then
    # shellcheck source=/dev/null
    . "$LIB/common.sh"
    set +o errexit
else
    log() { printf '%s [update] %s\n' "$(date -u +%FT%TZ)" "$*"; }
    warn() { log "[warning] $*"; }
    RUN_DIR=/run/fishbowl
    LOG_DIR=/var/lib/fishbowl/logs
fi

section() {
    echo ""
    echo "========================================"
    echo ">> $1"
    echo "========================================"
}

have() {
    command -v "$1" >/dev/null 2>&1
}

TIMEOUT_SECS="${FISHBOWL_UPDATE_TIMEOUT:-1800}"
VERIFY="${FISHBOWL_UPDATE_VERIFY:-$LIB/verify-runtime.sh}"
LOCK="${UPDATE_LOCK:-$RUN_DIR/update.lock}"
PKG_BEFORE="" PKG_AFTER=""
trap 'rm -f "$PKG_BEFORE" "$PKG_AFTER"' EXIT

# ---------------------------------------------------------------------------
# Started by the container at every start: wait until MySQL and Fishbowl Server
# have had their turn, take the lock that keeps a first-time setup or an
# upgrade from running at the same time, and write to a log file instead of the
# container's log.
# ---------------------------------------------------------------------------
# A read-only root filesystem: is / mounted ro?
root_read_only() {
    awk '$2 == "/" { print $4 }' /proc/mounts 2>/dev/null | tr ',' '\n' | grep -qx ro
}

if [ "$AT_START" = 1 ]; then
    if [ "${FISHBOWL_AUTO_UPDATE:-1}" = 0 ]; then
        exit 0
    fi
    # Hardened (read-only) containers get their updates from rebuilds: the weekly
    # maintenance, or any build. The container log already says how old this
    # image is when that matters (image_age_check in the entrypoint).
    if root_read_only; then
        exit 0
    fi
    trap 'exit 0' TERM            # still waiting: stopping the container ends this at once
    sleep "${FISHBOWL_UPDATE_DELAY:-90}" &
    wait $!
    mkdir -p "$RUN_DIR" "$LOG_DIR"
    exec 7>"$LOCK"
    # A setup or an upgrade that is running goes first. Wait in short turns, so a
    # stop request is noticed (bash runs a trap only between commands).
    until flock -w 5 7; do :; done
    LOGFILE="$LOG_DIR/update-$(date -u +%Y%m%dT%H%M%SZ).log"
    exec 3>&1 4>&2                # the container's own log, for the one line at the end
    exec >"$LOGFILE" 2>&1
    # From here on a stop request waits for dnf to finish its current step
    # (bash runs this after the running command ends), so a package is never
    # cut off half-way.
    trap ':' TERM
fi

if [ "$AT_START" = 0 ] && [ "$BUILD" = 0 ] && root_read_only; then
    echo "This container's root filesystem is read-only, so packages can't change in it."
    echo "Updates come from rebuilding the image: the weekly maintenance does that"
    echo "(tools/fishbowl-maintain.sh or .ps1, README section 12), or rebuild by hand."
    exit 1
fi

# The same check the image build runs, for this image's part of Fishbowl
# (FISHBOWL_VERIFY_PART: all for the single container, or server, page, desktop).
# Run with bash: a file uploaded through GitHub's web page loses its executable bit.
run_verify() {
    { [ "$CHANGED" -gt 0 ] || [ "$BUILD" = 1 ]; } || return 0
    [ -f "$VERIFY" ] || return 0
    echo ""
    echo "Runtime check after the update:"
    if ! bash "$VERIFY" "${FISHBOWL_VERIFY_PART:-all}"; then
        RESULT="packages were updated but the runtime check FAILED; recreate the container from the image (docker rm, then docker run) to get back to the tested versions"
        STATUS=2
    fi
}

echo "Update run started: $(date)"
RESULT="nothing to update"
STATUS=0

# ---------------------------------------------------------------------------
# 1. DNF / RPM
# ---------------------------------------------------------------------------
section "DNF system update"
if have dnf; then
    # A container start shrugs off a mirror that's down (it tries again next
    # start); an image build doesn't: an image must never ship quietly unpatched.
    SKIP_UNAVAILABLE=True
    [ "$BUILD" = 1 ] && SKIP_UNAVAILABLE=False
    DNF=(dnf -y --setopt=install_weak_deps=False --setopt=skip_if_unavailable="$SKIP_UNAVAILABLE"
         --setopt=timeout=30 --setopt=retries=2)
    # Eclipse Temurin (Java 21) comes from Adoptium's repository, which is
    # installed switched off; turn it on for this run so Java gets its fixes too.
    if [ -f /etc/yum.repos.d/adoptium-temurin-java-repository.repo ]; then
        DNF+=(--enablerepo=adoptium-temurin-java-repository)
    fi
    RUNNER=(timeout "$TIMEOUT_SECS")
    have nice && RUNNER=(nice -n 19 "${RUNNER[@]}")
    have ionice && RUNNER=(ionice -c3 "${RUNNER[@]}")

    # Look first. Fishbowl Server needs MySQL 8.4.x and Java 21, so an update
    # that would change either one's major version is left out (everything else
    # still updates). Fedora keeps MySQL 8.4 and Temurin 21 on those versions,
    # so in practice this stays quiet.
    EXCLUDES=()
    CANDIDATES="$("${DNF[@]}" -q repoquery --upgrades --latest-limit=1 --queryformat '%{name} %{version}\n')"
    REPO_RC=$?
    if [ "$REPO_RC" != 0 ]; then
        echo "Could not read the package repositories (offline, or a mirror is down)."
        echo "Nothing was changed; the next container start tries again."
        RESULT="could not reach the package repositories"
        STATUS=1
    else
        while read -r name version; do
            [ -n "${name:-}" ] || continue
            case "$name" in
                mysql|mysql-*|community-mysql*)
                    if [[ "$version" != 8.4.* ]]; then EXCLUDES+=("--exclude=mysql*" "--exclude=community-mysql*"); echo "Skipping MySQL packages: $name $version is not 8.4.x"; fi ;;
                temurin-*)
                    if [[ "$version" != 21.* ]]; then EXCLUDES+=("--exclude=temurin-*"); echo "Skipping Java packages: $name $version is not Java 21"; fi ;;
            esac
        done <<<"$CANDIDATES"

        PKG_BEFORE="$(mktemp)"; PKG_AFTER="$(mktemp)"
        rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > "$PKG_BEFORE"
        "${RUNNER[@]}" "${DNF[@]}" "${EXCLUDES[@]}" upgrade --refresh </dev/null
        DNF_RC=$?
        rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > "$PKG_AFTER"
        CHANGED="$(comm -13 "$PKG_BEFORE" "$PKG_AFTER" | wc -l)"
        if [ "$DNF_RC" != 0 ]; then
            echo "dnf finished with status $DNF_RC."
            RESULT="dnf failed (status $DNF_RC), $CHANGED package(s) changed before it stopped"
            STATUS=1
        elif [ "$CHANGED" -gt 0 ]; then
            RESULT="$CHANGED package(s) updated; they are used the next time the container starts"
        fi
        if [ "$CHANGED" -gt 0 ]; then
            echo "Updated packages:"
            comm -13 "$PKG_BEFORE" "$PKG_AFTER" | sed 's/^/  /'
        fi
        # Keep the cache out of the container's disk.
        dnf clean all >/dev/null 2>&1 || true

        # A newer MySQL package puts back the file capability the image removes
        # (mysqld then refuses to start under Docker's default capabilities).
        if { [ "$CHANGED" -gt 0 ] || [ "$BUILD" = 1 ]; } && [ -e /usr/libexec/mysqld ] && have setcap; then
            setcap -r /usr/libexec/mysqld 2>/dev/null || true
        fi
        run_verify
    fi
elif have microdnf; then
    # The Compose stack's UBI 9 images (server, page) have microdnf instead of dnf.
    # Java there is the temurin-21-jre package, which never moves off Java 21, and
    # MySQL isn't a package at all (its client tools come from the MySQL image),
    # so there's nothing to hold back. A repository that can't be read fails the
    # update, so a build stops instead of shipping unpatched.
    RUNNER=(timeout "$TIMEOUT_SECS")
    have nice && RUNNER=(nice -n 19 "${RUNNER[@]}")
    PKG_BEFORE="$(mktemp)"; PKG_AFTER="$(mktemp)"
    rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > "$PKG_BEFORE"
    "${RUNNER[@]}" microdnf -y --setopt=install_weak_deps=0 --nodocs upgrade </dev/null
    DNF_RC=$?
    rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > "$PKG_AFTER"
    CHANGED="$(comm -13 "$PKG_BEFORE" "$PKG_AFTER" | wc -l)"
    if [ "$DNF_RC" != 0 ]; then
        echo "microdnf finished with status $DNF_RC (offline, or a repository is down)."
        RESULT="microdnf failed (status $DNF_RC), $CHANGED package(s) changed before it stopped"
        STATUS=1
    elif [ "$CHANGED" -gt 0 ]; then
        RESULT="$CHANGED package(s) updated"
    fi
    if [ "$CHANGED" -gt 0 ]; then
        echo "Updated packages:"
        comm -13 "$PKG_BEFORE" "$PKG_AFTER" | sed 's/^/  /'
    fi
    microdnf clean all >/dev/null 2>&1 || true
    [ "$DNF_RC" = 0 ] && run_verify
else
    echo "dnf not found, skipping."
fi

# ---------------------------------------------------------------------------
# Wrap up. No reboot reminder on purpose: nothing here ever asks for a restart.
# ---------------------------------------------------------------------------
section "Done"
echo "Update run finished: $(date)"
echo "Result: $RESULT"

if [ "$AT_START" = 1 ]; then
    # Quiet unless something changed or went wrong; the log file has the details.
    case "$STATUS" in
        0) [ "$RESULT" = "nothing to update" ] || log "System updates: $RESULT (details: $LOGFILE)" >&3 ;;
        *) warn "System updates: $RESULT (details: $LOGFILE)" >&4 ;;
    esac
    # Keep the five newest logs.
    ls -1t "$LOG_DIR"/update-*.log 2>/dev/null | tail -n +6 | xargs -r rm -f --
fi
exit "$STATUS"
