#!/usr/bin/env bash
# Restore what a codespace rebuild destroyed. Safe to run repeatedly; never overwrites a
# newer settings.json, only fills in what is missing.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=".claude-env"
DEST="$HOME/.claude"
[ -d "$SRC" ] || { echo "  no $SRC — nothing to restore"; exit 0; }
mkdir -p "$DEST"

for d in skills skills-router; do
  [ -d "$SRC/$d" ] && [ ! -d "$DEST/$d" ] && { cp -r "$SRC/$d" "$DEST/$d"; echo "  $d restored"; }
done
[ -f "$SRC/settings.json" ] && [ ! -f "$DEST/settings.json" ] && \
  { cp "$SRC/settings.json" "$DEST/settings.json"; echo "  settings.json restored"; }

MEM="$DEST/projects/-workspaces-eks-code/memory"
if [ -d "$SRC/memory" ] && [ ! -d "$MEM" ]; then
  mkdir -p "$(dirname "$MEM")"; cp -r "$SRC/memory" "$MEM"
  echo "  memory restored ($(ls "$SRC/memory" | wc -l) files)"
fi
chmod +x "$DEST/skills-router/inject.sh" 2>/dev/null
echo "  claude env restored"
