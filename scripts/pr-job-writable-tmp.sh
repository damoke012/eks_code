#!/usr/bin/env bash
# Open the PR that gives the apply Job a writable /tmp.
# Renders the QA overlay and checks the result structurally before offering to push.
set -uo pipefail
REPO="variant-inc/risingwave-pipeline"
BRANCH="fix/job-writable-tmp"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

gh repo clone "$REPO" "$T/rp" -- --quiet 2>/dev/null || { echo "clone failed"; exit 3; }
cd "$T/rp"
git checkout --quiet -b "$BRANCH" origin/master

echo "=== patching deploy/base/job.yaml ==="
python3 "$HERE/fix-job-writable-tmp.py" deploy/base/job.yaml || exit 5
echo
echo "=== diff ==="
git --no-pager diff
echo
echo "=== does the QA overlay still render, and does the rendered Job carry it? ==="
if ! kubectl kustomize deploy/overlays/qa > "$T/qa.yaml" 2>"$T/err"; then
  echo "render FAILED -- not pushing:"; sed 's/^/   /' "$T/err"; exit 5
fi
python3 - "$T/qa.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
job = [d for d in docs if d.get("kind") == "Job"][0]
spec = job["spec"]["template"]["spec"]; c = spec["containers"][0]
print("   readOnlyRootFilesystem :", c["securityContext"]["readOnlyRootFilesystem"])
print("   volumes                :", [v["name"] for v in spec.get("volumes", [])])
print("   mounts                 :", [(m["name"], m["mountPath"]) for m in c.get("volumeMounts", [])])
print("   image                  :", c["image"].split("@")[-1][:19])
ok = (c["securityContext"]["readOnlyRootFilesystem"] is True
      and any(m["mountPath"] == "/tmp" for m in c.get("volumeMounts", []))
      and any("emptyDir" in v for v in spec.get("volumes", [])))
print("   VERDICT                :", "good" if ok else "NOT GOOD")
sys.exit(0 if ok else 1)
PY
[ $? -ne 0 ] && { echo "rendered Job is not what we want -- not pushing"; exit 5; }
echo
read -r -p "push and open the PR? [y/N] " a
case "$a" in y|Y|yes|YES) ;; *) echo "Not pushed."; exit 0 ;; esac

git add deploy/base/job.yaml
git commit -q -m "fix: give the apply Job a writable /tmp

apply.sh renders every pipeline file through mktemp before applying it, and the
container runs with readOnlyRootFilesystem: true and no volumes, so the render
fails on the first file:

  mktemp: Read-only file system

No pipeline file can be applied on QA today -- Brand included. An emptyDir at
/tmp fixes it without weakening the security context."
cat > "$T/body.md" <<'BODY'
## The defect

`apply.sh` renders each pipeline file through `mktemp` (the `%TOKEN%` substitution, and
the file it hashes into `pipeline_applied`). The Job runs with
`readOnlyRootFilesystem: true` and declares **no volumes at all**, so the very first
render fails:

```
pipeline dir : /pipeline/pipelines/canary
risingwave   : root@risingwave-frontend.risingwave.svc.cluster.local:4567/dev
NOTICE:  relation "pipeline_applied" already exists, skipping
mktemp: Read-only file system
```

**No pipeline file can be applied on QA today** — this is not specific to Brand, and it
would have blocked the cutover the moment the Kafka values landed.

It went unnoticed because the August run carried a smoke payload and predates the
rendering step, so nothing had ever called `mktemp` on this path.

## The fix

An `emptyDir` mounted at `/tmp`, plus `TMPDIR=/tmp`. `readOnlyRootFilesystem: true`,
`runAsNonRoot`, the dropped capabilities and the seccomp profile are all unchanged — the
hardening is right, it just needed somewhere to write.

Verified on the rendered overlay, not the diff: `kubectl kustomize deploy/overlays/qa`
produces a Job with `readOnlyRootFilesystem: true`, one `emptyDir` volume, and the mount
at `/tmp`.

## How it was found

A throwaway canary pipeline (`pipelines/canary/`) that depends on nothing outside
RisingWave, run with `PIPELINE_DIR` pointed at it, so a failure could only be the
delivery path. Both are temporary and come out once Brand is live.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
git push -q origin "$BRANCH"
gh pr create --repo "$REPO" --base master --head "$BRANCH" \
  --title "fix: give the apply Job a writable /tmp -- no pipeline file can be applied without it" \
  --body-file "$T/body.md"
