#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-${MODEL:-}}"
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"

if [ -z "$MODEL" ]; then
    echo "[model] error: No model specified in \$MODEL or argument" >&2
    exit 1
fi

echo "[model] checking ${MODEL}..."

# List available models via Ollama API
EXISTING_MODELS=$(curl -s "http://${OLLAMA_HOST}/api/tags" 2>/dev/null || echo "{}")

# Normalize model name for checking (if user gives model without tag, default is :latest)
MODEL_NORMALIZED="$MODEL"
if [[ "$MODEL" != *":"* ]]; then
    MODEL_NORMALIZED="${MODEL}:latest"
fi

# Check if model name or normalized name exists in the models list
if echo "$EXISTING_MODELS" | grep -q "\"name\":\"${MODEL}\"" || echo "$EXISTING_MODELS" | grep -q "\"name\":\"${MODEL_NORMALIZED}\""; then
    echo "[model] already installed"
    exit 0
fi

echo "[model] not found on persistent volume. Pulling ${MODEL}..."
ollama pull "$MODEL"
echo "[model] pull completed successfully for ${MODEL}"
