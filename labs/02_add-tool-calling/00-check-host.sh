#!/usr/bin/env bash
# Read-only preflight check for the local tool-calling lab.
set -euo pipefail

case "$(uname -s)" in
  Darwin) platform="macOS" ;;
  Linux) platform="Linux" ;;
  *) echo "Unsupported operating system: $(uname -s). This lab supports macOS and Linux." >&2; exit 1 ;;
esac

echo "Platform: ${platform} ($(uname -m))"
if [[ "$platform" == "macOS" ]]; then
  if memory_bytes="$(sysctl -n hw.memsize 2>/dev/null)"; then
    awk -v bytes="$memory_bytes" 'BEGIN { printf "Memory: %.1f GiB\n", bytes / 1024 / 1024 / 1024 }'
  else
    echo "Memory: unavailable in this environment"
  fi
else
  free -h
fi
echo "Free space in home directory:"
df -h "$HOME"
command -v python3 >/dev/null 2>&1 && python3 --version || echo "python3: not found"
command -v curl >/dev/null 2>&1 && curl --version | head -n 1 || echo "curl: not found"
command -v ollama >/dev/null 2>&1 && ollama --version || echo "ollama: not found"
echo "Recommended minimum: 8 GiB RAM and 10 GiB free disk space."
