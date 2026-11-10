#!/usr/bin/env bash
# Installs Python, venv support, pip, curl, and timezone data. Safe to rerun.
set -euo pipefail

run_as_root() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

case "$(uname -s)" in
  Darwin)
    command -v brew >/dev/null 2>&1 || { echo "Install Homebrew from https://brew.sh, then rerun." >&2; exit 1; }
    brew install python curl
    ;;
  Linux)
    if command -v apt-get >/dev/null 2>&1; then
      run_as_root apt-get update
      run_as_root apt-get install -y python3 python3-venv python3-pip curl tzdata
    elif command -v dnf >/dev/null 2>&1; then
      run_as_root dnf install -y python3 python3-pip curl tzdata
    elif command -v pacman >/dev/null 2>&1; then
      run_as_root pacman -Sy --needed --noconfirm python python-pip curl tzdata
    else
      echo "Install Python 3, pip, venv support, curl, and IANA timezone data manually." >&2
      exit 1
    fi
    ;;
  *) echo "This script supports macOS and Linux only." >&2; exit 1 ;;
esac
python3 --version
curl --version | head -n 1
