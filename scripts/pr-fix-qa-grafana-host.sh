#!/usr/bin/env bash
# op-qa's Grafana VirtualService claims grafana.op-dev.usxpress.io -- a DEV hostname,
# live on the QA cluster (verified 2026-08-24 via scripts/onprem-ingress-audit.sh).
# op-dev claims the same name. Two clusters, one DNS record, both running external-dns
# against zone usxpress.io; whichever wrote last decides where it resolves.
#
# Repoints QA's route to its own hostname and its own ingress targets.
#
# The targets are DERIVED from op-qa's argocd VirtualService, which is verified correct
# (argocd.op-qa.usxpress.io). They are NOT dev's: op-dev targets all 7 workers, op-qa
# targets 3 of 13 (the platform pool). There is no rule to generalise.
#
#   scripts/pr-fix-qa-grafana-host.sh          # dry run, prints the diff
#   scripts/pr-fix-qa-grafana-host.sh --push
set -euo pipefail

REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
PUSH="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH="yes"; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }
cd "$REPO"
git fetch origin

BR="op-qa"; TOPIC="infra-1639-qa-grafana-host"
OLD_HOST="grafana.op-dev.usxpress.io"
NEW_HOST="grafana.op-qa.usxpress.io"

clean_grafana() {
  git checkout -q HEAD -- infrastructure/grafana 2>/dev/null || true
  git clean -qfd infrastructure/grafana 2>/dev/null || true
}
trap clean_grafana EXIT
clean_grafana
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure/grafana
git clean -qfd infrastructure/grafana

VS="infrastructure/grafana/virtualservice.yaml"
REF="infrastructure/argocd-config/virtualservice-argocd.yaml"
[ -f "$VS" ]  || { echo "!! $VS missing on $BR" >&2; exit 1; }
[ -f "$REF" ] || { echo "!! $REF missing on $BR -- no verified route to copy targets from" >&2; exit 1; }

# The reference must belong to THIS cluster, or we are copying the same mistake.
RHOST=$(grep -oE '[a-z0-9.-]+\.usxpress\.io' "$REF" | head -1)
case "$RHOST" in
  *.op-qa.usxpress.io) echo "   reference route: $RHOST (belongs to $BR)" ;;
  *) echo "!! reference $REF claims '$RHOST', not .op-qa. Refusing." >&2; exit 1 ;;
esac
TARGETS=$(grep -oE 'external-dns\.alpha\.kubernetes\.io/target: *"[^"]+"' "$REF" \
          | sed 's/.*"\(.*\)"/\1/')
[ -n "$TARGETS" ] || { echo "!! no external-dns target on $REF" >&2; exit 1; }
echo "   qa targets:      $TARGETS"

grep -q "$OLD_HOST" "$VS" || { echo "!! $VS does not claim $OLD_HOST -- already fixed?" >&2; exit 1; }

python3 - "$VS" "$OLD_HOST" "$NEW_HOST" "$TARGETS" <<'PY1'
import re, sys
path, old, new, targets = sys.argv[1:5]
s = open(path).read()
s = s.replace(old, new)
s, n = re.subn(r'(external-dns\.alpha\.kubernetes\.io/target: *")[^"]+(")',
               lambda m: m.group(1) + targets + m.group(2), s)
assert n == 1, "expected exactly one external-dns target annotation, found %d" % n
note = (
"    # 2026-08-24: this route claimed %s -- a DEV\n"
"    # hostname, live on the QA cluster, while op-dev claimed the same name.\n"
"    # Two clusters, one DNS record, resolution decided by whichever external-dns\n"
"    # wrote last. Targets below are op-qa's own (the platform pool), taken from\n"
"    # this branch's verified argocd route; op-dev's list is a different length.\n" % old)
s = re.sub(r'( *)(external-dns\.alpha\.kubernetes\.io/target: )', note + r'\1\2', s, count=1)
open(path, "w").write(s)
PY1

python3 - "$VS" "$NEW_HOST" "$OLD_HOST" "$TARGETS" <<'PY2'
import sys, yaml
path, new, old, targets = sys.argv[1:5]
d = yaml.safe_load(open(path))
assert d["kind"] == "VirtualService", d["kind"]
assert d["spec"]["hosts"] == [new], d["spec"]["hosts"]
assert old not in open(path).read().replace("# 2026-08-24: this route claimed " + old, ""), \
    "the dev hostname still appears outside the explanatory comment"
ann = d["metadata"]["annotations"]["external-dns.alpha.kubernetes.io/target"]
assert ann == targets, (ann, targets)
print("   parsed back:     %s, %d dns targets" % (new, len(targets.split(","))))
PY2

git add -A infrastructure/grafana
[ -x scripts/check-foreign-cluster-ids.sh ] && { scripts/check-foreign-cluster-ids.sh || exit 1; } || true

echo
echo "-------- git diff origin/$BR --------"
git --no-pager diff --cached "origin/$BR"
echo "-------- end --------"

git commit -q -m "op-qa: Grafana claimed a dev hostname on the QA cluster

infrastructure/grafana/virtualservice.yaml claimed grafana.op-dev.usxpress.io
and carried op-dev's seven ingress target IPs. op-dev claims the same name, so
two clusters were claiming one DNS record in zone usxpress.io and resolution
was decided by whichever external-dns wrote last -- opening dev's Grafana URL
could land on QA's.

Repointed to grafana.op-qa.usxpress.io with op-qa's own targets, taken from
this branch's verified argocd route (op-qa uses 3 of 13 workers; op-dev uses
all 7, so the list is not transferable).

AFTER MERGE: the old record is dev's alone again, and anyone bookmarked on
grafana.op-dev.usxpress.io expecting QA needs the new name."

if [ "$PUSH" = "yes" ]; then
  git push -q -u origin "$TOPIC" --force-with-lease
  echo "   pushed $TOPIC"
else
  echo "   committed to local $TOPIC (not pushed). Re-run with --push."
fi
