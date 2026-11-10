#!/usr/bin/env bash
# Runs deterministic tests, then exercises live Ollama routing and tool execution.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$PROJECT_DIR/.venv/bin/python"
[[ -x "$PYTHON" ]] || { echo "Run 04-create-python-environment.sh first." >&2; exit 1; }

PYTHONPATH="$PROJECT_DIR" "$PYTHON" -m unittest discover -s "$PROJECT_DIR/tests" -v
"$PYTHON" "$PROJECT_DIR/app.py" --verify-tools
"$PYTHON" "$PROJECT_DIR/app.py" --question "What is (25 * 4) + 10?"
"$PYTHON" "$PROJECT_DIR/app.py" --question "What is my job?"
