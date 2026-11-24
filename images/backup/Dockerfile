# Build context: the repository's top folder (compose.yaml does this); the
# Dockerfile.dockerignore next to this file keeps the context to this folder.
# The backup container: the official MySQL 8.4 image (for its mysqldump, the same
# version as the database) running fishbowl-backup's daily loop. Built by
# compose.yaml; README, "Backups in the Compose stack".
ARG MYSQL_IMAGE=mysql:8.4
FROM ${MYSQL_IMAGE}

# The weekly maintenance prunes old builds by this label.
LABEL org.opencontainers.image.source="https://github.com/cesiumskater/Docker_Testing" \
      org.opencontainers.image.title="Fishbowl backups (mysqldump)"

# Every build takes Oracle Linux's pending updates (decision 4: updates can't
# stall). tzdata: the daily time is in your time zone.
ARG PACKAGES_REFRESH=
RUN microdnf -y upgrade --refresh \
 && microdnf -y install tzdata \
 && microdnf clean all \
 && rm -rf /var/cache/yum /var/cache/dnf \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} + \
 && mkdir -p /backups \
 && chown 1000:1000 /backups \
 && chmod 0700 /backups

COPY --chmod=0755 images/backup/fishbowl-backup /usr/local/bin/fishbowl-backup

# Fishbowl's user (1000): it can read Fishbowl's settings files, which are its own.
USER 1000:1000
ENV HOME=/tmp
VOLUME /backups
ENTRYPOINT ["/usr/local/bin/fishbowl-backup"]
CMD ["run"]
HEALTHCHECK --interval=5m --timeout=5s --start-period=60s --start-interval=10s --retries=1 \
  CMD ["/usr/local/bin/fishbowl-backup", "--health"]
