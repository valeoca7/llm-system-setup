#!/usr/bin/env bash
# Installs Ollama when absent and starts its local API. Safe to rerun.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}/api/tags"
run_as_root() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
wait_for_api() {
  local attempt
  for attempt in $(seq 1 30); do
    if curl -fsS --max-time 3 "$API_URL" >/dev/null; then
      echo "Ollama API is ready at ${API_URL%/api/tags}."; return 0
    fi
    sleep 2
  done
  return 1
}

if ! command -v ollama >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin)
      command -v brew >/dev/null 2>&1 || { echo "Install Ollama from https://ollama.com/download/mac." >&2; exit 1; }
      brew install --cask ollama
      ;;
    Linux)
      installer="$(mktemp)"; trap 'rm -f "$installer"' EXIT
      curl -fsSL --retry 3 https://ollama.com/install.sh -o "$installer"
      sh "$installer"
      ;;
    *) echo "This script supports macOS and Linux only." >&2; exit 1 ;;
  esac
fi
if wait_for_api; then exit 0; fi
case "$(uname -s)" in
  Darwin) open -gj -a Ollama ;;
  Linux)
    if command -v systemctl >/dev/null 2>&1 && systemctl cat ollama.service >/dev/null 2>&1; then
      run_as_root systemctl enable --now ollama
    else
      nohup ollama serve >"$PROJECT_DIR/logs/ollama-serve.log" 2>&1 &
    fi
    ;;
esac
wait_for_api || { echo "Ollama API did not become ready at ${API_URL%/api/tags}." >&2; exit 1; }
