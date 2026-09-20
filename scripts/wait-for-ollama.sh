#!/usr/bin/env bash
set -euo pipefail

OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
MAX_WAIT_SECONDS="${1:-60}"
WAIT_INTERVAL=1
ELAPSED=0

echo "[ollama] waiting for API at http://${OLLAMA_HOST}/api/tags..."

until curl -s -f "http://${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; do
    if [ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]; then
        echo "[ollama] timed out waiting after ${MAX_WAIT_SECONDS} seconds" >&2
        exit 1
    fi
    sleep "$WAIT_INTERVAL"
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

echo "[ollama] ready"
