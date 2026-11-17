# Fishbowl Advanced on Linux, in one container: Java 21 + MySQL 8.4 + the
# Fishbowl installer. Fishbowl itself is installed at FIRST START, after the
# person running the container accepts Fishbowl's license agreement on the
# Fishbowl page (http://localhost:6080/), which also shows Fishbowl Server
# Administration and the Fishbowl Client in browser tabs.
# See README.md.
#
# No "# syntax=" line on purpose: the Dockerfile frontend built into Docker is
# used, so a build never has to pull an extra image from Docker Hub.

ARG FEDORA_IMAGE=registry.fedoraproject.org/fedora:44

# ---------------------------------------------------------------------------
# Stage 1: find the installer on the GitHub release, download and inspect it
# ---------------------------------------------------------------------------
FROM ${FEDORA_IMAGE} AS installer
RUN dnf -y install --setopt=install_weak_deps=False python3 \
 && dnf clean all

# The one permanently named release that holds exactly one Fishbowl-*.sh asset.
ARG INSTALLER_REPO=cesiumskater/Docker_Testing
ARG INSTALLER_RELEASE_TAG=fishbowl-installer
ARG GITHUB_API_URL=https://api.github.com
# Optional (set by CI): fail if the release no longer holds the asset this build was started for.
ARG EXPECTED_ASSET_ID=

# BuildKit fetches this URL on every build. When the release's assets change,
# the response changes and every later step in this stage re-runs, so swapping
# the installer on the release is the whole update. No Dockerfile edits.
# (The response includes download counts too, so most builds download the
# installer again.)
ADD ${GITHUB_API_URL}/repos/${INSTALLER_REPO}/releases/tags/${INSTALLER_RELEASE_TAG} /build/release.json
COPY build/fetch-installer.py /build/fetch-installer.py
RUN python3 -I /build/fetch-installer.py --release-json /build/release.json --out /out \
      --repo "${INSTALLER_REPO}" --tag "${INSTALLER_RELEASE_TAG}" \
      --expected-asset-id "${EXPECTED_ASSET_ID}"

# ---------------------------------------------------------------------------
# Stage 2: the runtime image
# ---------------------------------------------------------------------------
FROM ${FEDORA_IMAGE}

# MySQL 8.4 from Fedora's own repositories (the install guide's lab-tested
# source), pinned to 8.4.x so a rebuild can never drift to 9.x. Java 21 is
# Eclipse Temurin from Adoptium's repository, as in the guide.
#
# The last two package lines are for the browser windows (fishbowl-session):
#   tigervnc-x11-server  Xvnc, a virtual screen that resizes with the browser tab
#   openbox              window manager (title bars, moving, maximizing)
#   novnc, websockify    the VNC viewer that runs in the browser, and its bridge
#   gtk3, nss, nspr      libraries the Fishbowl Client's built-in web view needs
#
# Fedora gives mysqld the file capability cap_sys_nice (thread priorities for
# MySQL resource groups). Docker's default capability set doesn't include it,
# so exec fails with "Operation not permitted". Dropping the file capability
# (same layer, so the binary isn't stored twice) beats asking every user for
# --cap-add.
RUN dnf -y install --setopt=install_weak_deps=False \
        'mysql-server-8.4.*' 'mysql-8.4.*' \
        adoptium-temurin-java-repository \
        tini util-linux shadow-utils procps-ng findutils which less gzip tar tzdata \
        python3 libcap \
        tigervnc-x11-server openbox novnc python3-websockify dejavu-sans-fonts \
        gtk3 nss nspr \
 && dnf -y install --setopt=install_weak_deps=False \
        --enablerepo=adoptium-temurin-java-repository temurin-21-jdk \
 && setcap -r /usr/libexec/mysqld \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/libdnf5 /var/log/dnf* /var/log/hawkey.log

