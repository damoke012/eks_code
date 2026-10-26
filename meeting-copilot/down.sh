#!/usr/bin/env bash
# Stop Meeting Copilot.
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$HERE/.." && pwd)}"
PIDF="$PROJECT_DIR/.meeting-copilot/server.pid"
if [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; then
  rm -f "$PIDF"; echo "Meeting Copilot stopped."
else
  pkill -f "uvicorn server:app --host 0.0.0.0" 2>/dev/null && echo "Meeting Copilot stopped." || echo "Meeting Copilot was not running."
fi
