#!/usr/bin/env bash
# Starts the interactive assistant. It reuses the index unless the source changed.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$PROJECT_DIR/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
  echo "Python environment is missing. Run 04-create-python-environment.sh first." >&2
  exit 1
fi

exec "$PYTHON" "$PROJECT_DIR/app.py"
