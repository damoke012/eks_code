#!/usr/bin/env bash
# INFRA-1657 — ship the flux-system PodMonitor to op-dev, op-qa and op-prod.
#
# Every Flux alert rule on-prem is permanently inactive because nothing scrapes
# flux-system: gotk_reconcile_condition has 0 series. This adds the PodMonitor
# that makes them capable of firing.
#
# BUILT FROM THE BRANCH, per CLAUDE.md rule 7. On 2026-08-20 a PR assembled by
# copying a stale wip/ file over a cluster branch silently reverted an
# ApplicationSet's Git URL and broke op-qa delivery for 18 hours with every
# status field green. So this script:
#
#   * starts each branch from origin/<branch>, never from a working tree;
#   * REFUSES to overwrite an existing file — it only adds a new one, and
#     appends one line to the kustomization;
#   * DISCOVERS where PrometheusRules live on each branch rather than assuming
#     the path is the same (op-qa has a prometheus-rules Kustomization op-dev
#     does not, so the layouts are known to differ);
#   * prints `git diff origin/<branch>` IN FULL and stops. Nothing is pushed
#     without --push, and you are expected to read the diff first — including
#     the lines you did not mean to change.
#
#   scripts/pr-flux-podmonitor.sh              # build + show diffs, push nothing
#   scripts/pr-flux-podmonitor.sh --push       # push and open PRs
#
# Run from a WSL checkout with corporate GitHub Enterprise access.
set -uo pipefail

PUSH=no
[ "${1:-}" = "--push" ] && PUSH=yes

REPO_SSH="https://github.com/variant-inc/iaac-talos-flux-platform"
WORK="${WORK:-$HOME/pr-work/iaac-talos-flux-platform}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wip/observability/platform/prometheus/flux-podmonitor.yaml"
FILE="flux-podmonitor.yaml"
BRANCHES="op-dev op-qa op-prod"
TOPIC="infra-1657-flux-podmonitor"

[ -f "$SRC" ] || { echo "!! source manifest not found: $SRC" >&2; exit 2; }
command -v gh >/dev/null || { echo "!! gh CLI not on PATH" >&2; exit 2; }
[ -d "$WORK/.git" ] || { echo "!! no checkout at $WORK — clone $REPO_SSH there first" >&2; exit 2; }
cd "$WORK" || exit 2

echo "repo:   $WORK"
echo "source: $SRC"
echo "push:   $PUSH"
git fetch -q origin || { echo "!! git fetch failed" >&2; exit 2; }

FAILED=0
for B in $BRANCHES; do
  echo
  echo "==================== $B ===================="
  git rev-parse --verify -q "origin/$B" >/dev/null || { echo "!! no origin/$B"; FAILED=1; continue; }

  git checkout -q -B "$TOPIC-$B" "origin/$B" || { echo "!! checkout failed"; FAILED=1; continue; }

  # Where do PrometheusRules live on THIS branch? Do not assume dev's layout.
  DIR=$(git ls-tree -r --name-only HEAD | grep -E 'platform-alerts\.yaml$' | head -1)
  if [ -z "$DIR" ]; then
    echo "!! platform-alerts.yaml not found on $B — cannot place the PodMonitor. SKIPPING."
    FAILED=1; continue
  fi
  DIR=$(dirname "$DIR")
  KUST="$DIR/kustomization.yaml"
  echo "rules live in: $DIR"
  [ -f "$KUST" ] || { echo "!! no $KUST on $B. SKIPPING."; FAILED=1; continue; }

  # Never overwrite. Adding a new file is safe; replacing one is how #100 happened.
  if [ -e "$DIR/$FILE" ]; then
    echo "!! $DIR/$FILE already exists on $B — refusing to overwrite. SKIPPING."
    FAILED=1; continue
  fi
  cp "$SRC" "$DIR/$FILE"

  # Append to the kustomization only if it is not already listed.
  if grep -qE "^- *$FILE$|^ *- *$FILE$" "$KUST"; then
    echo "   $FILE already in $KUST"
  else
    printf -- "- %s\n" "$FILE" >> "$KUST"
  fi

  # The selector label is what makes this work at all. Assert it survived the copy.
  if ! grep -q "release: prometheus-stack" "$DIR/$FILE"; then
    echo "!! the release: prometheus-stack label is missing — the PodMonitor would"
    echo "   apply cleanly, report Ready=True, and never be selected. SKIPPING."
    git checkout -q -- . ; FAILED=1; continue
  fi

  # Does it still parse, and does the kustomization still build?
  if command -v kustomize >/dev/null; then
    if ! kustomize build "$DIR" >/dev/null 2>&1; then
      echo "!! kustomize build $DIR FAILED on $B. SKIPPING."
      git checkout -q -- . ; FAILED=1; continue
    fi
    echo "   kustomize build: ok"
  elif command -v kubectl >/dev/null; then
    if ! kubectl kustomize "$DIR" >/dev/null 2>&1; then
      echo "!! kubectl kustomize $DIR FAILED on $B. SKIPPING."
      git checkout -q -- . ; FAILED=1; continue
    fi
    echo "   kubectl kustomize: ok"
  else
    echo "   (no kustomize or kubectl — build NOT verified on this branch)"
  fi

  git add -A "$DIR"
  git -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
      commit -q -m "INFRA-1657: scrape flux-system so the Flux alert rules can fire

