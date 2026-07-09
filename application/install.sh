#!/usr/bin/env bash
# OCP Reproducer Toolkit — installer (macOS + Linux)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "=============================================="
echo "  OCP Reproducer Toolkit — Install"
echo "=============================================="
echo ""

# --- Python 3 ---
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required."
  echo ""
  echo "Install hints:"
  echo "  macOS:   brew install python3"
  echo "  RHEL:    sudo dnf install python3 python3-pip"
  echo "  Fedora:  sudo dnf install python3 python3-pip"
  echo "  Ubuntu:  sudo apt install python3 python3-venv python3-pip"
  exit 1
fi

PY_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 9 ]; }; then
  echo "ERROR: Python 3.9+ required (found $PY_VERSION)"
  exit 1
fi
echo "✓ Python $PY_VERSION"

# --- venv ---
if [ ! -d ".venv" ]; then
  echo "Creating virtual environment…"
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

echo "Installing Python dependencies…"
pip install --upgrade pip -q
pip install -r requirements.txt -q
echo "✓ Dependencies installed"

# --- Script permissions (repo root, sibling of application/) ---
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
MARKED=0
for f in "$REPO_ROOT"/*.sh "$REPO_ROOT"/loki-install-aws-gcp-loki-script; do
  if [ -f "$f" ]; then
    chmod +x "$f" 2>/dev/null || true
    MARKED=1
  fi
done
if [ "$MARKED" -eq 1 ]; then
  echo "✓ Repo scripts marked executable"
fi

# --- Optional CLI hints ---
MISSING=""
for cmd in oc aws jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING="$MISSING $cmd"
  fi
done

echo ""
echo "=============================================="
echo "  Installation complete!"
echo "=============================================="
echo ""
echo "Start the wizard:"
echo "  ./start.sh"
echo ""
echo "Then open: http://127.0.0.1:8765"
echo ""

if [ -n "$MISSING" ]; then
  echo "Note — these optional tools are not on PATH:$MISSING"
  echo "Install them before deploying to a cluster."
  echo ""
fi
