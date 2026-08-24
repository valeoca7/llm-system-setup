#!/usr/bin/env bash
# Stops this lab's assistant process and the local Ollama runtime. Safe to rerun.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

stop_lab_app() {
  local stopped=0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    echo "Stopping local RAG assistant process: $pid"
    kill -TERM "$pid" 2>/dev/null || true
    stopped=1
  done < <(pgrep -f "$PROJECT_DIR/app.py" 2>/dev/null || true)

  if [[ "$stopped" -eq 0 ]]; then
    echo "No running local RAG assistant process found."
  fi
}

stop_ollama() {
  local stopped=0

  case "$(uname -s)" in
    Darwin)
      if pgrep -x "Ollama" >/dev/null 2>&1 && command -v osascript >/dev/null 2>&1; then
        echo "Requesting Ollama application shutdown."
        osascript -e 'tell application "Ollama" to quit' || true
        stopped=1
      fi
      ;;
    Linux)
      if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ollama; then
        echo "Stopping the Ollama system service."
        run_as_root systemctl stop ollama
        stopped=1
      fi
      ;;
    *)
      echo "Unsupported operating system: $(uname -s)." >&2
      exit 1
      ;;
  esac

  # Covers a manually started `ollama serve` process on either supported platform.
  if pgrep -x "ollama" >/dev/null 2>&1; then
    echo "Stopping Ollama server process(es)."
    pkill -TERM -x "ollama" || true
    stopped=1
  fi

  if [[ "$stopped" -eq 0 ]]; then
    echo "Ollama is not running."
  fi
}

stop_lab_app
stop_ollama
echo "Stop request completed."
