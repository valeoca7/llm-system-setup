#!/usr/bin/env bash
# Installs Ollama when absent and starts its local API. Safe to rerun.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}/api/tags"

run_as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

wait_for_api() {
  local attempt
  for attempt in $(seq 1 30); do
    if curl -fsS --max-time 3 "$API_URL" >/dev/null; then
      echo "Ollama API is ready at ${API_URL%/api/tags}."
      return 0
    fi
    sleep 2
  done
  return 1
}

if ! command -v ollama >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin)
      if ! command -v brew >/dev/null 2>&1; then
        cat >&2 <<'EOF'
Install Ollama for macOS from https://ollama.com/download/mac, start the app once,
then rerun this script. Alternatively install Homebrew and rerun this script.
EOF
        exit 1
      fi
      brew install --cask ollama
      ;;
    Linux)
      installer="$(mktemp)"
      trap 'rm -f "$installer"' EXIT
      curl -fsSL --retry 3 https://ollama.com/install.sh -o "$installer"
      sh "$installer"
      ;;
    *)
      echo "This script supports macOS and Linux only." >&2
      exit 1
      ;;
  esac
fi

if command -v ollama >/dev/null 2>&1 && wait_for_api; then
  exit 0
fi

case "$(uname -s)" in
  Darwin)
    open -gj -a Ollama
    ;;
  Linux)
    if command -v systemctl >/dev/null 2>&1 \
      && systemctl show-environment >/dev/null 2>&1 \
      && systemctl cat ollama.service >/dev/null 2>&1; then
      run_as_root systemctl enable --now ollama
    else
      echo "systemd service is unavailable; starting Ollama in the background for this session."
      mkdir -p "$PROJECT_DIR/logs"
      nohup ollama serve >"$PROJECT_DIR/logs/ollama-serve.log" 2>&1 &
    fi
    ;;
esac

if ! wait_for_api; then
  cat >&2 <<EOF
Ollama was installed but its API did not become ready.
Linux: inspect 'systemctl status ollama' or '$PROJECT_DIR/logs/ollama-serve.log'.
macOS: open Ollama from Applications and accept any first-run prompts.
EOF
  exit 1
fi
