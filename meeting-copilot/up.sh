#!/usr/bin/env bash
# Start Meeting Copilot in the background (safe to run twice) and print the URL to open.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$HERE/.." && pwd)}"
CONF="$PROJECT_DIR/.meeting-copilot/config.env"
# Load config.env; variables already set in the environment win (handy for one-off overrides).
if [ -f "$CONF" ]; then
  while IFS='=' read -r k v; do
    k="${k//[[:space:]]/}"
    [[ -z "$k" || "$k" == \#* ]] && continue
    v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"
    [ -z "${!k+x}" ] && export "$k=$v"
  done < "$CONF"
fi
PORT="${PORT:-8765}"
LOG="$PROJECT_DIR/.meeting-copilot/server.log"
mkdir -p "$PROJECT_DIR/.meeting-copilot"

if curl -sf "localhost:$PORT/api/health" >/dev/null 2>&1; then
  echo "Meeting Copilot is already running."
else
  echo "Starting Meeting Copilot (first start downloads the Whisper model, ~1 min)..."
  nohup "$HERE/start.sh" >"$LOG" 2>&1 &
  echo $! >"$PROJECT_DIR/.meeting-copilot/server.pid"
  for i in $(seq 1 180); do
    if curl -sf "localhost:$PORT/api/health" >/dev/null 2>&1; then break; fi
    if ! kill -0 "$(cat "$PROJECT_DIR/.meeting-copilot/server.pid")" 2>/dev/null; then
      echo "Server exited during startup. Last log lines:"; tail -20 "$LOG"; exit 1
    fi
    sleep 1
  done
fi

curl -s "localhost:$PORT/api/health"; echo
if [ -n "${CODESPACE_NAME:-}" ]; then
  echo "Open in Chrome: https://${CODESPACE_NAME}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}/"
  echo "(Port must be Private. Check the Ports panel.)"
else
  echo "Open in Chrome: http://localhost:$PORT/"
fi
