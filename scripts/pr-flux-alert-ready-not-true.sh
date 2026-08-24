#!/usr/bin/env bash
# INFRA-1657, third part — match ready!="True" instead of ready="False".
#
# WHY, measured on op-usxpress-dev 2026-08-24 15:57 UTC:
#
#   gotk_resource_info{name="risingwave"} over 60 minutes
#     ready="True"      0 samples
#     ready="False"    59 samples
#     ready="Unknown"  61 samples
#
#   kube-state-metrics is scraped every 30s, so ONE series yields 120 samples
#   an hour. False + Unknown = exactly 120. That is a single object alternating
#   between the two on roughly every other scrape, and never True at any point.
#
#   flux-system/risingwave's health check times out after 5m and re-runs. While
#   it runs, Ready goes Unknown; on timeout it goes back to False. Under
#   ready="False" the series disappears on every flip, the alert's activeAt
#   resets, and the 10-minute `for:` window NEVER completes. It sat `pending`
#   for over an hour on a Kustomization that had been broken for six days.
#
#   wiz-sensor fires correctly because it is STALLED — its condition sits
#   still. So the rule as shipped works for stalled failures and silently fails
#   for cycling ones, which is what a timing-out health check produces. Having
#   one of the two fire is exactly what would have let us call this done.
#
# ready!="True" matches both False and Unknown, so the series stays continuous
# across the flip and the window completes.
#
# BUILT FROM THE BRANCH (CLAUDE.md rule 7). Anchored edits, each anchor asserted
# to appear exactly once. Prints the full diff; pushes nothing without --push.
#
#   scripts/pr-flux-alert-ready-not-true.sh --only op-dev
#   scripts/pr-flux-alert-ready-not-true.sh --only op-dev --push
set -uo pipefail

PUSH=no; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=yes; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

WORK="${WORK:-$HOME/pr-work/iaac-talos-flux-platform}"
BRANCHES="${ONLY:-op-dev op-qa op-prod}"
TOPIC="infra-1657-ready-not-true"

command -v gh >/dev/null || { echo "!! gh CLI not on PATH" >&2; exit 2; }
[ -d "$WORK/.git" ] || { echo "!! no checkout at $WORK" >&2; exit 2; }
cd "$WORK" || exit 2
git fetch -q origin || { echo "!! git fetch failed" >&2; exit 2; }
echo "repo: $WORK   push: $PUSH"

FAILED=0
for B in $BRANCHES; do
  echo
  echo "==================== $B ===================="
  git rev-parse --verify -q "origin/$B" >/dev/null || { echo "!! no origin/$B"; FAILED=1; continue; }
  git checkout -q -B "$TOPIC-$B" "origin/$B" || { echo "!! checkout failed"; FAILED=1; continue; }

  AL=$(git ls-tree -r --name-only HEAD | grep -E 'platform-alerts\.yaml$' | head -1)
  [ -n "$AL" ] || { echo "!! platform-alerts.yaml not found. SKIPPING."; FAILED=1; continue; }
  echo "platform-alerts: $AL"

  if ! python3 - "$AL" <<'PY'
import sys
p = sys.argv[1]
al = open(p, encoding="utf-8").read()

def die(m):
    print(f"!! {m}", file=sys.stderr); sys.exit(1)

if 'gotk_reconcile_condition' in al:
    die("this branch still has gotk_reconcile_condition — run pr-ksm-flux-crs.sh first")

pairs = []
for kind in ("Kustomization", "HelmRelease", "GitRepository"):
    old = f'gotk_resource_info{{customresource_kind="{kind}", ready="False", suspended!="true"}} == 1'
    new = f'gotk_resource_info{{customresource_kind="{kind}", ready!="True", suspended!="true"}} == 1'
    pairs.append((old, new))

for old, _ in pairs:
    n = al.count(old)
    if n != 1:
        die(f"expression appears {n} times, expected exactly 1:\n     {old}")

for old, new in pairs:
    al = al.replace(old, new, 1)

