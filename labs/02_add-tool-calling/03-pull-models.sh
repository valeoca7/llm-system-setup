#!/usr/bin/env bash
# Downloads tool-capable generation and embedding models when absent.
set -euo pipefail

LLM_MODEL="${LLM_MODEL:-qwen3:1.7b}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-qwen3-embedding:0.6b}"
API_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}/api/tags"
command -v ollama >/dev/null 2>&1 || { echo "Run 02-install-ollama.sh first." >&2; exit 1; }
curl -fsS --max-time 5 "$API_URL" >/dev/null || { echo "Ollama is not reachable at ${API_URL%/api/tags}." >&2; exit 1; }
ensure_model() {
  if ollama show "$1" >/dev/null 2>&1; then echo "Model already available: $1"; else ollama pull "$1"; fi
}
ensure_model "$LLM_MODEL"
ensure_model "$EMBEDDING_MODEL"
ollama list
