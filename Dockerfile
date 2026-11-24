# Fishbowl Advanced on Linux in Docker. Two ways to run it (README.md):
#
#   * One container (the default target, the last stage in this file): Java 21
#     + MySQL 8.4 + the Fishbowl installer + the Fishbowl page and its browser
#     windows. `docker build .` builds this.
#   * The Compose stack (compose.yaml): each part in its own container, built
#     from the targets "server", "page" and "desktop" below, none of them
#     running as root, with MySQL in its own container (images/db).
#
# Either way, Fishbowl itself is installed at FIRST START, after the person
# running it accepts Fishbowl's license agreement on the Fishbowl page, which
# also shows Fishbowl Server Administration and the Fishbowl Client in browser
# tabs.
#
# No "# syntax=" line on purpose: the Dockerfile frontend built into Docker is
# used, so a build never has to pull an extra image from Docker Hub.

ARG FEDORA_IMAGE=registry.fedoraproject.org/fedora:44
# The Compose stack's bases: Red Hat's Universal Base Image 9 (minimal) for
# Fishbowl Server and the page, AlmaLinux 9 for the windows (their packages come
# from EPEL there), and the official MySQL 8.4 image for MySQL's client tools.
# Red Hat's and AlmaLinux's registries have no anonymous pull limit.
ARG UBI_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest
ARG DESKTOP_BASE_IMAGE=quay.io/almalinuxorg/almalinux:9
ARG MYSQL_IMAGE=mysql:8.4

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

# ===========================================================================
# The Compose stack's images (compose.yaml builds the targets "server", "page"
# and "desktop"). Each runs as its own user, never as root, on a read-only
# root filesystem; Docker's init (compose.yaml: init: true) is process 1.
# ===========================================================================

# MySQL's client tools (mysql, mysqldump, mysqladmin) for the server and the
# desktop, from the same official MySQL 8.4 image the db and backup containers
# run, so every part uses one MySQL version. That image is Oracle Linux 9, the
# same family as UBI 9 and AlmaLinux 9, so the tools run on their libraries.
FROM ${MYSQL_IMAGE} AS mysql-tools

# noVNC, the window viewer the page hands to browsers: Fedora's package, the
# same files the single container serves.
FROM ${FEDORA_IMAGE} AS novnc
ARG PACKAGES_REFRESH=
RUN dnf -y install --setopt=install_weak_deps=False novnc \
 && test -f /usr/share/novnc/core/rfb.js \
 && dnf clean all

# Noto Sans, the sans-serif font Fedora gives the single container (Java's
# SansSerif and Dialog fonts): the windows' text, and reports that ask for
# SansSerif or Arial, come out the same in the stack. UBI 9 has no Noto, so the
# server gets the four faces from AlmaLinux 9's package (SIL Open Font License;
# its text comes along). The desktop installs the package itself.
FROM ${DESKTOP_BASE_IMAGE} AS fonts
ARG PACKAGES_REFRESH=
RUN dnf -y install --setopt=install_weak_deps=False google-noto-sans-fonts \
 && mkdir -p /out/fonts /out/license \
 && cp /usr/share/fonts/google-noto/NotoSans-Regular.ttf /usr/share/fonts/google-noto/NotoSans-Bold.ttf \
       /usr/share/fonts/google-noto/NotoSans-Italic.ttf /usr/share/fonts/google-noto/NotoSans-BoldItalic.ttf /out/fonts/ \
 && cp -r /usr/share/licenses/google-noto-fonts-common/. /out/license/ \
 && dnf clean all

# ---------------------------------------------------------------------------
# Target "server": Fishbowl Server, its first-time setup and its upgrades.
# UBI 9 minimal, Eclipse Temurin's Java 21 JRE (a package, so every build's
# update step brings Java's fixes too), fonts for reports, MySQL's client tools
# and the Fishbowl installer. No window libraries, no compilers.
# ---------------------------------------------------------------------------
FROM ${UBI_IMAGE} AS server
ENV JAVA_HOME=/usr/lib/jvm/temurin-21-jre \
    FISHBOWL_VERIFY_PART=server
