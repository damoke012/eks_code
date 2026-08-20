#!/usr/bin/env bash
# Back up everything that lives OUTSIDE the repo and is destroyed by a codespace rebuild:
# the memory directory, user-scope skills, the router, and settings.json.
# /home is NOT a mounted volume. Memory is the half you cannot reinstall.
set -uo pipefail
cd "$(dirname "$0")/.."
DEST=".claude-env"
SRC="$HOME/.claude"
mkdir -p "$DEST"

# settings.json, minus anything secret-shaped — never commit a credential.
if [ -f "$SRC/settings.json" ]; then
  python3 - "$SRC/settings.json" "$DEST/settings.json" <<'PY'
import json, re, sys
src, dst = sys.argv[1], sys.argv[2]
SECRET = re.compile(r'(ATATT[0-9A-Za-z]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|lsv2_[a-z]{2}_[0-9a-f]{32})')
d = json.load(open(src))
allow = d.get("permissions", {}).get("allow", [])
d.setdefault("permissions", {})["allow"] = [a for a in allow if not SECRET.search(a)]
dropped = len(allow) - len(d["permissions"]["allow"])
json.dump(d, open(dst, "w"), indent=2)
print(f"  settings.json backed up ({dropped} secret-bearing entr(y/ies) redacted)")
PY
fi

for d in skills skills-router; do
  [ -d "$SRC/$d" ] && { rm -rf "${DEST:?}/$d"; cp -r "$SRC/$d" "$DEST/$d"; echo "  $d backed up"; }
done

MEM="$SRC/projects/-workspaces-eks-code/memory"
if [ -d "$MEM" ]; then
  rm -rf "$DEST/memory"; cp -r "$MEM" "$DEST/memory"
  echo "  memory backed up ($(ls "$MEM" | wc -l) files)"
fi
echo "  -> $DEST (commit it; this is what a rebuild restores from)"
