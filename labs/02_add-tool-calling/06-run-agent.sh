#!/usr/bin/env bash
# Starts the interactive tool-calling assistant.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$PROJECT_DIR/.venv/bin/python"
[[ -x "$PYTHON" ]] || { echo "Run 04-create-python-environment.sh first." >&2; exit 1; }
exec "$PYTHON" "$PROJECT_DIR/app.py"
