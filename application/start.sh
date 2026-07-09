#!/usr/bin/env bash
# OCP Reproducer Toolkit — start local wizard (macOS + Linux)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

HOST="127.0.0.1"
PORT="8765"
URL="http://${HOST}:${PORT}"
LOG_FILE="${ROOT}/.server.log"
CLEANED_UP=0

if [ ! -d ".venv" ]; then
  echo "Virtual environment not found. Run ./install.sh first."
  exit 1
fi

# shellcheck disable=SC1091
source .venv/bin/activate

cleanup() {
  if [ "$CLEANED_UP" -eq 1 ]; then
    return 0
  fi
  CLEANED_UP=1
  echo ""
  echo "Stopping server…"
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f .server.pid
}

trap 'cleanup; exit 0' INT TERM

# If something is already on the port, tell the user how to stop it
if curl -sf "${URL}/api/health" >/dev/null 2>&1; then
  OLD_PID=""
  if [ -f .server.pid ]; then OLD_PID=$(cat .server.pid 2>/dev/null || true); fi
  echo "Server is already running at ${URL}"
  [ -n "$OLD_PID" ] && echo "  PID: $OLD_PID"
  echo ""
  echo "To stop it, run:  ./stop.sh"
  echo "Or:              lsof -ti:${PORT} | xargs kill"
  echo ""
  echo "Opening browser…"
  if command -v open >/dev/null 2>&1; then
    open "$URL"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" >/dev/null 2>&1 || true
  fi
  exit 0
fi

echo "Starting OCP Reproducer Toolkit…"

# Run server in background; logs go to file so terminal stays clean
python3 -m uvicorn app.main:app --host "$HOST" --port "$PORT" --log-level info \
  >"$LOG_FILE" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > .server.pid

# Wait until healthy
for _ in $(seq 1 30); do
  if curl -sf "${URL}/api/health" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Server failed to start. See ${LOG_FILE}"
    tail -20 "$LOG_FILE" 2>/dev/null || true
    rm -f .server.pid
    exit 1
  fi
  sleep 0.5
done

if ! curl -sf "${URL}/api/health" >/dev/null 2>&1; then
  echo "Server did not become ready in time. See ${LOG_FILE}"
  cleanup
  exit 1
fi

# Open browser
if command -v open >/dev/null 2>&1; then
  open "$URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$URL" >/dev/null 2>&1 || true
fi

echo ""
echo "=============================================="
echo "  Wizard ready:  ${URL}"
echo "  Server logs:    ${LOG_FILE}"
echo "=============================================="
echo ""
printf "To stop server, say \`stop\` or press ^C: "

# Interactive loop — type 'stop' or Ctrl+C to quit
while kill -0 "$SERVER_PID" 2>/dev/null; do
  if ! read -r cmd; then
    cleanup
    exit 0
  fi
  case "$(echo "$cmd" | tr '[:upper:]' '[:lower:]')" in
    stop|quit|exit)
      cleanup
      echo "Server stopped."
      exit 0
      ;;
    "")
      printf "To stop server, say \`stop\` or press ^C: "
      ;;
    *)
      echo "Unknown command. To stop server, say 'stop' or press ^C."
      printf "To stop server, say \`stop\` or press ^C: "
      ;;
  esac
done

cleanup
echo "Server stopped."
