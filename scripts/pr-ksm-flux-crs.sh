#!/usr/bin/env bash
# INFRA-1657, second half — make the Flux alert rules capable of firing.
#
# The PodMonitor was necessary and not sufficient: gotk_reconcile_condition does
# not exist in this Flux version (verified 2026-08-24 by reading /metrics on
# kustomize-controller — the only gotk reconcile metric is
# gotk_reconcile_duration_seconds). This configures kube-state-metrics
# CustomResourceState to emit gotk_resource_info, and repoints the three rules.
#
# TWO FILES ARE MODIFIED, not added, so unlike pr-flux-podmonitor.sh this cannot
# refuse-to-overwrite its way to safety. Instead every edit is ANCHORED and the
# anchor is asserted to appear EXACTLY ONCE before the edit is made. A branch
# whose anchors do not match is skipped, loudly, rather than edited by guesswork.
#
# BUILT FROM THE BRANCH (CLAUDE.md rule 7). Prints git diff origin/<branch> in
# full and pushes nothing without --push.
#
#   scripts/pr-ksm-flux-crs.sh                 # build + show diffs
#   scripts/pr-ksm-flux-crs.sh --push          # push and open PRs
#   scripts/pr-ksm-flux-crs.sh --push --only op-dev
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
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wip/observability/platform/prometheus/ksm-flux-crs-values.yaml"
BRANCHES="${ONLY:-op-dev op-qa op-prod}"
TOPIC="infra-1657-ksm-flux-crs"

[ -f "$SRC" ] || { echo "!! values source not found: $SRC" >&2; exit 2; }
command -v gh >/dev/null || { echo "!! gh CLI not on PATH" >&2; exit 2; }
[ -d "$WORK/.git" ] || { echo "!! no checkout at $WORK" >&2; exit 2; }
cd "$WORK" || exit 2
git fetch -q origin || { echo "!! git fetch failed" >&2; exit 2; }

echo "repo:   $WORK"
echo "values: $SRC"
echo "push:   $PUSH"

FAILED=0
for B in $BRANCHES; do
  echo
  echo "==================== $B ===================="
  git rev-parse --verify -q "origin/$B" >/dev/null || { echo "!! no origin/$B"; FAILED=1; continue; }
  git checkout -q -B "$TOPIC-$B" "origin/$B" || { echo "!! checkout failed"; FAILED=1; continue; }

  HR=$(git ls-tree -r --name-only HEAD | grep -E 'prometheus[^/]*/helmrelease\.yaml$' | head -1)
  AL=$(git ls-tree -r --name-only HEAD | grep -E 'platform-alerts\.yaml$' | head -1)
  if [ -z "$HR" ] || [ -z "$AL" ]; then
    echo "!! could not locate helmrelease.yaml and/or platform-alerts.yaml on $B. SKIPPING."
    FAILED=1; continue
  fi
  echo "helmrelease:     $HR"
  echo "platform-alerts: $AL"

  if ! python3 - "$HR" "$AL" "$SRC" <<'PY'
import re, sys
hr_path, al_path, src_path = sys.argv[1], sys.argv[2], sys.argv[3]

def die(msg):
    print(f"!! {msg}", file=sys.stderr); sys.exit(1)

hr = open(hr_path, encoding="utf-8").read()

if "kube-state-metrics:" in hr:
    die("helmrelease.yaml already carries a kube-state-metrics: block — refusing to edit")

# Anchor: the kubeStateMetrics toggle. Must appear exactly once, or we are not
# looking at the file we think we are.
anchor = "    kubeStateMetrics:\n      enabled: true\n"
n = hr.count(anchor)
if n != 1:
    die(f"anchor 'kubeStateMetrics: enabled: true' appears {n} times, expected exactly 1")

block = open(src_path, encoding="utf-8").read()
# Strip the file's own leading comment header — it explains the file, not the
# values — and keep the rest, re-indented to sit under `values:` (4 spaces).
lines = block.splitlines()
start = next(i for i, l in enumerate(lines) if l.startswith("kube-state-metrics:"))
body = "\n".join(("    " + l) if l.strip() else "" for l in lines[start:])
hr = hr.replace(anchor, anchor + "\n" + body.rstrip() + "\n", 1)
open(hr_path, "w", encoding="utf-8").write(hr)

# --- the three rule expressions -------------------------------------------
al = open(al_path, encoding="utf-8").read()
repl = [
 ('gotk_reconcile_condition{type="Ready", status="False", kind="Kustomization"} == 1',
  'gotk_resource_info{customresource_kind="Kustomization", ready="False", suspended!="true"} == 1'),
 ('gotk_reconcile_condition{type="Ready", status="False", kind="HelmRelease"} == 1',
  'gotk_resource_info{customresource_kind="HelmRelease", ready="False", suspended!="true"} == 1'),
 ('gotk_reconcile_condition{type="Ready", status="False", kind="GitRepository"} == 1',
  'gotk_resource_info{customresource_kind="GitRepository", ready="False", suspended!="true"} == 1'),
]
for old, new in repl:
    c = al.count(old)
    if c != 1:
        die(f"rule expression appears {c} times, expected exactly 1:\n     {old}")
    al = al.replace(old, new, 1)

if "gotk_reconcile_condition" in al:
    die("a gotk_reconcile_condition reference survived — the file has a form this script does not handle")

