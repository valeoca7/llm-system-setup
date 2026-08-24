#!/usr/bin/env bash
# Builds the index if needed and asks one deterministic sample question.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$PROJECT_DIR/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
  echo "Python environment is missing. Run 04-create-python-environment.sh first." >&2
  exit 1
fi

"$PYTHON" "$PROJECT_DIR/app.py" --question "What does the example assistant use for retrieval?" --show-context
