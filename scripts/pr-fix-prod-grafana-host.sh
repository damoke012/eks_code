#!/usr/bin/env bash
# INFRA-1689 — op-usxpress-prod's Grafana VirtualService claims grafana.op-dev.usxpress.io,
# a DEV hostname, and carries dev's seven ingress target IPs. Recorded on the op-prod branch
# 2026-08-31 while correcting the RisingWave routes under INFRA-1674, and deliberately left
# out of that PR (wip/rw-etl-promotion/PR-BODY-INFRA-1674-prod-routes.md).
#
# What is actually broken. op-dev OWNS that record in zone usxpress.io — ownership is keyed
# on --txt-owner-id in the DynamoDB registry — so prod's external-dns SKIPS it: no error, no
# event, and prod's Grafana has no working hostname at all. This is not a collision that
# resolves the wrong way. Prod Grafana is simply unreachable by name, and every status field
# is green. So this change does not "repoint" prod's route; it gives prod Grafana its first
# name.
#
# Targets are DERIVED from op-prod's own argocd route, which is verified correct
# (argocd.op-prod.usxpress.io, live since 2026-08-25). They are NOT dev's and NOT QA's: each
# cluster targets its own platform pool and the lists are different lengths. There is no rule
# to generalise — see [[onprem-ingress-dns-convention]].
#
#   scripts/pr-fix-prod-grafana-host.sh          # dry run, prints the diff
#   scripts/pr-fix-prod-grafana-host.sh --push
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

# Refuse a dirty tree rather than dying halfway through a branch switch.
if [ -n "$(git status --porcelain)" ]; then
  echo "!! $REPO has uncommitted changes. Commit or stash them first." >&2
  git --no-pager status --short >&2
  exit 2
fi
git fetch -q origin

BR="op-prod"; TOPIC="infra-1689-prod-grafana-host"
OLD_HOST="grafana.op-dev.usxpress.io"
NEW_HOST="grafana.op-prod.usxpress.io"

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

# The reference must belong to THIS cluster, or we copy the same mistake into the fix.
# Read spec.hosts; do NOT grep. On 2026-08-24 grepping the first hostname-shaped string
# matched a hostname inside a COMMENT, so a file whose comment said op-qa while its spec
# claimed a dev host would have passed — the exact case this check exists to catch.
RHOST=$(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["spec"]["hosts"][0])' "$REF")
case "$RHOST" in
  *.op-prod.usxpress.io) echo "   reference route: $RHOST (belongs to $BR)" ;;
  *) echo "!! reference $REF claims '$RHOST', not .op-prod. Refusing." >&2; exit 1 ;;
esac
TARGETS=$(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["metadata"]["annotations"]["external-dns.alpha.kubernetes.io/target"])' "$REF")
[ -n "$TARGETS" ] || { echo "!! no external-dns target on $REF" >&2; exit 1; }
echo "   prod targets:    $TARGETS"

OLD_TARGETS=$(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["metadata"]["annotations"].get("external-dns.alpha.kubernetes.io/target",""))' "$VS")
echo "   was:             ${OLD_TARGETS:-<none>}"

# If the reference carries the same targets the broken file already has, the reference is
# itself a copy and deriving from it changes the hostname while leaving prod pointed at
# dev's nodes — a half-fix that looks complete in the diff.
[ "$TARGETS" != "$OLD_TARGETS" ] || {
  echo "!! $REF carries the SAME targets as the broken $VS ($TARGETS)." >&2
  echo "   The reference route is a copy too. Verify prod's platform node IPs by hand." >&2
  exit 1; }

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
"    # INFRA-1689, 2026-09-03: this route claimed %s --\n"
"    # a DEV hostname, on the PROD cluster, carrying dev's ingress addresses.\n"
"    # op-dev owns that record in zone usxpress.io, so prod's external-dns skipped\n"
"    # it entirely: no error, no event, and prod Grafana had no name at all.\n"
"    # Targets below are op-prod's own, taken from this branch's verified argocd\n"
"    # route; dev's and QA's lists are different lengths and not transferable.\n" % old)
s = re.sub(r'( *)(external-dns\.alpha\.kubernetes\.io/target: )', note + r'\1\2', s, count=1)
open(path, "w").write(s)
PY1

# Parse the result back. Assert against the PARSED document, not the raw text, so the
# explanatory comment cannot satisfy or break the check either way.
python3 - "$VS" "$NEW_HOST" "$OLD_HOST" "$TARGETS" <<'PY2'
import sys, yaml
path, new, old, targets = sys.argv[1:5]
d = yaml.safe_load(open(path))
assert d["kind"] == "VirtualService", d["kind"]
assert d["spec"]["hosts"] == [new], d["spec"]["hosts"]
ann = d["metadata"]["annotations"]["external-dns.alpha.kubernetes.io/target"]
assert ann == targets, (ann, targets)

# No dev or QA string may survive anywhere in the live parts of the document. Comments are
# stripped by the parser, so provenance notes are exempt by construction.
live = yaml.safe_dump(d)
for foreign in ("op-dev", "op-qa"):
    assert foreign not in live, "%s still present in the parsed document" % foreign
print("   parsed back:     %s, %d dns targets, no foreign env in spec" % (new, len(targets.split(","))))
PY2

git add -A infrastructure/grafana
[ -x scripts/check-foreign-cluster-ids.sh ] && { scripts/check-foreign-cluster-ids.sh || exit 1; } || true

echo
echo "-------- git diff origin/$BR --------"
git --no-pager diff --cached "origin/$BR"
echo "-------- end --------"

git commit -q -F - <<COMMIT
op-prod: Grafana had no hostname, because it claimed dev's

infrastructure/grafana/virtualservice.yaml claimed grafana.op-dev.usxpress.io
and carried op-dev's ingress target IPs.

This is not a collision. external-dns keys ownership on --txt-owner-id in the
DynamoDB registry, so prod skipped a record dev owns: silently, with no error
and no event. Prod Grafana has never had a working name, and every status field
stayed green throughout.

Repointed to grafana.op-prod.usxpress.io with op-prod's own targets, derived
from this branch's verified argocd route (argocd.op-prod.usxpress.io). Dev's
and QA's target lists are different lengths; they are not transferable.

Same defect class as the RisingWave route copies corrected on this branch under
INFRA-1674, and noted then as deserving its own change.

AFTER MERGE: confirm with scripts/onprem-dns-claims.sh dev qa prod -- prod
should claim grafana.op-prod.usxpress.io against its own nodes, and dev's
record should be untouched.
COMMIT

if [ "$PUSH" = "yes" ]; then
  git push -q -u origin "$TOPIC" --force-with-lease
  echo "   pushed $TOPIC"
  echo
  # This repo has a branch PER CLUSTER and its default branch is op-dev, so GitHub's
  # "Open a pull request" page opens with base=op-dev. Creating it there would merge a
  # PROD route into DEV: dev's Grafana would claim grafana.op-prod.usxpress.io with prod's
  # targets. The tell is "Can't automatically merge" plus an empty auto-filled body.
  # Use this and the base cannot be wrong:
  echo "   Open the PR with the base pinned — do NOT use the GitHub link, it defaults to op-dev:"
  echo "     gh pr create --base $BR --head $TOPIC --fill"
else
  echo "   committed to local $TOPIC (not pushed). Re-run with --push."
fi
