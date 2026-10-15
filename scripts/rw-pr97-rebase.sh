#!/usr/bin/env bash
#
# rw-pr97-rebase.sh -- rebase PR #97 (bootstrap-database-hook) onto master and
# resolve its two conflicts.
#
# Both conflicts are add/add in the same place, and neither side touches the
# other's keys:
#
#   values.yaml      master added `appSecret:`   #97 adds `bootstrap:`
#   values-dev.yaml  master added `appSecret:`   #97 adds `bootstrap:`
#
# So the resolution is KEEP BOTH. Nothing is dropped and no behaviour is
# invented: the marker lines go, the content on both sides stays, and the
# `=======` becomes the blank line that separates the two blocks.
#
# Guarded: refuses unless each file has exactly one conflict with one marker of
# each kind, and both files must still parse as YAML afterwards. A resolution
# that silently drops one side is the failure mode here, and it would look like
# a clean merge.
#
# Leaves the rebase finished and the branch ready to force-push. Does not push.

set -euo pipefail

D=/tmp/pr97
if [ ! -d "$D/.git" ]; then
  echo "ABORT - no clone at $D. Run the rebase block first."
  exit 1
fi
cd "$D"

if [ ! -d .git/rebase-merge ] && [ ! -d .git/rebase-apply ]; then
  echo "ABORT - no rebase in progress at $D"
  exit 1
fi

python3 - <<'PY'
import pathlib, sys
files = ["deploy/chart/values-dev.yaml", "deploy/chart/values.yaml"]
for f in files:
    p = pathlib.Path(f)
    s = p.read_text()
    a, b, c = s.count("<<<<<<<"), s.count("\n=======\n"), s.count(">>>>>>>")
    if (a, b, c) != (1, 1, 1):
        print(f"ABORT {f}: markers <<< {a}  === {b}  >>> {c}, expected 1/1/1")
        sys.exit(1)
    out = []
    for line in s.splitlines(keepends=True):
        if line.startswith("<<<<<<<") or line.startswith(">>>>>>>"):
            continue
        if line.rstrip("\n") == "=======":
            out.append("\n")      # the separator between the two blocks
            continue
        out.append(line)
    p.write_text("".join(out))
    print(f"resolved {f}")
PY

echo
echo "=== both files must still parse, and hold BOTH keys ==="
python3 - <<'PY'
import yaml, sys
ok = True
for f, need in [("deploy/chart/values-dev.yaml", ["appSecret", "bootstrap"]),
                ("deploy/chart/values.yaml",     ["appSecret", "bootstrap"])]:
    d = yaml.safe_load(open(f))
    miss = [k for k in need if k not in d]
    print(f"  {f}: keys={len(d)} missing={miss or 'none'}")
    if miss:
        ok = False
if not ok:
    print("ABORT - a side was dropped")
    sys.exit(1)
print("  both sides present in both files")
PY

echo
echo "=== values-dev bootstrap block ==="
python3 -c "import yaml;print(yaml.safe_load(open('deploy/chart/values-dev.yaml'))['bootstrap'])"

git add deploy/chart/values-dev.yaml deploy/chart/values.yaml
GIT_EDITOR=true git rebase --continue

echo
echo "=== rebase done ==="
git log --oneline -3
echo
echo "files changed vs master:"
git diff --stat origin/master
echo
echo "Clone: $D   (force-push needed: the rebase rewrote the commit)"