note = ("""# ⚠️ 2026-08-24: the Flux rules below no longer use gotk_reconcile_condition.
# That metric DOES NOT EXIST in the Flux version running on these clusters —
# the controllers expose only gotk_reconcile_duration_seconds. The rules had
# therefore never been able to fire since INFRA-1503, and did not fire when
# flux-system/risingwave and flux-system/wiz-sensor sat Ready=False for six
# days. They now key on gotk_resource_info, emitted by kube-state-metrics
# CustomResourceState (configured in helmrelease.yaml). INFRA-1657.
""")
if "gotk_resource_info" in al and note not in al:
    al = al.replace("apiVersion: monitoring.coreos.com/v1", note + "apiVersion: monitoring.coreos.com/v1", 1)
open(al_path, "w", encoding="utf-8").write(al)
print("   edits applied: helmrelease values block + 3 rule expressions")
PY
  then
    echo "!! anchored edit failed on $B — nothing changed. SKIPPING."
    git checkout -q -- . ; FAILED=1; continue
  fi

  # Does it still parse and build?
  if ! python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1]))); list(yaml.safe_load_all(open(sys.argv[2])))" "$HR" "$AL" 2>/dev/null; then
    echo "!! YAML no longer parses on $B. SKIPPING."
    git checkout -q -- . ; FAILED=1; continue
  fi
  echo "   yaml parses: ok"
  DIR=$(dirname "$AL")
  if command -v kubectl >/dev/null && ! kubectl kustomize "$DIR" >/dev/null 2>&1; then
    echo "!! kubectl kustomize $DIR FAILED on $B. SKIPPING."
    git checkout -q -- . ; FAILED=1; continue
  fi
  echo "   kustomize build: ok"

  git add -A
  git commit -q -m "INFRA-1657: emit gotk_resource_info via kube-state-metrics, and repoint the Flux rules

The PodMonitor was necessary and not sufficient. gotk_reconcile_condition does
not exist in the Flux version running here -- kustomize-controller's /metrics
exposes only gotk_reconcile_duration_seconds (read directly, 2026-08-24). The
PodMonitor produces four healthy targets and still zero series for it.

So the three Flux rules from INFRA-1503 could never have fired, and did not fire
while flux-system/risingwave and flux-system/wiz-sensor sat Ready=False for six
days.

Configures kube-state-metrics CustomResourceState to emit gotk_resource_info for
Kustomization, HelmRelease and GitRepository, and repoints the rules at it.

The rbac.extraRules are load-bearing: kube-state-metrics' ClusterRole lists only
core resources today, with no *.toolkit.fluxcd.io group. Without them the config
mounts, the container starts, and it exports nothing, silently." || echo "   nothing to commit"

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
        --title "INFRA-1657: emit gotk_resource_info via kube-state-metrics, repoint the Flux rules" \
        --body "Second half of INFRA-1657. The PodMonitor (#114/#115/#116) was necessary and **not sufficient**.

\`gotk_reconcile_condition\` **does not exist** in the Flux version running on these clusters. Read directly from \`kustomize-controller\`'s \`/metrics\` on op-usxpress-dev, 2026-08-24, the only gotk reconcile metric is:

\`\`\`
# HELP gotk_reconcile_duration_seconds  The duration in seconds of a GitOps Toolkit resource reconciliation.
\`\`\`

The PodMonitor produces **four healthy targets, all \`up\`, no errors** — and still zero series for the metric the rules need. A working scrape of a metric that is never emitted looks exactly like no scrape at all.

So \`FluxKustomizationFailed\`, \`FluxHelmReleaseFailed\` and \`FluxGitRepositoryFailed\` have never been able to fire since INFRA-1503, and did not fire while \`flux-system/risingwave\` and \`flux-system/wiz-sensor\` sat \`Ready=False\` for six days.

**This PR** configures kube-state-metrics CustomResourceState to emit \`gotk_resource_info\` for Kustomization, HelmRelease and GitRepository, and repoints the three rules at it.

**\`rbac.extraRules\` is load-bearing.** kube-state-metrics' ClusterRole lists only core resources today — verified, no \`*.toolkit.fluxcd.io\` group at all. Without those rules the ConfigMap mounts, the container starts happily, and it exports nothing.

**Verify after merge**, and not by series count alone — \`risingwave\` and \`wiz-sensor\` are still \`Ready=False\`, so the alert should go red on its own:
\`\`\`
kubectl -n prometheus port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090 &
curl -s --get --data-urlencode 'query=gotk_resource_info' localhost:9090/api/v1/query | jq '.data.result | length'
curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname|startswith(\"Flux\")) | \"\(.state) \(.labels.alertname) \(.labels.name)\"'
\`\`\`

Same mechanism is what \`CiliumNodeCountDivergence\` needs — it references \`kube_customresource_cilium_io_v2_ciliumnode_info\` and no CustomResourceState config existed anywhere, so it is dead for the same reason.

Alerts still reach nobody until INFRA-1659; there is no Alertmanager." \
        || echo "   !! gh pr create failed for $B"
    else
      echo "   !! push failed for $B"; FAILED=1
    fi
  fi
done

git checkout -q - 2>/dev/null
echo
[ "$PUSH" = "yes" ] || echo "Nothing pushed. Read the diffs, then re-run with --push."
[ "$FAILED" -eq 0 ] || { echo "One or more branches were skipped — see above."; exit 1; }
