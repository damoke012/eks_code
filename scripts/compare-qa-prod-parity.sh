#!/usr/bin/env bash
# What is DIFFERENT between op-usxpress-qa and op-usxpress-prod?  READ ONLY.
#
#   scripts/compare-qa-prod-parity.sh            # summary
#   scripts/compare-qa-prod-parity.sh --full     # every line, not just counts
#
# WHY
#   "Make prod identical to QA" cannot be planned from memory. This measures
#   the delta so the work is a list rather than an impression.
#
#   It resolves each cluster BY ENDPOINT and by which kubeconfig actually
#   answers -- never by filename. ~/.kube on this box holds a file named
#   op-usxpress-dev.yaml that points at cloud QA EKS, and two files serve each
#   on-prem endpoint with different auth.
set -uo pipefail

FULL=no; [ "${1:-}" = "--full" ] && FULL=yes
QA_EP=10.10.82.51;   QA_ACCT=527101283767
PROD_EP=10.10.82.52; PROD_ACCT=937464026810
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

say() { printf '%s\n' "$*"; }
hdr() { say ""; say "=== $*"; }

# A kubeconfig is chosen because it ANSWERS, not because it matched a name.
resolve() {
  local ep="$1" f s
  for f in "$HOME"/.kube/*.yaml "$HOME"/.kube/*.yml; do
    [ -f "$f" ] || continue
    s=$(kubectl --kubeconfig="$f" config view -o jsonpath='{.clusters[*].cluster.server}' 2>/dev/null)
    [ "$(echo "$s" | wc -w)" = "1" ] || continue
    case "$s" in *"$ep:6443"*) ;; *) continue ;; esac
    kubectl --kubeconfig="$f" get --raw /version >/dev/null 2>&1 && { printf '%s' "$f"; return 0; }
  done
  return 1
}

KQA=$(resolve "$QA_EP")   || { say "STOPPED - no working kubeconfig answers $QA_EP:6443";   exit 2; }
KPR=$(resolve "$PROD_EP") || { say "STOPPED - no working kubeconfig answers $PROD_EP:6443"; exit 2; }
say "qa:   $(basename "$KQA")"
say "prod: $(basename "$KPR")"

k() { kubectl --kubeconfig="$1" "${@:2}" 2>/dev/null; }

# ---- collect -----------------------------------------------------------------
for E in qa prod; do
  [ "$E" = qa ] && KC="$KQA" || KC="$KPR"
  k "$KC" get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort > "$W/$E.ns"
  k "$KC" get kustomizations -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort > "$W/$E.ks"
  k "$KC" get kustomizations -A \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | grep -v "$(printf '\t')True$" | sort > "$W/$E.ks_bad"
  k "$KC" get helmreleases -A \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.chart.spec.version}{"\n"}{end}' | sort > "$W/$E.hr"
  k "$KC" get pods -A --field-selector=status.phase!=Running \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' | sort > "$W/$E.badpods"
  k "$KC" get virtualservices -A -o jsonpath='{range .items[*]}{.spec.hosts[*]}{"\n"}{end}' | tr ' ' '\n' | sort -u > "$W/$E.vs"
  k "$KC" get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort | uniq -c > "$W/$E.kver"
  # IRSA role ARNs, with the account they point at. This is the one that bites:
  # platform branches are copies of each other, so an op-prod manifest can
  # carry a DEV role ARN and everything stays green until a pod needs AWS.
  k "$KC" get sa -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}{end}' \
    | grep 'arn:aws:iam' | sort > "$W/$E.irsa"
done

only() { comm -23 "$1" "$2"; }

hdr "node kubelet versions"
say "-- qa";   cat "$W/qa.kver"
say "-- prod"; cat "$W/prod.kver"

hdr "namespaces"
say "only in QA:   $(only "$W/qa.ns" "$W/prod.ns" | tr '\n' ' ')"
say "only in PROD: $(only "$W/prod.ns" "$W/qa.ns" | tr '\n' ' ')"

hdr "Flux Kustomizations"
say "count  qa=$(wc -l < "$W/qa.ks")  prod=$(wc -l < "$W/prod.ks")"
say "only in QA:   $(only "$W/qa.ks" "$W/prod.ks" | tr '\n' ' ')"
say "only in PROD: $(only "$W/prod.ks" "$W/qa.ks" | tr '\n' ' ')"
say "NOT Ready on qa:   $(wc -l < "$W/qa.ks_bad")"
[ -s "$W/qa.ks_bad" ] && sed 's/^/     /' "$W/qa.ks_bad"
say "NOT Ready on prod: $(wc -l < "$W/prod.ks_bad")"
[ -s "$W/prod.ks_bad" ] && sed 's/^/     /' "$W/prod.ks_bad"

hdr "HelmReleases (name + chart version)"
say "only in QA:";   only "$W/qa.hr" "$W/prod.hr" | sed 's/^/   /'
say "only in PROD:"; only "$W/prod.hr" "$W/qa.hr" | sed 's/^/   /'

hdr "IRSA role ARNs pointing at the WRONG account"
# A ServiceAccount on prod must name a role in prod's account. Anything else is
# a manifest copied between branches, and it fails only when a pod calls AWS.
for E in qa prod; do
  [ "$E" = qa ] && WANT=$QA_ACCT || WANT=$PROD_ACCT
  BAD=$(awk -v w="$WANT" -F'\t' '$2 !~ ("::" w ":") {print "   " $1 "  -> " $2}' "$W/$E.irsa")
  N=$(printf '%s' "$BAD" | grep -c . || true)
  say "$E (expects $WANT): $N of $(wc -l < "$W/$E.irsa") wrong"
  [ -n "$BAD" ] && printf '%s\n' "$BAD"
done

hdr "pods not Running"
say "qa:   $(wc -l < "$W/qa.badpods")"
[ "$FULL" = yes ] && sed 's/^/   /' "$W/qa.badpods"
say "prod: $(wc -l < "$W/prod.badpods")"
[ "$FULL" = yes ] && sed 's/^/   /' "$W/prod.badpods"

hdr "ingress hostnames"
say "count  qa=$(wc -l < "$W/qa.vs")  prod=$(wc -l < "$W/prod.vs")"
if [ "$FULL" = yes ]; then
  say "only in QA:";   only "$W/qa.vs" "$W/prod.vs" | sed 's/^/   /'
  say "only in PROD:"; only "$W/prod.vs" "$W/qa.vs" | sed 's/^/   /'
fi

say ""
say "Counts are a starting point, not a verdict: a Kustomization present on"
say "both clusters can still reconcile different content. Re-run with --full"
say "for the lines behind each count."
