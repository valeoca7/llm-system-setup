#!/usr/bin/env bash
# Stops this lab's agent and the shared local Ollama runtime. Safe to rerun.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_as_root() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
found=0
while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  echo "Stopping Lab 02 agent process: $pid"; kill -TERM "$pid" 2>/dev/null || true; found=1
done < <(pgrep -f "$PROJECT_DIR/app.py" 2>/dev/null || true)
[[ "$found" -eq 1 ]] || echo "No running Lab 02 agent process found."

case "$(uname -s)" in
  Darwin)
    if pgrep -x Ollama >/dev/null 2>&1; then osascript -e 'tell application "Ollama" to quit' || true; fi
    ;;
  Linux)
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ollama; then run_as_root systemctl stop ollama; fi
    ;;
  *) echo "Unsupported operating system: $(uname -s)." >&2; exit 1 ;;
esac
if pgrep -x ollama >/dev/null 2>&1; then pkill -TERM -x ollama || true; else echo "Ollama is not running."; fi
echo "Stop request completed."
