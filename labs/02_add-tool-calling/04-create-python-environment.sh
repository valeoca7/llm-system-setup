#!/usr/bin/env bash
# Creates/updates this lab's isolated Python environment.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || { echo "Run 01-install-prerequisites.sh first." >&2; exit 1; }
"$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' || {
  echo "Python 3.10 or later is required." >&2; exit 1
}
mkdir -p "$PROJECT_DIR/data" "$PROJECT_DIR/storage" "$PROJECT_DIR/logs"
[[ -x "$PROJECT_DIR/.venv/bin/python" ]] || "$PYTHON_BIN" -m venv "$PROJECT_DIR/.venv"
"$PROJECT_DIR/.venv/bin/python" -m pip install --upgrade pip
"$PROJECT_DIR/.venv/bin/python" -m pip install -r "$PROJECT_DIR/requirements.txt"
echo "Python environment ready: $PROJECT_DIR/.venv"
