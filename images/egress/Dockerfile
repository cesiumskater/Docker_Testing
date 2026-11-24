# Build context: the repository's top folder (compose.yaml does this); the
# Dockerfile.dockerignore next to this file keeps the context to this folder.
# The egress proxy: Squid from Alpine's packages, as its own unprivileged user,
# allowing only Fishbowl's servers. Built by compose.yaml; README, "The egress
# allowlist".
ARG ALPINE_IMAGE=alpine:3
FROM ${ALPINE_IMAGE}

# The weekly maintenance prunes old builds by this label.
LABEL org.opencontainers.image.source="https://github.com/cesiumskater/Docker_Testing" \
      org.opencontainers.image.title="Fishbowl egress proxy (Squid)"

# Every build takes Alpine's pending updates (decision 4: updates can't stall).
ARG PACKAGES_REFRESH=
RUN apk upgrade --no-cache \
 && apk add --no-cache squid \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} +

COPY images/egress/squid.conf /etc/squid/squid.conf
COPY images/egress/fishbowl-allowlist.txt /etc/squid/fishbowl-allowlist.txt
COPY --chmod=0755 images/egress/egress-entrypoint /usr/local/bin/egress-entrypoint

USER squid
EXPOSE 3128
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["nc", "-z", "127.0.0.1", "3128"]
ENTRYPOINT ["/usr/local/bin/egress-entrypoint"]
