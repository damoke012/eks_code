#!/usr/bin/env bash
# Reclaim codespace disk by pruning tool caches that keep EVERY version they download.
#
# Measured 2026-10-16: the workspace hit 90% (2.1G of 20G free) and VS Code raised a
# low-disk warning. The whole cause was ~/.cache/copilot/pkg/linux-x64 holding 27
# Copilot CLI versions (1.0.67 .. 1.0.98) at ~180M each = 4.8G, which is 28% of
# everything used. Nothing prunes them: `copilot update` adds a version and never
# removes the one it superseded. The repo itself is 74M.
#
# Safe because the cache is update STAGING, not the running code:
#   - /usr/local/bin/copilot is a standalone ELF binary, not a launcher into the cache.
#   - the live VS Code process runs @github/copilot-sdk-linux-x64 from /vscode/bin.
#   - `lsof +D` showed no open handles anywhere under pkg/.
# Keeping the two newest covers the installed version plus one rollback.
#
# Reports by default. Deletes only with --apply.
set -uo pipefail

KEEP=2
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

# version dir -> the cache root holding numbered version directories
CACHES="${PRUNE_CACHE_ROOTS:-$HOME/.cache/copilot/pkg/linux-x64}"

avail() { df -BM --output=avail / | tail -1 | tr -dc 0-9; }

before=$(avail)
total_reclaim=0

for root in $CACHES; do
  if [ ! -d "$root" ]; then
    echo "SKIP  $root - not present"
    continue
  fi
  # Version-sort, not mtime: these archives carry a fixed 1985-10-26 build timestamp,
  # so mtime cannot tell the newest from the oldest.
  mapfile -t all < <(ls -1 "$root" 2>/dev/null | sort -V)
  n=${#all[@]}
  if [ "$n" -le "$KEEP" ]; then
    echo "OK    $root - $n version(s), keeping $KEEP, nothing to prune"
    continue
  fi
  keep_from=$((n - KEEP))
  echo "$root - $n version(s), pruning $keep_from, keeping ${all[*]:$keep_from}"
  for v in "${all[@]:0:$keep_from}"; do
    sz=$(du -sxm "$root/$v" 2>/dev/null | cut -f1)
    total_reclaim=$((total_reclaim + sz))
    if [ "$APPLY" = "true" ]; then
      rm -rf "$root/$v" && echo "  deleted $v (${sz}M)"
    else
      echo "  would delete $v (${sz}M)"
    fi
  done
  [ "$APPLY" = "true" ] && rm -rf "$root/../tmp"/* 2>/dev/null
done

after=$(avail)
if [ "$APPLY" = "true" ]; then
  echo
  echo "avail before: ${before}M  after: ${after}M  freed: $((after - before))M"
  df -h / | tail -1
else
  echo
  echo "reclaimable: ${total_reclaim}M   avail now: ${before}M"
  echo "re-run with --apply to delete"
fi