platform-alerts.yaml has shipped FluxKustomizationFailed, FluxHelmReleaseFailed
and FluxGitRepositoryFailed since INFRA-1503. All three key on
gotk_reconcile_condition. On op-usxpress-dev, 2026-08-21:

  gotk_reconcile_condition series:  0
  flux-system scrape targets:       0

Nothing has ever scraped flux-system, so all three rules are permanently
inactive. flux-system/risingwave and flux-system/wiz-sensor held Ready=False for
2 days 18 hours and none of them fired.

The release: prometheus-stack label is load-bearing: kube-prometheus-stack sets
podMonitorSelectorNilUsesHelmValues, so without it this object applies cleanly,
reports Ready=True, and is never selected." || { echo "   nothing to commit"; }

  echo
  echo "-------- git diff origin/$B  (READ THIS IN FULL) --------"
  git --no-pager diff "origin/$B" --stat
  echo
  git --no-pager diff "origin/$B"
  echo "-------- end diff for $B --------"

  if [ "$PUSH" = "yes" ]; then
    if git push -q -u origin "$TOPIC-$B"; then
      gh pr create --repo variant-inc/iaac-talos-flux-platform \
        --base "$B" --head "$TOPIC-$B" \
        --title "INFRA-1657: scrape flux-system so the Flux alert rules can fire" \
        --body "Adds a PodMonitor for the Flux controllers.

\`gotk_reconcile_condition\` has **0 series** on op-usxpress-dev and \`flux-system\` has **0 scrape targets**, so \`FluxKustomizationFailed\`, \`FluxHelmReleaseFailed\` and \`FluxGitRepositoryFailed\` — shipped in \`platform-alerts.yaml\` since INFRA-1503 — have never been able to fire. \`flux-system/risingwave\` and \`flux-system/wiz-sensor\` sat \`Ready=False\` for 2d18h and none of them fired.

A PrometheusRule selecting a metric that is never ingested is valid, healthy, permanently \`inactive\` and dead. Nothing in the stack reports it.

**The \`release: prometheus-stack\` label is load-bearing.** kube-prometheus-stack sets \`podMonitorSelectorNilUsesHelmValues: true\`, so the Prometheus CR selects PodMonitors by that label — the same convention \`platform-alerts.yaml\` documents for \`ruleSelector\`. Without it this applies cleanly, goes \`Ready=True\`, and is never selected: this PR's own failure mode.

**Verify after merge**, and not by series count alone:
\`\`\`
scripts/check-alert-delivery.sh --context <ctx>
\`\`\`
then make a Kustomization fail deliberately on dev and watch \`FluxKustomizationFailed\` reach \`firing\`. A rule never seen to go red is not a rule to trust.

Note: alerts still reach nobody until INFRA-1659 — there is no Alertmanager. This makes the rules *capable* of firing; it does not deliver them." \
        || echo "   !! gh pr create failed for $B"
    else
      echo "   !! push failed for $B"; FAILED=1
    fi
  fi
done

git checkout -q - 2>/dev/null
echo
if [ "$PUSH" != "yes" ]; then
  echo "Nothing pushed. Read the three diffs above, then re-run with --push."
else
  echo "PRs opened. op-prod now requires an approving review (INFRA-1656) — it will"
  echo "NOT auto-merge. That is the new behaviour working, not a failure."
fi
[ "$FAILED" -eq 0 ] || { echo "One or more branches were skipped — see above."; exit 1; }
