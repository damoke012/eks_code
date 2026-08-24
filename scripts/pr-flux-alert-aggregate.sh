#!/usr/bin/env bash
# INFRA-1657, fourth part — aggregate the churning labels away, and name the
# right namespace in the annotation.
#
# TWO DEFECTS, both measured on op-usxpress-dev 2026-08-24 16:30 UTC.
#
# 1. ready!="True" was necessary and NOT sufficient. Prometheus identifies an
#    alert instance by the LABEL SET of the expression's output. `ready` is in
#    that set. So a Kustomization flapping False->Unknown still produces two
#    alternating alert instances; each disappears when the other appears, each
#    resets activeAt, and the 10m `for:` window still never completes.
#
#    Proof, on the metric itself:
#        count(count_over_time(gotk_resource_info{...,ready!="True"}[10m]) >= 20)
#          -> 1        (only wiz-sensor, which is stalled)
#        ... same query with max by (exported_namespace, name) applied first
#          -> 2        (wiz-sensor AND risingwave)
#    Two objects have been not-Ready for days. Only the aggregated form sees
#    both. `revision` churns too -- it changes on every successful apply -- so
#    it is a second reset trigger on the HelmRelease and GitRepository rules.
#
# 2. The annotations say {{ $labels.namespace }}. That is NOT the Flux object's
#    namespace. kube-state-metrics is scraped in its own namespace and the
#    ServiceMonitor stamps namespace="prometheus" onto every series it emits --
#    which is exactly why the CRS config had to call the real one
#    exported_namespace. Verified on the live series:
#        exported_namespace=flux-system     <- the Kustomization
#        namespace=prometheus               <- kube-state-metrics' own pod
#    The page would have read "Flux Kustomization prometheus/risingwave not
#    Ready" -- a correct alert naming the wrong namespace. After the max by()
#    drops `namespace` entirely it would render empty instead.
#
# Only the three Flux summaries are touched. Other rules in this file use
# {{ $labels.namespace }} correctly, because kube_pod_* carries a real one.
#
# NORMALISES FROM EITHER STARTING STATE. op-dev has ready!="True" (part three);
# op-qa and op-prod are still on ready="False". Both converge here, and the
# part-three comment is added to any branch missing it so all three files match.
#
# BUILT FROM THE BRANCH (CLAUDE.md rule 7). Anchored, each anchor asserted to
# appear exactly once. Prints the diff; pushes nothing without --push.
#
#   scripts/pr-flux-alert-aggregate.sh --only op-dev
#   scripts/pr-flux-alert-aggregate.sh --only op-dev --push
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
TOPIC="infra-1657-aggregate-labels"

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

# Guard on EXPRESSIONS, never the whole file -- the part-two comment block
# contains the string gotk_reconcile_condition to explain that it is gone, and
# a naive substring search reads that documentation as the defect it documents.
code = "\n".join(l for l in al.splitlines() if not l.lstrip().startswith("#"))
if "gotk_reconcile_condition" in code:
    die("this branch still has gotk_reconcile_condition in a rule -- run pr-ksm-flux-crs.sh first")
if "max by (customresource_kind, exported_namespace, name)" in code:
    die("this branch is already aggregated -- nothing to do")

KINDS = ("Kustomization", "HelmRelease", "GitRepository")
changed_expr = 0

for kind in KINDS:
    new = ('            max by (customresource_kind, exported_namespace, name) (\n'
           f'              gotk_resource_info{{customresource_kind="{kind}", ready!="True", suspended!="true"}}\n'
           '            ) == 1')
    # Accept either starting state: post-part-three, or the original.
    olds = [f'            gotk_resource_info{{customresource_kind="{kind}", ready!="True", suspended!="true"}} == 1',
            f'            gotk_resource_info{{customresource_kind="{kind}", ready="False", suspended!="true"}} == 1']
    hits = [o for o in olds if al.count(o) == 1]
    if len(hits) != 1:
        counts = ", ".join(f"{al.count(o)}x" for o in olds)
        die(f"{kind}: expected exactly one known expression form, found {counts}")
    al = al.replace(hits[0], new, 1); changed_expr += 1