# Build fails here unless mysqld/mysql are 8.4.x and Java is 21, or if the
# pieces the browser windows need are missing.
COPY rootfs/usr/local/lib/fishbowl/verify-runtime.sh /usr/local/lib/fishbowl/verify-runtime.sh
RUN bash /usr/local/lib/fishbowl/verify-runtime.sh

# Fishbowl Server, Server Administration and the Fishbowl Client run as
# "fishbowl", the Fishbowl page's web server as "fbweb". Neither is root.
RUN groupadd --gid 1000 fishbowl \
 && useradd --uid 1000 --gid 1000 --no-create-home --home-dir /var/lib/fishbowl/home/fishbowl \
        --shell /sbin/nologin --comment "Fishbowl Server" fishbowl \
 && groupadd --gid 1001 fbweb \
 && useradd --uid 1001 --gid 1001 --no-create-home --home-dir /nonexistent \
        --shell /sbin/nologin --comment "Fishbowl page" fbweb

# Permissions are set here, not taken from the repository: files uploaded
# through GitHub's web page lose their executable bit.
COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/fishbowl-* /usr/local/lib/fishbowl/verify-runtime.sh \
 && chmod 0644 /usr/local/lib/fishbowl/*.sh /usr/local/lib/fishbowl/*.py /usr/local/lib/fishbowl/*.xml /usr/local/lib/fishbowl/mysql-root-password.txt \
        /etc/my.cnf.d/90-fishbowl.cnf \
 && chmod 0755 /usr/local/lib/fishbowl/verify-runtime.sh \
 && find /usr/local/share/fishbowl -type d -exec chmod 0755 {} + \
 && find /usr/local/share/fishbowl -type f -exec chmod 0644 {} + \
 && python3 -I -m py_compile /usr/local/lib/fishbowl/portal.py \
 && mkdir -p /opt/Fishbowl /var/lib/fishbowl \
 && test -z "$(ls -A /var/lib/mysql)"

ARG FISHBOWL_IMAGE=fishbowl
ENV FISHBOWL_IMAGE=${FISHBOWL_IMAGE} \
    JAVA_HOME=/usr/lib/jvm/temurin-21-jdk \
    INSTALL4J_JAVA_HOME=/usr/lib/jvm/temurin-21-jdk \
    INSTALL4J_JAVA_HOME_OVERRIDE=/usr/lib/jvm/temurin-21-jdk \
    LANG=C.UTF-8

# Last, so swapping the installer only rebuilds this layer.
COPY --from=installer /out/ /opt/fishbowl-installer/
RUN . /opt/fishbowl-installer/installer.env \
 && test -s "$FISHBOWL_INSTALLER" && test -s "$FISHBOWL_EULA" \
 && echo "$FISHBOWL_INSTALLER_SHA256  $FISHBOWL_INSTALLER" | sha256sum -c - \
 && echo "Image carries Fishbowl $FISHBOWL_APP_VERSION ($FISHBOWL_INSTALLER)"

LABEL org.opencontainers.image.title="Fishbowl Advanced for Linux (Docker)" \
      org.opencontainers.image.description="Java 21 + MySQL 8.4 + the Fishbowl Advanced installer. Fishbowl installs at first start after you accept its license agreement on the Fishbowl page (port 6080)." \
      org.opencontainers.image.source="https://github.com/cesiumskater/Docker_Testing"

# Kept last: nothing after this line may write to these paths. Named volumes
# (README, compose.yaml) are what you want; without them Docker supplies unnamed
# ones, and the Fishbowl page warns about that.
VOLUME ["/var/lib/mysql", "/opt/Fishbowl", "/var/lib/fishbowl"]

# 2456: Fishbowl Clients. 6080: the Fishbowl page (publish it on 127.0.0.1 only).
EXPOSE 2456 6080
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=10m --retries=3 \
  CMD ["/usr/local/bin/fishbowl-healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/fishbowl-entrypoint"]
CMD ["run"]
