#!/usr/bin/env bash
set -euo pipefail

OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
MODEL="${MODEL:-}"

# 1. Check Ollama API
if ! curl -s -f -m 5 "http://${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; do
    echo "[health] ollama API is not responding" >&2
    exit 1
fi

# 2. Check Caddy process
if ! pgrep -x caddy >/dev/null 2>&1; then
    echo "[health] caddy is not running" >&2
    exit 1
fi

# 3. Check if configured model is available (if MODEL is set)
if [ -n "$MODEL" ]; then
    EXISTING_MODELS=$(curl -s "http://${OLLAMA_HOST}/api/tags" 2>/dev/null || echo "{}")
    MODEL_NORMALIZED="$MODEL"
    if [[ "$MODEL" != *":"* ]]; then
        MODEL_NORMALIZED="${MODEL}:latest"
    fi
    if ! (echo "$EXISTING_MODELS" | grep -q "\"name\":\"${MODEL}\"" || echo "$EXISTING_MODELS" | grep -q "\"name\":\"${MODEL_NORMALIZED}\""); then
        echo "[health] configured model '${MODEL}' not found in Ollama" >&2
        exit 1
    fi
fi

echo "[health] ok"
exit 0
