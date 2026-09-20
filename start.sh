#!/usr/bin/env bash
set -euo pipefail

# 1. Validation and Fail-Fast
echo "[init] validating configuration..."
if [ -z "${MODEL:-}" ]; then
    echo "[init] ERROR: MODEL environment variable is required (e.g. MODEL=llama3.1:8b)" >&2
    exit 1
fi

if [ -z "${API_KEY:-}" ] || [ "${API_KEY}" = "change-me" ] || [ "${API_KEY}" = "change-this-to-a-secure-random-token" ]; then
    echo "[init] ERROR: API_KEY must be set to a secure, non-default value" >&2
    exit 1
fi

export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
export HTTPS_PORT="${HTTPS_PORT:-8443}"
export DOMAIN="${DOMAIN:-}"
export ACME_EMAIL="${ACME_EMAIL:-}"

# Ensure persistence directories exist
mkdir -p /root/.ollama
mkdir -p /data/caddy
mkdir -p /config/caddy
mkdir -p /etc/caddy

# 2. Build Caddyfile dynamically based on MODE A (Domain) vs MODE B (No Domain)
echo "[caddy] configuring TLS mode..."
if [ -n "$DOMAIN" ]; then
    echo "[caddy] MODE A selected: Domain-based TLS for ${DOMAIN}:${HTTPS_PORT}"
    TLS_DIRECTIVE=""
    if [ -n "$ACME_EMAIL" ]; then
        TLS_DIRECTIVE="tls ${ACME_EMAIL}"
    fi

    cat <<EOF > /etc/caddy/Caddyfile
{
	admin off
	persist_config off
	auto_https disable_redirects
	log {
		output stdout
		format console
		level WARN
	}
}

${DOMAIN}:${HTTPS_PORT} {
	@unauthorized {
		not header Authorization "Bearer {$API_KEY}"
	}
	respond @unauthorized "Unauthorized: Invalid or missing API key" 401 {
		close
	}

	reverse_proxy 127.0.0.1:11434 {
		flush_interval -1
		buffer_requests false
		buffer_responses false

		transport http {
			response_header_timeout 600s
			dial_timeout 10s
		}
	}

	${TLS_DIRECTIVE}
}
EOF
else
    echo "[caddy] MODE B selected: No-Domain self-signed TLS listening on :${HTTPS_PORT}"
    cat <<EOF > /etc/caddy/Caddyfile
{
	admin off
	persist_config off
	auto_https disable_redirects
	log {
		output stdout
		format console
		level WARN
	}
}

:${HTTPS_PORT} {
	@unauthorized {
		not header Authorization "Bearer {$API_KEY}"
	}
	respond @unauthorized "Unauthorized: Invalid or missing API key" 401 {
		close
	}

	reverse_proxy 127.0.0.1:11434 {
		flush_interval -1
		buffer_requests false
		buffer_responses false

		transport http {
			response_header_timeout 600s
			dial_timeout 10s
		}
	}

	tls internal
}
EOF
fi

# Clean process cleanup trap
OLLAMA_PID=""
CADDY_PID=""

shutdown() {
    echo "[init] received termination signal, shutting down services cleanly..."
    if [ -n "$CADDY_PID" ] && kill -0 "$CADDY_PID" 2>/dev/null; then
        echo "[caddy] stopping..."
        kill -TERM "$CADDY_PID" 2>/dev/null || true
    fi
    if [ -n "$OLLAMA_PID" ] && kill -0 "$OLLAMA_PID" 2>/dev/null; then
        echo "[ollama] stopping..."
        kill -TERM "$OLLAMA_PID" 2>/dev/null || true
    fi
    wait "$CADDY_PID" 2>/dev/null || true
    wait "$OLLAMA_PID" 2>/dev/null || true
    echo "[init] clean shutdown complete"
    exit 0
}

trap shutdown SIGTERM SIGINT

# 3. Start Ollama in background
echo "[ollama] starting..."
ollama serve &
OLLAMA_PID=$!

# 4. Wait for Ollama to become ready
/app/scripts/wait-for-ollama.sh 60

# 5. Check & pull model
/app/scripts/pull-model.sh "$MODEL"

# 6. Start Caddy
echo "[caddy] starting on port ${HTTPS_PORT}..."
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

echo "[server] ready"

# 7. Monitor background processes
while true; do
    if ! kill -0 "$OLLAMA_PID" 2>/dev/null; then
        echo "[ollama] process exited unexpectedly" >&2
        shutdown
        exit 1
    fi
    if ! kill -0 "$CADDY_PID" 2>/dev/null; then
        echo "[caddy] process exited unexpectedly" >&2
        shutdown
        exit 1
    fi
    sleep 2
done
