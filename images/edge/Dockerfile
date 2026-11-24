# Build context: the repository's top folder (compose.yaml does this); the
# Dockerfile.dockerignore next to this file keeps the context to this folder.
# The edge (HTTPS for the Fishbowl page, TLS for Fishbowl Clients): the official
# Caddy image, run as an unprivileged user with this folder's Caddyfile. Built by
# compose.yaml; README, "The HTTPS front door".
ARG CADDY_IMAGE=caddy:2
FROM ${CADDY_IMAGE}

# The weekly maintenance prunes old builds by this label.
LABEL org.opencontainers.image.source="https://github.com/cesiumskater/Docker_Testing" \
      org.opencontainers.image.title="Fishbowl edge (Caddy)"

# Every build takes Alpine's pending updates, so a weekly rebuild patches the edge
# even between Caddy releases (decision 4: updates can't stall). The weekly
# maintenance passes a new value, so this layer never comes from the cache.
ARG PACKAGES_REFRESH=
RUN apk upgrade --no-cache \
 && addgroup -S -g 1002 edge \
 && adduser -S -D -H -u 1002 -G edge -h /data -s /sbin/nologin edge \
 && mkdir -p /data/caddy /config/caddy \
 && chown -R edge:edge /data /config \
 && chmod 0700 /data /config
# No setuid or setgid programs (CIS Docker Benchmark 4.8).
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} +

COPY images/edge/Caddyfile /etc/caddy/Caddyfile
# Checked at build time, with throwaway storage so no certificate authority ends
# up in the image (the real one is made at first start, in the fishbowl-edge volume).
RUN XDG_DATA_HOME=/tmp/validate XDG_CONFIG_HOME=/tmp/validate \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
 && rm -rf /tmp/validate

# Docker lets unprivileged processes bind any port inside a container, so the edge
# needs no capabilities, even for 443.
USER edge
EXPOSE 443 2456 6080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:9180/"]