# Annotations. Scoped by the alert's own wording so the other rules in this
# file -- which use $labels.namespace correctly -- are untouched.
changed_ann = 0
for kind in KINDS:
    old = "Flux %s {{ $labels.namespace }}/{{ $labels.name }}" % kind
    new = "Flux %s {{ $labels.exported_namespace }}/{{ $labels.name }}" % kind
    n = al.count(old)
    if n != 1:
        die(f"{kind}: summary annotation appears {n} times, expected exactly 1")
    al = al.replace(old, new, 1); changed_ann += 1

note3 = ('# 2026-08-24, second correction: the Flux rules match ready!="True", NOT\n'
         '# ready="False". A Kustomization whose health check times out cycles Ready\n'
         '# between False and Unknown on roughly every scrape. Measured on op-dev over\n'
         '# 60 minutes for flux-system/risingwave: True 0 samples, False 59, Unknown 61\n'
         '# -- one object alternating, never True. wiz-sensor fired correctly only\n'
         '# because it is STALLED and its condition sits still. INFRA-1657.\n')

note4 = ('# 2026-08-24, third correction: the expressions aggregate with max by(). An\n'
         '# alert instance is identified by the LABEL SET of the output, and `ready`\n'
         '# was in it -- so under ready!="True" a flapping object still produced two\n'
         '# alternating instances, each resetting activeAt, and the 10m window still\n'
         '# never completed. `revision` churns the same way on every apply. Measured:\n'
         '#   count(count_over_time(gotk_resource_info{...ready!="True"}[10m]) >= 20)\n'
         '#     = 1   (wiz-sensor only -- the stalled one)\n'
         '#   same, with max by (exported_namespace, name) applied first\n'
         '#     = 2   (wiz-sensor AND risingwave)\n'
         '#\n'
         '# The summaries say exported_namespace, NOT namespace. kube-state-metrics is\n'
         '# scraped in its own namespace, so its ServiceMonitor stamps\n'
         '# namespace="prometheus" on every series -- the page would have named the\n'
         '# wrong namespace. Verified live: exported_namespace=flux-system,\n'
         '# namespace=prometheus. Other rules in this file use $labels.namespace\n'
         '# correctly, because kube_pod_* carries a real one. INFRA-1657.\n')

anchor = "apiVersion: monitoring.coreos.com/v1"
for nt in (note3, note4):
    if nt not in al:
        al = al.replace(anchor, nt + anchor, 1)

open(p, "w", encoding="utf-8").write(al)
print(f"   {changed_expr} expressions aggregated, {changed_ann} summaries repointed to exported_namespace")
PY
  then
    echo "!! anchored edit failed on $B — nothing changed. SKIPPING."
    git checkout -q -- . ; FAILED=1; continue
  fi

  python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$AL" 2>/dev/null \
    || { echo "!! YAML no longer parses. SKIPPING."; git checkout -q -- . ; FAILED=1; continue; }
  echo "   yaml parses: ok"

  # If promtool is here, actually check the PromQL rather than trusting it.
  if command -v promtool >/dev/null; then
    TMPR=$(mktemp)
    python3 - "$AL" "$TMPR" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
groups = []
for d in docs:
    if d.get("kind") == "PrometheusRule":
        groups.extend(d.get("spec", {}).get("groups", []))
yaml.safe_dump({"groups": groups}, open(sys.argv[2], "w"))
PY
    if promtool check rules "$TMPR" >/dev/null 2>&1; then
      echo "   promtool check rules: ok"
    else
      echo "!! promtool rejected the rules on $B:"
      promtool check rules "$TMPR" 2>&1 | sed 's/^/     /'
      rm -f "$TMPR"; git checkout -q -- . ; FAILED=1; continue
    fi
    rm -f "$TMPR"
  else
    echo "   (no promtool — PromQL NOT syntax-checked on this branch)"
  fi

  DIR=$(dirname "$AL")
  if command -v kubectl >/dev/null && ! kubectl kustomize "$DIR" >/dev/null 2>&1; then
    echo "!! kubectl kustomize $DIR FAILED. SKIPPING."
    git checkout -q -- . ; FAILED=1; continue
  fi
  echo "   kustomize build: ok"

  git add -A
  git commit -q -m "INFRA-1657: aggregate the churning labels, and name the right namespace

An alert instance is identified by the label set of the expression's output, and
ready was in it. So ready!=\"True\" widened the match but a flapping Kustomization
still produced two alternating alert instances -- False and Unknown -- each
vanishing as the other appeared, each resetting activeAt. The 10m window still
never completed. revision churns the same way, changing on every apply.

