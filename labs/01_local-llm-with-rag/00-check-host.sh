#!/usr/bin/env bash
# Read-only preflight check for the local RAG lab.
set -euo pipefail

case "$(uname -s)" in
  Darwin) platform="macOS" ;;
  Linux) platform="Linux" ;;
  *)
    echo "Unsupported operating system: $(uname -s). This lab supports macOS and Linux." >&2
    exit 1
    ;;
esac

echo "Platform: ${platform} ($(uname -m))"
echo
echo "CPU:"
if [[ "$platform" == "macOS" ]]; then
  sysctl -n machdep.cpu.brand_string 2>/dev/null || true
  memory_bytes="$(sysctl -n hw.memsize)"
  awk -v bytes="$memory_bytes" 'BEGIN { printf "Memory: %.1f GiB\n", bytes / 1024 / 1024 / 1024 }'
else
  lscpu | grep -E 'Model name|CPU\(s\)' || true
  free -h
fi

echo
echo "Free space in home directory:"
df -h "$HOME"

echo
if command -v python3 >/dev/null 2>&1; then
  python3 --version
else
  echo "python3: not found (run 01-install-prerequisites.sh)"
fi

if command -v curl >/dev/null 2>&1; then
  curl --version | head -n 1
else
  echo "curl: not found (run 01-install-prerequisites.sh)"
fi

if command -v ollama >/dev/null 2>&1; then
  ollama --version
else
  echo "ollama: not found (run 02-install-ollama.sh)"
fi

echo
echo "Recommended minimum: 8 GiB RAM and 10 GiB free disk space."
