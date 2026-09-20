# Pin base image versions for determinism
# caddy:2.9-alpine is used to extract the caddy binary
FROM caddy:2.9.1-alpine AS caddy-bin

# Official Ollama image with CUDA 12 support for RunPod GPUs
FROM ollama/ollama:0.6.0

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    procps \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Copy Caddy binary from official caddy image
COPY --from=caddy-bin /usr/bin/caddy /usr/bin/caddy

WORKDIR /app

# Copy scripts and configuration templates
COPY Caddyfile /etc/caddy/Caddyfile
COPY start.sh /app/start.sh
COPY healthcheck.sh /app/healthcheck.sh
COPY scripts/ /app/scripts/

RUN chmod +x /app/start.sh /app/healthcheck.sh /app/scripts/*.sh

# Persistent storage directories:
# /root/.ollama: Ollama model weights, manifests, and blobs
# /data/caddy: Caddy TLS certificates and keys
# /config/caddy: Caddy autosaves and runtime config
VOLUME ["/root/.ollama", "/data/caddy", "/config/caddy"]

# Environment paths for Caddy persistent storage
ENV XDG_DATA_HOME=/data
ENV XDG_CONFIG_HOME=/config

# Expose Caddy's TLS port (default 8443)
EXPOSE 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["/app/healthcheck.sh"]

ENTRYPOINT ["/app/start.sh"]
