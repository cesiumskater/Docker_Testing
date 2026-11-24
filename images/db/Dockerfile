# Build context: the repository's top folder (compose.yaml does this); the
# Dockerfile.dockerignore next to this file keeps the context to this folder.
# The database container: the official MySQL 8.4 image with Fishbowl's required
# settings and the root-account step of fishbowl-db-entrypoint. Built by
# compose.yaml; README, "The Compose stack".
ARG MYSQL_IMAGE=mysql:8.4
FROM ${MYSQL_IMAGE}

# The weekly maintenance prunes old builds by this label.
LABEL org.opencontainers.image.source="https://github.com/cesiumskater/Docker_Testing" \
      org.opencontainers.image.title="Fishbowl database (MySQL 8.4)"

# Every build takes Oracle Linux's pending updates, so a weekly rebuild patches the
# database even between MySQL releases (decision 4: updates can't stall). MySQL
# itself stays on 8.4.x: its packages come from the 8.4 repository only.
ARG PACKAGES_REFRESH=
RUN microdnf -y upgrade --refresh \
 && microdnf clean all \
 && rm -rf /var/cache/yum /var/cache/dnf \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} +

COPY images/db/90-fishbowl.cnf /etc/mysql/conf.d/90-fishbowl.cnf
COPY --chmod=0755 images/db/fishbowl-db-entrypoint /usr/local/bin/fishbowl-db-entrypoint
# Fishbowl's own tuning (its server/bin/my.cnf, minus the guide's two settings)
# arrives in /etc/mysql/fishbowl.d from the fishbowl container, read before
# conf.d so the guide's settings always win.
# MySQL runs as uid 27, the mysql user of the single-container image (Fedora), so a
# data volume moves between the two with no chown (E14); a new volume starts out
# owned by 27 because these folders are.
RUN chown 27:27 /var/lib/mysql /var/lib/mysql-files /var/run/mysqld
RUN mkdir -p /etc/mysql/fishbowl.d \
 && sed -i 's#^!includedir /etc/mysql/conf.d/#!includedir /etc/mysql/fishbowl.d/\n&#' /etc/my.cnf \
 && grep -q '^!includedir /etc/mysql/fishbowl.d/' /etc/my.cnf \
 && chmod 0644 /etc/mysql/conf.d/90-fishbowl.cnf

USER 27:27
ENTRYPOINT ["/usr/local/bin/fishbowl-db-entrypoint"]
CMD ["mysqld", "--lower-case-table-names=1"]
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=3 \
  CMD ["mysqladmin", "--socket=/var/run/mysqld/mysqld.sock", "ping", "--silent"]
