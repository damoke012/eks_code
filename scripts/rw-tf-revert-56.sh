#!/usr/bin/env bash
#
# rw-tf-revert-56.sh -- revert PR #56 on iaac-risingwave-onprem.
#
# WHY. #56 changed main.tf to match the LIVE DEV estate: two role tags, three
# bucket tags, and an inline IAM policy replaced by a managed policy plus
# attachment. It was written on the belief that this module had never applied
# anywhere and that dev was the environment to adopt.
#
# Both halves of that were wrong, established afterwards:
#
#   * QA's state EXISTS -- s3://lazy-tf-state-425rbol87rmn6c7m/
#     iaac/risingwave/op-usxpress-qa.tfstate, serial 2, 23 resources -- and it
#     manages `aws_iam_role_policy.risingwave_s3`, the INLINE form. So the next
#     QA apply would DESTROY the inline policy granting RisingWave its S3
#     access and create a replacement. QA has TfApply = true, so that is one
#     Octopus deploy away, unannounced, to a working environment.
#
#   * DEV is not an environment on this Octopus project at all. Its only
#     scoped variables are qa (Environments-602) and production
#     (Environments-41). Dev's RisingWave estate was built entirely by hand,
#     which is why its role carries an attached managed policy and no inline
#     one. Dev is not what this module describes, and adopting it would be its
#     own migration rather than a redefinition here.
#
# So the module was correct before #56. The tags go too: QA's state predates
# them, so leaving them in would still show a diff on a plan that must come
# back clean.
#
# The real lesson, worth more than the revert: I compared the module against
# the WRONG environment. "Does the config match reality" is only meaningful
# against the environment the config actually governs -- which is the one
# holding its state, not the one that happens to be reachable.
#
# Writes a branch and shows the diff. Does not push.

set -euo pipefail

D=$(mktemp -d)
gh repo clone variant-inc/iaac-risingwave-onprem "$D/repo" -- --depth 1 -q
cd "$D/repo"

SUBJ="fix(terraform): describe the live dev estate"
SHA=$(git log --format='%H %s' -40 | grep -F "$SUBJ" | head -1 | cut -d' ' -f1)
if [ -z "$SHA" ]; then
  echo "ABORT - could not find the #56 commit in the last 40 on main"
  git log --oneline -10
  exit 1
fi
echo "reverting $SHA"
git log -1 --format='  %s' "$SHA"

git checkout -q -b fix/revert-56-wrong-reference-environment
git revert --no-edit --no-commit "$SHA"

echo
if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=deploy/terraform init -backend=false -no-color >/dev/null 2>&1 || true
  terraform -chdir=deploy/terraform validate -no-color || echo "VALIDATE FAILED"
else
  echo "terraform absent - not a validation failure"
fi

echo
echo "=== the inline policy must be BACK ==="
grep -n 'aws_iam_role_policy"' deploy/terraform/main.tf || echo "** NOT RESTORED **"
echo "=== and the managed pair GONE ==="
if grep -q 'aws_iam_policy" "risingwave_s3"' deploy/terraform/main.tf; then
  echo "** STILL PRESENT - revert incomplete **"
else
  echo "ok, absent"
fi
echo "=== tags should be gone too ==="
grep -c 'tags = {' deploy/terraform/main.tf || true

echo
git --no-pager diff --cached -- deploy/terraform/main.tf | cat
echo
echo "Clone: $D/repo"
