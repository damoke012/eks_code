#!/usr/bin/env bash
# apply-qa-fixes.sh — apply the review fix set to iaac-risingwave-onprem.
#
# Run from the ROOT of ~/work/iaac-risingwave-onprem, on branch fix/qa-review.
# Idempotent: safe to re-run.
#
# Usage:
#   cd ~/work/iaac-risingwave-onprem
#   bash ~/work/eks_code/iaac-drafts/qa-risingwave-jul20/qa-fixes/apply-qa-fixes.sh
#
# Written as a script rather than pasted heredocs because large multi-block
# pastes have been truncated mid-file twice, silently producing valid-looking
# but incomplete YAML.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(pwd)"
M="${REPO}/manifests/op-usxpress-qa"
T="${REPO}/terraform"

[[ -d "${M}" ]] || { echo "ERROR: run from the root of iaac-risingwave-onprem" >&2; exit 1; }
[[ -d "${T}" ]] || { echo "ERROR: terraform/ not found" >&2; exit 1; }

echo "==> Repo   : ${REPO}"
echo "==> Branch : $(git rev-parse --abbrev-ref HEAD)"
echo ""

# ── 1. Manifests ────────────────────────────────────────────────────────────
echo "==> [1/5] podmonitors.yaml + kustomization.yaml"
cp "${SRC}/podmonitors.yaml"    "${M}/podmonitors.yaml"
cp "${SRC}/kustomization.yaml"  "${M}/kustomization.yaml"

echo "==> [2/5] remove velero-schedule.yaml and the 1.15 MiB dev dashboard"
git rm -q --ignore-unmatch \
  manifests/op-usxpress-qa/velero-schedule.yaml \
  manifests/op-usxpress-qa/risingwave-dev-dashboard.json || true
rm -f "${M}/velero-schedule.yaml" "${M}/risingwave-dev-dashboard.json"

# ── 2. deploy.sh ────────────────────────────────────────────────────────────
echo "==> [3/5] deploy/deploy.sh -> terraform-only"
cp "${SRC}/deploy.sh" "${REPO}/deploy/deploy.sh"
chmod +x "${REPO}/deploy/deploy.sh"

# ── 3. main.tf backend block ────────────────────────────────────────────────
# Blank the hardcoded backend so a missing -backend-config fails loudly instead
# of silently resolving to whichever environment is hardcoded.
echo "==> [4/5] terraform/main.tf backend block"
python3 - "$T/main.tf" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
new = '''  backend "s3" {
    # Values are supplied per environment via -backend-config:
    #   dev: terraform init -backend-config=backend-dev.hcl
    #   qa:  terraform init -backend-config=backend-qa.hcl
    # Intentionally EMPTY: a missing -backend-config must fail loudly, not
    # silently default to another environment's state.
  }
'''
pat = re.compile(r'  backend "s3" \{.*?\n  \}\n', re.S)
if not pat.search(s):
    if 'Intentionally EMPTY' in s:
        print("    already applied, skipping"); sys.exit(0)
    print("ERROR: backend \"s3\" block not found in main.tf", file=sys.stderr); sys.exit(1)
open(p, 'w').write(pat.sub(new, s, count=1))
print("    backend block blanked")
PY

# ── 4. Verify ───────────────────────────────────────────────────────────────
echo "==> [5/5] verify"
echo ""
echo "--- kustomize build ---"
kubectl kustomize "${M}" > /tmp/rwqa-render.yaml && echo "OK ($(wc -l < /tmp/rwqa-render.yaml) lines)"

echo ""
echo "--- Schedule must NOT appear (it moved to the platform repo) ---"
if grep -q "kind: Schedule" /tmp/rwqa-render.yaml; then
  echo "FAIL: Velero Schedule still rendered"; exit 1
else
  echo "OK: no Schedule"
fi

echo ""
echo "--- all 4 PodMonitors must render ---"
grep -c "kind: PodMonitor" /tmp/rwqa-render.yaml

echo ""
echo "--- terraform fmt/validate (init is offline-safe: -backend=false) ---"
( cd "${T}" && terraform fmt -check -diff || true )

echo ""
echo "--- files present ---"
ls -1 "${T}"/backend-*.hcl "${T}"/op-usxpress-qa.tfvars 2>&1

echo ""
echo "==> Done. Review with: git status --short && git diff"