note = ('# ⚠️ 2026-08-24, second correction: the Flux rules match ready!="True", NOT\n'
        '# ready="False". A Kustomization whose health check times out cycles Ready\n'
        '# between False and Unknown on roughly every scrape. Measured on op-dev over\n'
        '# 60 minutes for flux-system/risingwave: True 0 samples, False 59, Unknown 61\n'
        '# — one object alternating, never True. Under ready="False" the series breaks\n'
        '# on every flip, activeAt resets, and the 10m window never completes: it sat\n'
        '# `pending` for over an hour on something broken for six days. wiz-sensor\n'
        '# fired correctly only because it is STALLED and its condition sits still.\n'
        '# ready!="True" covers False and Unknown and stays continuous. INFRA-1657.\n')
if note not in al:
    al = al.replace("apiVersion: monitoring.coreos.com/v1", note + "apiVersion: monitoring.coreos.com/v1", 1)

open(p, "w", encoding="utf-8").write(al)
print("   3 rule expressions updated to ready!=\"True\"")
PY
  then
    echo "!! anchored edit failed on $B — nothing changed. SKIPPING."
    git checkout -q -- . ; FAILED=1; continue
  fi

  python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$AL" 2>/dev/null \
    || { echo "!! YAML no longer parses. SKIPPING."; git checkout -q -- . ; FAILED=1; continue; }
  echo "   yaml parses: ok"

  git add -A
  git commit -q -m "INFRA-1657: match ready!=\"True\", not ready=\"False\"

A Kustomization whose health check times out cycles Ready between False and
Unknown on roughly every scrape. Measured on op-usxpress-dev over 60 minutes for
flux-system/risingwave: True 0 samples, False 59, Unknown 61. kube-state-metrics
is scraped every 30s so one series is 120 samples an hour -- False plus Unknown
is exactly 120, one object alternating, never True.

Under ready=\"False\" the series disappears on every flip, the alert's activeAt
resets, and the 10-minute window never completes. FluxKustomizationFailed sat
'pending' for over an hour on a Kustomization broken for six days.

wiz-sensor fired correctly only because it is stalled and its condition sits
still. The rule as shipped worked for stalled failures and silently failed for
cycling ones -- and one of the two firing is exactly what would have let us call
this finished." || echo "   nothing to commit"

  echo
  echo "-------- git diff origin/$B --------"
  git --no-pager diff "origin/$B"
  echo "-------- end diff for $B --------"

  if [ "$PUSH" = "yes" ]; then
    if git push -q -u origin "$TOPIC-$B"; then
      gh pr create --repo variant-inc/iaac-talos-flux-platform \
        --base "$B" --head "$TOPIC-$B" \
        --title "INFRA-1657: match ready!=\"True\" so cycling failures also alert" \
        --body "Third and final part of INFRA-1657.

Measured on op-usxpress-dev, \`gotk_resource_info{name=\"risingwave\"}\` over 60 minutes:

| ready | samples |
|---|---|
| True | **0** |
| False | 59 |
| Unknown | 61 |

kube-state-metrics is scraped every 30s, so one series yields **120 samples an hour**. False + Unknown = exactly 120 — a single object alternating between them on roughly every other scrape, never \`True\`.

\`flux-system/risingwave\`'s health check times out after 5m and re-runs; Ready goes \`Unknown\` while it runs and back to \`False\` on timeout. Under \`ready=\"False\"\` the series breaks on every flip, \`activeAt\` resets, and the 10-minute \`for:\` window never completes — the alert sat **\`pending\` for over an hour** on a Kustomization that had been broken for six days.

\`wiz-sensor\` fires correctly only because it is **stalled**, so its condition sits still. The rule as shipped works for stalled failures and silently fails for cycling ones — which is what a timing-out health check produces.

\`ready!=\"True\"\` matches both \`False\` and \`Unknown\`, keeping the series continuous.

**Verify:** \`FluxKustomizationFailed\` for \`risingwave\` should move \`pending\` → \`firing\` and stay there." \
        || echo "   !! gh pr create failed for $B"
    else
      echo "   !! push failed for $B"; FAILED=1
    fi
  fi
done

git checkout -q - 2>/dev/null
echo
[ "$PUSH" = "yes" ] || echo "Nothing pushed. Read the diffs, then re-run with --push."
[ "$FAILED" -eq 0 ] || { echo "One or more branches were skipped."; exit 1; }
