#!/usr/bin/env bash
# Start Meeting Copilot. Settings come from .meeting-copilot/config.env in the project repo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PROJECT_DIR="${PROJECT_DIR:-$(cd "$HERE/.." && pwd)}"
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
cd "$HERE"
echo "Meeting Copilot for $(basename "$PROJECT_DIR") on port $PORT"
exec python3 -m uvicorn server:app --host 0.0.0.0 --port "$PORT" --log-level warning
