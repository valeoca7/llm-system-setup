#!/usr/bin/env bash
# Downloads the generation and embedding models if they are not already local.
set -euo pipefail

LLM_MODEL="${LLM_MODEL:-qwen3:1.7b}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-qwen3-embedding:0.6b}"
API_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}/api/tags"

if ! command -v ollama >/dev/null 2>&1; then
  echo "Ollama is not installed. Run 02-install-ollama.sh first." >&2
  exit 1
fi

if ! curl -fsS --max-time 5 "$API_URL" >/dev/null; then
  echo "Ollama is not reachable at ${API_URL%/api/tags}. Run 02-install-ollama.sh first." >&2
  exit 1
fi

ensure_model() {
  local model="$1"
  if ollama show "$model" >/dev/null 2>&1; then
    echo "Model already available: $model"
  else
    echo "Pulling model: $model"
    ollama pull "$model"
  fi
}

ensure_model "$LLM_MODEL"
ensure_model "$EMBEDDING_MODEL"
ollama list
