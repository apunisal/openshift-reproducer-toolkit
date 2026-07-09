#!/usr/bin/env bash
# Stop the local wizard server
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PORT="8765"
KILLED=false

if [ -f .server.pid ]; then
  PID=$(cat .server.pid)
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null && KILLED=true
    echo "Stopped server (PID $PID)"
  fi
  rm -f .server.pid
fi

# Also kill anything still bound to the port (including stale root-level servers)
if command -v lsof >/dev/null 2>&1; then
  for PID in $(lsof -ti:"$PORT" 2>/dev/null || true); do
    kill "$PID" 2>/dev/null && KILLED=true && echo "Stopped process on port $PORT (PID $PID)"
  done
fi

# Stale pid from before application/ folder move (repo root)
STALE_PID_FILE="$(cd "$ROOT/.." && pwd)/.server.pid"
if [ -f "$STALE_PID_FILE" ]; then
  PID=$(cat "$STALE_PID_FILE" 2>/dev/null || true)
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null && KILLED=true && echo "Stopped stale server (PID $PID)"
  fi
  rm -f "$STALE_PID_FILE"
fi

if [ "$KILLED" = false ]; then
  echo "No server running on port $PORT."
fi