Measured on op-usxpress-dev:
  count(count_over_time(gotk_resource_info{...ready!=\"True\"}[10m]) >= 20)  = 1
  same, with max by (exported_namespace, name) applied first               = 2

Two Kustomizations have been not-Ready for days. Only the aggregated form sees
both; the unaggregated one sees only wiz-sensor, which is stalled and therefore
does not flap.

Separately, the summaries said {{ \$labels.namespace }}, which is
kube-state-metrics' OWN namespace -- its ServiceMonitor stamps
namespace=\"prometheus\" on every series it emits, which is why the CRS config
had to call the real one exported_namespace. Verified live on
gotk_resource_info{name=\"risingwave\"}: exported_namespace=flux-system,
namespace=prometheus. The page would have fired correctly and named the wrong
namespace. Only the three Flux summaries are changed; the other rules in this
file use \$labels.namespace correctly." || echo "   nothing to commit"

  echo
  echo "-------- git diff origin/$B --------"
  git --no-pager diff "origin/$B"
  echo "-------- end diff for $B --------"

  if [ "$PUSH" = "yes" ]; then
    if git push -q -u origin "$TOPIC-$B"; then
      gh pr create --repo variant-inc/iaac-talos-flux-platform \
        --base "$B" --head "$TOPIC-$B" \
        --title "INFRA-1657: aggregate churning labels so cycling failures complete the for: window" \
        --body "Fourth and final part of INFRA-1657. Part three (\`ready!=\"True\"\`) was necessary and **not sufficient**.

**Defect 1 — the alert instance still churns.** Prometheus identifies an alert instance by the **label set of the expression's output**, and \`ready\` is in that set. A Kustomization flapping \`False\`↔\`Unknown\` therefore still produces *two alternating alert instances*; each disappears as the other appears, each resets \`activeAt\`, and the 10-minute \`for:\` window still never completes.

Measured on op-usxpress-dev:

| query | result |
|---|---|
| \`count(count_over_time(gotk_resource_info{…ready!=\"True\"}[10m]) >= 20)\` | **1** |
| same, with \`max by (exported_namespace, name)\` applied first | **2** |

Two Kustomizations — \`risingwave\` and \`wiz-sensor\` — have been not-Ready for days. The unaggregated form sees only \`wiz-sensor\`, because it is *stalled* and so does not flap. \`revision\` churns the same way, changing on every successful apply, so it would have reset the HelmRelease and GitRepository rules too.

**Defect 2 — the annotations name the wrong namespace.** The summaries said \`{{ \$labels.namespace }}\`. kube-state-metrics is scraped in its own namespace, so its ServiceMonitor stamps \`namespace=\"prometheus\"\` onto every series it emits — which is precisely why the CustomResourceState config had to call the real one \`exported_namespace\`. Verified live:

\`\`\`
exported_namespace=flux-system     <- the Kustomization
namespace=prometheus               <- kube-state-metrics' own pod
\`\`\`

The page would have read *\"Flux Kustomization prometheus/risingwave not Ready > 10m\"* — a correct alert naming the wrong namespace. After \`max by()\` drops \`namespace\`, it would have rendered empty instead. Only the three Flux summaries change; every other rule in this file uses \`\$labels.namespace\` correctly, because \`kube_pod_*\` carries a real one.

**\`for: 10m\` is confirmed correctly sized.** Peak cascade breadth in the observed window was 27 Kustomizations simultaneously not-True — a \`dependsOn\` fan-out during a mass reconcile — decaying to 4 within three minutes. Exactly 2 objects survive a full 10-minute window, which is the two genuinely broken ones.

**Verify after merge** — note the object is \`prometheusrule/platform-health\`, not \`platform-alerts\` (that is the filename):
\`\`\`
kubectl --context <ctx> -n prometheus get prometheusrule platform-health -o yaml | grep -A3 'max by'
curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname==\"FluxKustomizationFailed\") | \"\(.state) \(.labels.exported_namespace)/\(.labels.name)\"'
\`\`\`
\`risingwave\` must reach \`firing\` and **stay** there across several flips — reaching it once is what the last three attempts already did.

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
[ "$FAILED" -eq 0 ] || { echo "One or more branches were skipped."; exit 1; }
