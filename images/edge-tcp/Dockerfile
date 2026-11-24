# Build context: the repository's top folder (compose.yaml does this); the
# Dockerfile.dockerignore next to this file keeps the context to this folder.
# The edge's TCP relay for Fishbowl Server's two ports (2456 and 28192 unless
# FB_CLIENT_PORT and FB_API_PORT say otherwise): the official HAProxy image (LTS
# line, Alpine), as its own unprivileged user. Built by compose.yaml; README, "The
# HTTPS front door".
ARG HAPROXY_IMAGE=haproxy:lts-alpine
FROM ${HAPROXY_IMAGE}

# The weekly maintenance prunes old builds by this label.
LABEL org.opencontainers.image.source="https://github.com/cesiumskater/Docker_Testing" \
      org.opencontainers.image.title="Fishbowl edge TCP relay (HAProxy)"

# Every build takes Alpine's pending updates (decision 4: updates can't stall).
ARG PACKAGES_REFRESH=
USER root
RUN apk upgrade --no-cache \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} +
COPY images/edge-tcp/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
# The pair it relays; compose.yaml sets both from .env.
ENV FB_CLIENT_PORT=2456 FB_API_PORT=28192
RUN haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
USER haproxy

EXPOSE 2456 28192
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8405/healthz"]