COPY build/adoptium-el9.repo /etc/yum.repos.d/adoptium.repo
COPY rootfs/usr/local/lib/fishbowl/verify-runtime.sh /usr/local/lib/fishbowl/verify-runtime.sh
COPY rootfs/usr/local/bin/update-all.sh /usr/local/bin/update-all.sh
COPY --from=mysql-tools /usr/bin/mysql /usr/bin/mysqldump /usr/bin/mysqladmin /usr/bin/
# As in the single container: update-all.sh --build applies every update
# published so far and fails the build if a repository can't be read or the
# runtime check (verify-runtime.sh server) fails (decision 4).
ARG PACKAGES_REFRESH=
RUN microdnf -y --setopt=install_weak_deps=0 --nodocs install \
        temurin-21-jre fontconfig dejavu-sans-fonts \
        python3 procps-ng util-linux findutils diffutils tar gzip which hostname tzdata \
        ncurses-libs zlib openssl-libs \
 && bash /usr/local/bin/update-all.sh --build \
 && mkdir -p /usr/local/share/fishbowl \
 && date -u +%Y-%m-%dT%H:%M:%SZ > /usr/local/share/fishbowl/image-built \
 && microdnf clean all \
 && rm -rf /var/cache/yum /var/log/dnf* /var/log/hawkey.log
COPY --from=fonts /out/fonts/ /usr/share/fonts/google-noto-sans/
COPY --from=fonts /out/license/ /usr/share/licenses/google-noto-sans-fonts/
COPY build/fontconfig-sans-noto.conf /etc/fonts/conf.d/56-fishbowl-sans-noto.conf
RUN chmod 0644 /etc/fonts/conf.d/56-fishbowl-sans-noto.conf && fc-cache -f \
 && fc-match sans-serif | grep -q 'Noto Sans'
# Fishbowl's user (Fishbowl Server, setup, upgrades) and the page's, the same
# numbers as in the single container, so the volumes move between the two.
RUN printf '%s\n' 'fishbowl:x:1000:1000:Fishbowl Server:/var/lib/fishbowl/home/fishbowl:/sbin/nologin' \
                  'fbweb:x:1001:1001:Fishbowl page:/nonexistent:/sbin/nologin' >> /etc/passwd \
 && printf '%s\n' 'fishbowl:x:1000:' 'fbweb:x:1001:' >> /etc/group
