#!/usr/bin/env bash
# Creates/updates the isolated Python environment and application directories.
# Packages are installed only inside .venv; this never uses the system pip.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "${PYTHON_BIN} is not installed. Run 01-install-prerequisites.sh first." >&2
  exit 1
fi

"$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' || {
  echo "Python 3.10 or later is required." >&2
  exit 1
}

mkdir -p "$PROJECT_DIR/data" "$PROJECT_DIR/storage" "$PROJECT_DIR/logs"
if [[ ! -x "$PROJECT_DIR/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$PROJECT_DIR/.venv"
fi

# PEP 668's externally-managed-environment restriction does not apply inside a venv.
# Always invoke pip through this interpreter; never call bare pip or pip3.
"$PROJECT_DIR/.venv/bin/python" -m pip install --upgrade pip
"$PROJECT_DIR/.venv/bin/python" -m pip install -r "$PROJECT_DIR/requirements.txt"

echo "Python environment ready: $PROJECT_DIR/.venv"
