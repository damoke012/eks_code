#!/usr/bin/env bash
# op-usxpress-dev / risingwave-2: Prometheus filled its 10Gi volume and crashlooped 1567
# times. Bring the HelmRelease into line with the cluster, and bound the pod.
#
# What happened, 2026-09-03. prometheus-server exited 1 on every start:
#   "write /data/queries.active: no space left on device"
# The PVC was 10Gi on ceph-block, 72 days old, and `retention: 15d` was already in the
# values -- retention did NOT prevent this, because retention is enforced by a RUNNING
# Prometheus and this one never got far enough to apply it. The disk filled, and from then
# on it could not start to clean up after itself.
#
# The PVC was expanded live to 25Gi (ceph-block has allowVolumeExpansion: true) to break
# that deadlock. THIS PR makes Git say the same thing -- otherwise the next reconcile or
# rebuild silently puts it back to 10Gi and the loop starts again.
#
# It also sets resources. Both containers had `resources: {}`, so nothing bounded them:
# automemlimit read the CGROUP limit as 11.2 GB, i.e. the whole node. An unbounded
# Prometheus on a shared dev node is how one workload takes the others with it.
#
#   scripts/pr-rw2-prometheus-storage.sh          # dry run, prints the diff
#   scripts/pr-rw2-prometheus-storage.sh --push
set -euo pipefail

REPO="${REPO:-$HOME/pr-work/iaac-risingwave-2}"
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
if [ -n "$(git status --porcelain)" ]; then
  echo "!! $REPO has uncommitted changes. Commit or stash them first." >&2
  git --no-pager status --short >&2; exit 2
fi
git fetch -q origin

# The Flux Kustomization `risingwave` on op-dev tracks sourceRef iaac-risingwave-2,
# path ./manifests/op-usxpress-dev. Confirmed against the live cluster 2026-09-03.
BR="${BR:-master}"
git rev-parse --verify -q "origin/$BR" >/dev/null || BR=main
TOPIC="rw2-prometheus-storage"
DIR="manifests/op-usxpress-dev"

git checkout -q -B "$TOPIC" "origin/$BR"
[ -d "$DIR" ] || { echo "!! $DIR not on origin/$BR — is this iaac-risingwave-2?" >&2; exit 1; }

# Find the file by CONTENT, not by a guessed filename.
HR=$(grep -rl --include='*.yaml' --include='*.yml' 'kind: HelmRelease' "$DIR" \
     | xargs grep -l 'name: prometheus' 2>/dev/null | head -1)
[ -n "$HR" ] || { echo "!! no HelmRelease named prometheus under $DIR on $BR" >&2; exit 1; }
echo "   HelmRelease: $HR"

python3 - "$HR" <<'PY'
import re, sys, yaml
path = sys.argv[1]
raw = open(path).read()

# Assert the shape BEFORE editing. A blind sed here would silently do nothing, or edit the
# wrong size: on 2026-09-03 rw-prod-status keyed on a column that was never what it assumed.
doc = None
for d in yaml.safe_load_all(raw):
    if d and d.get("kind") == "HelmRelease" and d.get("metadata", {}).get("name") == "prometheus":
        doc = d
assert doc, "no prometheus HelmRelease parsed out of %s" % path
server = doc["spec"]["values"]["server"]
assert server["persistentVolume"]["size"] == "10Gi", \
    "expected size 10Gi, found %r -- someone has already changed this" % server["persistentVolume"]["size"]
assert "resources" not in server or not server["resources"], \
    "server.resources already set to %r -- not overwriting" % server.get("resources")

# Edit the TEXT, so comments and ordering survive. One occurrence only.
new, n = re.subn(r'(persistentVolume:(?:\n[ \t]+.*)*?\n[ \t]+size:[ \t]*)10Gi', r'\g<1>25Gi', raw, count=1)
assert n == 1, "expected exactly one persistentVolume size to rewrite, changed %d" % n

# Add resources beside retention, at retention's own indentation.
m = re.search(r'(?m)^([ \t]+)retention:[ \t]*.*$', new)
assert m, "no retention line to anchor resources against"
ind = m.group(1)
block = (
    "\n{i}# 2026-09-03: both containers ran with resources: {{}}, so automemlimit read the\n"
    "{i}# cgroup limit as the whole node (11.2 GB). First pass -- tune once it has a week\n"
    "{i}# of real usage behind it.\n"
    "{i}resources:\n"
    "{i}  requests:\n"
    "{i}    cpu: 250m\n"
    "{i}    memory: 512Mi\n"
    "{i}  limits:\n"
    "{i}    memory: 3Gi"
).format(i=ind)
new = new[:m.end()] + block + new[m.end():]
open(path, "w").write(new)

# Parse it back and assert on the PARSED document, not on the text we just wrote.
back = None
for d in yaml.safe_load_all(open(path).read()):
    if d and d.get("kind") == "HelmRelease" and d.get("metadata", {}).get("name") == "prometheus":
        back = d
s = back["spec"]["values"]["server"]
assert s["persistentVolume"]["size"] == "25Gi", s["persistentVolume"]["size"]
assert s["resources"]["limits"]["memory"] == "3Gi", s["resources"]
assert s["retention"] == "15d", "retention changed unexpectedly: %r" % s.get("retention")
print("   parsed back:  size=%s  retention=%s  limits=%s"
      % (s["persistentVolume"]["size"], s["retention"], s["resources"]["limits"]))
PY

git add -A "$DIR"
echo
echo "-------- git diff origin/$BR --------"
git --no-pager diff --cached "origin/$BR"
echo "-------- end --------"

git commit -q -F - <<'COMMIT'
risingwave-2 prometheus: 25Gi to match the cluster, and bound the pod

prometheus-server crashlooped 1567 times on op-usxpress-dev, exiting 1 every
start with "write /data/queries.active: no space left on device". The PVC was
10Gi on ceph-block and had been full for a long time.

retention: 15d was already set and did not prevent it. Retention is enforced by
a RUNNING Prometheus; this one died before applying it, so once the volume filled
it could never start to clean up after itself. A bigger volume alone would only
delay that, which is why the limits below matter as much as the size.

The PVC was expanded live to 25Gi to break the deadlock (ceph-block has
allowVolumeExpansion: true). This makes Git agree -- without it the next
reconcile or rebuild puts it back to 10Gi.

Also sets resources on the server container. Both containers ran with
resources: {}, so automemlimit read the cgroup limit as 11.2 GB, the whole node.
A first pass at 250m/512Mi requests and a 3Gi memory limit; worth tuning once
there is a week of real usage to look at.

Dev only. risingwave-2 is dev-only and is never promoted.
COMMIT

if [ "$PUSH" = "yes" ]; then
  git push -q -u origin "$TOPIC" --force-with-lease
  echo "   pushed $TOPIC"
  echo
  echo "   Open the PR with the base pinned:"
  echo "     gh pr create --base $BR --head $TOPIC --fill"
else
  echo "   committed to local $TOPIC (not pushed). Re-run with --push."
fi