# The scripts, without the single container's MySQL root password file: in the
# stack that password arrives as a Compose secret, and no image carries it.
COPY rootfs/usr/local/bin/ /usr/local/bin/
COPY rootfs/usr/local/lib/fishbowl/*.sh rootfs/usr/local/lib/fishbowl/*.py rootfs/usr/local/lib/fishbowl/*.stub /usr/local/lib/fishbowl/
RUN chmod 0755 /usr/local/bin/fishbowl-* /usr/local/bin/update-all.sh /usr/local/lib/fishbowl/verify-runtime.sh \
 && chmod 0644 /usr/local/lib/fishbowl/*.py /usr/local/lib/fishbowl/*.stub /usr/local/lib/fishbowl/common.sh \
        /usr/local/lib/fishbowl/setup.sh /usr/local/lib/fishbowl/upgrade.sh \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} + \
 && mkdir -p /opt/Fishbowl /var/lib/fishbowl /var/lib/fishbowl-dbconf /run/fishbowl /etc/systemd \
 && chown 1000:1000 /opt/Fishbowl /var/lib/fishbowl /var/lib/fishbowl-dbconf /run/fishbowl \
 && rm -rf /etc/systemd/system && ln -s /tmp/install4j/systemd-units /etc/systemd/system
ARG FISHBOWL_IMAGE=fishbowl-server
ENV FISHBOWL_ROLE=server \
    FISHBOWL_IMAGE=${FISHBOWL_IMAGE} \
    INSTALL4J_JAVA_HOME=/usr/lib/jvm/temurin-21-jre \
    INSTALL4J_JAVA_HOME_OVERRIDE=/usr/lib/jvm/temurin-21-jre \
    LANG=C.UTF-8
# Last, so swapping the installer only rebuilds this layer.
COPY --from=installer /out/ /opt/fishbowl-installer/
RUN . /opt/fishbowl-installer/installer.env \
 && test -s "$FISHBOWL_INSTALLER" && test -s "$FISHBOWL_EULA" \
 && echo "$FISHBOWL_INSTALLER_SHA256  $FISHBOWL_INSTALLER" | sha256sum -c - \
 && echo "Image carries Fishbowl $FISHBOWL_APP_VERSION ($FISHBOWL_INSTALLER)"
LABEL org.opencontainers.image.title="Fishbowl Advanced: Fishbowl Server (Compose stack)" \
      org.opencontainers.image.description="Fishbowl Server on UBI 9 with the Java 21 JRE, run by compose.yaml as uid 1000. Fishbowl installs at first start after you accept its license agreement on the Fishbowl page." \
      org.opencontainers.image.source="https://github.com/cesiumskater/Docker_Testing"
USER 1000:1000
# 2456: Fishbowl Clients. 28192: Fishbowl's API (integrated apps). Only the edge
# containers publish ports; these are reached on the stack's own network.
EXPOSE 2456 28192
STOPSIGNAL SIGTERM
# Healthy once Fishbowl Server answers an HTTP request on its client port and
# MySQL answers (fishbowl-healthcheck). Checks every 5 s while it starts.
HEALTHCHECK --interval=10s --timeout=5s --start-period=10m --start-interval=5s --retries=3 \
  CMD ["/usr/local/bin/fishbowl-healthcheck"]
ENTRYPOINT ["/usr/local/bin/fishbowl-entrypoint"]
CMD ["run"]

# ---------------------------------------------------------------------------
# Target "page": the Fishbowl page (portal.py) and noVNC's files. UBI 9 minimal
# with Python 3. It never holds a password: no MySQL secret, no License Key.
# ---------------------------------------------------------------------------
FROM ${UBI_IMAGE} AS page
ENV FISHBOWL_VERIFY_PART=page
COPY rootfs/usr/local/lib/fishbowl/verify-runtime.sh /usr/local/lib/fishbowl/verify-runtime.sh
COPY rootfs/usr/local/bin/update-all.sh /usr/local/bin/update-all.sh
COPY --from=novnc /usr/share/novnc/ /usr/share/novnc/
ARG PACKAGES_REFRESH=
RUN microdnf -y --setopt=install_weak_deps=0 --nodocs install \
        python3 procps-ng util-linux findutils tzdata \
 && bash /usr/local/bin/update-all.sh --build \
 && mkdir -p /usr/local/share/fishbowl \
 && date -u +%Y-%m-%dT%H:%M:%SZ > /usr/local/share/fishbowl/image-built \
 && microdnf clean all \
 && rm -rf /var/cache/yum /var/log/dnf* /var/log/hawkey.log
RUN printf '%s\n' 'fishbowl:x:1000:1000:Fishbowl Server:/var/lib/fishbowl/home/fishbowl:/sbin/nologin' \
                  'fbweb:x:1001:1001:Fishbowl page:/nonexistent:/sbin/nologin' >> /etc/passwd \
 && printf '%s\n' 'fishbowl:x:1000:' 'fbweb:x:1001:' >> /etc/group
COPY rootfs/usr/local/bin/fishbowl-entrypoint rootfs/usr/local/bin/fishbowl-healthcheck rootfs/usr/local/bin/fishbowl-link /usr/local/bin/
# The entrypoint loads all of the shell library (setup.sh and upgrade.sh only
# define functions; the page never runs them).
COPY rootfs/usr/local/lib/fishbowl/*.sh rootfs/usr/local/lib/fishbowl/*.py /usr/local/lib/fishbowl/
COPY rootfs/usr/local/share/fishbowl/ /usr/local/share/fishbowl/
# The license agreement and the version facts the page shows; not the installer.
COPY --from=installer /out/installer.env /out/VERSION /opt/fishbowl-installer/
COPY --from=installer /out/eula/ /opt/fishbowl-installer/eula/
RUN chmod 0755 /usr/local/bin/fishbowl-* \
 && chmod 0644 /usr/local/lib/fishbowl/*.sh /usr/local/lib/fishbowl/*.py \
 && chmod 0755 /usr/local/lib/fishbowl/verify-runtime.sh \
 && find /usr/local/share/fishbowl /opt/fishbowl-installer -type d -exec chmod 0755 {} + \
 && find /usr/local/share/fishbowl /opt/fishbowl-installer -type f -exec chmod 0644 {} + \
 && python3 -I -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' /usr/local/lib/fishbowl/portal.py \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} + \
 && mkdir -p /var/lib/fishbowl/page /var/lib/fishbowl/import /run/fishbowl
ENV FISHBOWL_ROLE=page \
    LANG=C.UTF-8
LABEL org.opencontainers.image.title="Fishbowl Advanced: the Fishbowl page (Compose stack)" \
      org.opencontainers.image.description="The Fishbowl page on UBI 9: setup, upgrades and Fishbowl's windows in the browser. Run by compose.yaml as uid 1001 behind the HTTPS edge." \
      org.opencontainers.image.source="https://github.com/cesiumskater/Docker_Testing"
# The page's own user, in Fishbowl's group: it reads the status Fishbowl Server
# publishes and connects to the windows' sockets on the shared in-memory volume.
USER 1001:1000
EXPOSE 6080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --start-interval=2s --retries=3 \
  CMD ["/usr/local/bin/fishbowl-healthcheck"]
ENTRYPOINT ["/usr/local/bin/fishbowl-entrypoint"]
CMD ["run"]

# ---------------------------------------------------------------------------
# Target "desktop": Server Administration and the Fishbowl Client, each on its
# own virtual screen, shown in the browser through the page. AlmaLinux 9 with
# EPEL (TigerVNC's Xvnc from AlmaLinux, openbox from EPEL), the Temurin 21 JRE,
# GTK 3 and NSS for the Client's built-in web view, MySQL's client tools (Server
# Administration's Backup and Restore tabs run them), and websockify 0.12.0
# from PyPI, pinned by hash (build/websockify-requirements.txt says why).
# ---------------------------------------------------------------------------
FROM ${DESKTOP_BASE_IMAGE} AS desktop
ENV JAVA_HOME=/usr/lib/jvm/temurin-21-jre \
    FISHBOWL_VERIFY_PART=desktop
COPY build/adoptium-el9.repo /etc/yum.repos.d/adoptium.repo
COPY build/websockify-requirements.txt /usr/local/lib/fishbowl/websockify-requirements.txt
COPY rootfs/usr/local/lib/fishbowl/verify-runtime.sh /usr/local/lib/fishbowl/verify-runtime.sh
COPY rootfs/usr/local/bin/update-all.sh /usr/local/bin/update-all.sh
COPY --from=mysql-tools /usr/bin/mysql /usr/bin/mysqldump /usr/bin/mysqladmin /usr/bin/
ARG PACKAGES_REFRESH=
RUN dnf -y install --setopt=install_weak_deps=False epel-release \
 && dnf -y install --setopt=install_weak_deps=False --nodocs \
        temurin-21-jre tigervnc-server-minimal openbox gtk3 nss nspr \
        google-noto-sans-fonts urw-base35-fonts dejavu-sans-fonts \
        python3 python3-pip procps-ng util-linux findutils diffutils which hostname tar gzip \
        ncurses-libs zlib openssl-libs \
 && pip3 install --no-cache-dir --disable-pip-version-check --no-deps --only-binary :all: \
        --require-hashes -r /usr/local/lib/fishbowl/websockify-requirements.txt \
 && dnf -y remove python3-pip \
 && bash /usr/local/bin/update-all.sh --build \
 && mkdir -p /usr/local/share/fishbowl \
 && date -u +%Y-%m-%dT%H:%M:%SZ > /usr/local/share/fishbowl/image-built \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/log/dnf* /var/log/hawkey.log
# The same fonts as the single container's windows (see the fonts stage).
# MySQL's client tools always use TCP here, also for "localhost": there's no
# MySQL socket in this container, and localhost:3306 is the database container
# (db-relay.py), so Server Administration's Restore tab works as it does in the
# single container.
COPY build/fontconfig-sans-noto.conf /etc/fonts/conf.d/56-fishbowl-sans-noto.conf
RUN chmod 0644 /etc/fonts/conf.d/56-fishbowl-sans-noto.conf && fc-cache -f \
 && fc-match sans-serif | grep -q 'Noto Sans' && fc-match serif | grep -q 'Nimbus Roman' \
 && printf '%s\n' '# MySQL client tools in the desktop container: TCP, also for "localhost" (db-relay.py).' \
                   '[client]' 'protocol=tcp' > /etc/my.cnf \
 && chmod 0644 /etc/my.cnf
RUN printf '%s\n' 'fishbowl:x:1000:1000:Fishbowl Server:/var/lib/fishbowl/home/fishbowl:/sbin/nologin' \
                  'fbweb:x:1001:1001:Fishbowl page:/nonexistent:/sbin/nologin' >> /etc/passwd \
 && printf '%s\n' 'fishbowl:x:1000:' 'fbweb:x:1001:' >> /etc/group
COPY rootfs/usr/local/bin/ /usr/local/bin/
COPY rootfs/usr/local/lib/fishbowl/*.sh rootfs/usr/local/lib/fishbowl/*.py rootfs/usr/local/lib/fishbowl/*.xml /usr/local/lib/fishbowl/
COPY --from=installer /out/installer.env /out/VERSION /opt/fishbowl-installer/
COPY --from=installer /out/eula/ /opt/fishbowl-installer/eula/
RUN chmod 0755 /usr/local/bin/fishbowl-* /usr/local/bin/update-all.sh /usr/local/lib/fishbowl/verify-runtime.sh \
 && chmod 0644 /usr/local/lib/fishbowl/*.py /usr/local/lib/fishbowl/*.xml /usr/local/lib/fishbowl/common.sh \
        /usr/local/lib/fishbowl/setup.sh /usr/local/lib/fishbowl/upgrade.sh /usr/local/lib/fishbowl/websockify-requirements.txt \
 && find /opt/fishbowl-installer -type d -exec chmod 0755 {} + \
 && find /opt/fishbowl-installer -type f -exec chmod 0644 {} + \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} + \
 && mkdir -p /opt/Fishbowl /var/lib/fishbowl /run/fishbowl \
 && chown 1000:1000 /opt/Fishbowl /var/lib/fishbowl /run/fishbowl
ENV FISHBOWL_ROLE=desktop \
    INSTALL4J_JAVA_HOME=/usr/lib/jvm/temurin-21-jre \
    INSTALL4J_JAVA_HOME_OVERRIDE=/usr/lib/jvm/temurin-21-jre \
    LANG=C.UTF-8
LABEL org.opencontainers.image.title="Fishbowl Advanced: Fishbowl's windows (Compose stack)" \
      org.opencontainers.image.description="Server Administration and the Fishbowl Client on AlmaLinux 9, each on a private virtual screen the Fishbowl page shows in the browser. Run by compose.yaml as uid 1000." \
      org.opencontainers.image.source="https://github.com/cesiumskater/Docker_Testing"
USER 1000:1000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --start-interval=2s --retries=3 \
  CMD ["/usr/local/bin/fishbowl-healthcheck"]
ENTRYPOINT ["/usr/local/bin/fishbowl-entrypoint"]
CMD ["run"]

# ===========================================================================
# The single container (the default target): everything in one, Fedora 44.
# ===========================================================================
FROM ${FEDORA_IMAGE} AS single

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
# so exec fails with "Operation not permitted". update-all.sh --build drops the
# file capability (same layer, so the binary isn't stored twice), which beats
# asking every user for --cap-add.
#
# update-all.sh --build then applies every package update published so far, in
# the same layer, and fails the build if a repository can't be read or the
# runtime check fails: no image ships quietly unpatched (decision 4). It also
# runs verify-runtime.sh: MySQL 8.4.x, Java 21, the browser-window pieces.
COPY rootfs/usr/local/lib/fishbowl/verify-runtime.sh /usr/local/lib/fishbowl/verify-runtime.sh
COPY rootfs/usr/local/bin/update-all.sh /usr/local/bin/update-all.sh
# A new value makes Docker run the next step again instead of reusing its cache.
# The weekly maintenance and the weekly CI build pass the date; a plain build
# passes nothing, and its packages are as new as that step's last run.
ARG PACKAGES_REFRESH=
RUN dnf -y install --setopt=install_weak_deps=False \
        'mysql-server-8.4.*' 'mysql-8.4.*' \
        adoptium-temurin-java-repository \
        tini util-linux shadow-utils procps-ng findutils which less gzip tar tzdata \
        python3 libcap \
        tigervnc-x11-server openbox novnc python3-websockify dejavu-sans-fonts \
        gtk3 nss nspr \
 && dnf -y install --setopt=install_weak_deps=False \
        --enablerepo=adoptium-temurin-java-repository temurin-21-jdk \
 && bash /usr/local/bin/update-all.sh --build \
 && mkdir -p /usr/local/share/fishbowl \
 && date -u +%Y-%m-%dT%H:%M:%SZ > /usr/local/share/fishbowl/image-built \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/libdnf5 /var/log/dnf* /var/log/hawkey.log

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
RUN chmod 0755 /usr/local/bin/fishbowl-* /usr/local/bin/update-all.sh /usr/local/lib/fishbowl/verify-runtime.sh \
 && chmod 0644 /usr/local/lib/fishbowl/*.sh /usr/local/lib/fishbowl/*.py /usr/local/lib/fishbowl/*.xml /usr/local/lib/fishbowl/mysql-root-password.txt \
        /etc/my.cnf.d/50-fishbowl-tuning.cnf /etc/my.cnf.d/90-fishbowl.cnf \
 && chmod 0755 /usr/local/lib/fishbowl/verify-runtime.sh \
 && find /usr/local/share/fishbowl -type d -exec chmod 0755 {} + \
 && find /usr/local/share/fishbowl -type f -exec chmod 0644 {} + \
 && python3 -I -m py_compile /usr/local/lib/fishbowl/portal.py \
 && mkdir -p /opt/Fishbowl /var/lib/fishbowl \
 && test -z "$(ls -A /var/lib/mysql)"

# Fishbowl's installer writes two things outside the volumes: a systemd unit file
# (this container has no systemd) and install4j's list of installations under
# root's home (never needed here: a new image has always meant a new container).
# Pointing both into /run keeps them working on a read-only container, instead of
# failing with errors in the setup log. The entrypoint creates the targets.
RUN rm -rf /etc/systemd/system /root/.local \
 && ln -s /run/install4j/systemd-units /etc/systemd/system \
 && ln -s /run/install4j/root-local /root/.local

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

# 2456: Fishbowl Clients. 28192: Fishbowl's API ("Legacy Port"), for integrated
# apps and integrations. 6080: the Fishbowl page (publish it on 127.0.0.1 only).
EXPOSE 2456 28192 6080
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=10m --retries=3 \
  CMD ["/usr/local/bin/fishbowl-healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/fishbowl-entrypoint"]
CMD ["run"]
