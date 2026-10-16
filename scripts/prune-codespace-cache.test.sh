#!/usr/bin/env bash
# Both directions: the prune must find work when versions have piled up, and must
# find none when they have not. A check that can only say OK is a constant.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ck() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi }

# 1. Piled up: 5 versions, version-sorted so 1.0.9 < 1.0.10 (lexical sort gets this wrong).
R=$T/piled; mkdir -p $R
for v in 1.0.9 1.0.10 1.0.8 1.0.11 1.0.12; do mkdir -p "$R/$v"; dd if=/dev/zero of="$R/$v/blob" bs=1M count=2 status=none; done
out=$(PRUNE_CACHE_ROOTS="$R" bash scripts/prune-codespace-cache.sh)
ck "reports 5 found"      "$(echo "$out" | grep -c '5 version(s), pruning 3')" "1"
ck "keeps the two newest" "$(echo "$out" | grep -c 'keeping 1.0.11 1.0.12')"   "1"
ck "dry run deletes nothing" "$(ls -1 $R | wc -l | tr -d ' ')" "5"

# 2. --apply really deletes, and leaves exactly the keep-set.
PRUNE_CACHE_ROOTS="$R" bash scripts/prune-codespace-cache.sh --apply >/dev/null
ck "apply left 2"         "$(ls -1 $R | wc -l | tr -d ' ')" "2"
ck "apply kept newest"    "$(ls -1 $R | sort -V | tr '\n' ' ')" "1.0.11 1.0.12 "

# 3. Nothing to do: already at the keep count.
out=$(PRUNE_CACHE_ROOTS="$R" bash scripts/prune-codespace-cache.sh)
ck "reports OK when clean" "$(echo "$out" | grep -c 'nothing to prune')" "1"

# 4. Absent cache is not a failure.
out=$(PRUNE_CACHE_ROOTS="$T/nope" bash scripts/prune-codespace-cache.sh)
ck "absent root skips"     "$(echo "$out" | grep -c 'not present')" "1"

[ "$fail" = "0" ] && echo "prune-codespace-cache: all pass" || echo "prune-codespace-cache: FAILURES"
exit $fail
