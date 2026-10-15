#!/usr/bin/env bash
#
# rw-tf-match-live.sh -- make iaac-risingwave-onprem's main.tf describe the
# environment it already names, so an import can plan clean.
#
# Measured on op-usxpress-dev 2026-10-15, module vs live. Three mismatches, and
# everything else (versioning Enabled, encryption AES256, all four public-access
# flags true, the bucket name, the role name) already agrees:
#
#   1. aws_s3_bucket.risingwave declares NO tags; live has three.
#   2. aws_iam_role.risingwave_irsa declares NO tags; live has two.
#   3. The module declares an INLINE policy (aws_iam_role_policy, name
#      "risingwave-s3-access"). Live has an ATTACHED MANAGED policy,
#      op-usxpress-dev-risingwave-s3. There is no inline policy to import, so a
#      plan would CREATE one and leave the role carrying both.
#
# The module is edited to match the environment, never the reverse: dev works,
# and a tag-stripping or policy-duplicating plan is not a fix.
#
# This writes a branch and shows the diff. It does not push and does not apply.

set -euo pipefail

D=$(mktemp -d)
gh repo clone variant-inc/iaac-risingwave-onprem "$D/repo" -- --depth 1 -q
cd "$D/repo"

python3 - <<'PY'
import pathlib, re
p = pathlib.Path("deploy/terraform/main.tf")
s = p.read_text()
hits = 0

# 1. bucket tags, exactly as live. Live values are adopted verbatim -- changing
#    a tag value is a live mutation and is not this PR's job.
old = '''resource "aws_s3_bucket" "risingwave" {
  bucket = var.s3_bucket_prefix
}'''
new = '''resource "aws_s3_bucket" "risingwave" {
  bucket = var.s3_bucket_prefix

  // Adopted verbatim from the live bucket on 2026-10-15. Without these, the
  // first plan after an import wants to STRIP them.
  tags = {
    managed-by = "onprem-platform-team"
    cluster    = var.cluster_name
    purpose    = "risingwave-state-store"
  }
}'''
if old in s:
    s = s.replace(old, new, 1); hits += 1

# 2. role tags. Live carries two, not the bucket's three -- that asymmetry is
#    the environment as built, not an oversight to tidy up here.
old = '''resource "aws_iam_role" "risingwave_irsa" {
  name               = "${var.cluster_name}-risingwave"
  assume_role_policy = data.aws_iam_policy_document.risingwave_assume_role.json
}'''
new = '''resource "aws_iam_role" "risingwave_irsa" {
  name               = "${var.cluster_name}-risingwave"
  assume_role_policy = data.aws_iam_policy_document.risingwave_assume_role.json

  // Adopted verbatim from the live role. Two tags, not the bucket's three.
  tags = {
    cluster = var.cluster_name
    purpose = "risingwave-state-store"
  }
}'''
if old in s:
    s = s.replace(old, new, 1); hits += 1

# 3. inline policy -> managed policy + attachment, matching live.
old = '''resource "aws_iam_role_policy" "risingwave_s3" {
  name   = "risingwave-s3-access"
  role   = aws_iam_role.risingwave_irsa.id
  policy = data.aws_iam_policy_document.risingwave_s3.json
}'''
new = '''// A MANAGED policy plus an attachment, not an inline policy.
//
// The live role on every environment built so far carries an attached managed
// policy named <cluster>-risingwave-s3 and has no inline policy at all. An
// aws_iam_role_policy here cannot be imported -- there is nothing to import --
// and a plan would create an inline policy alongside the attached one, leaving
// the role with two sources of S3 access and neither managed cleanly.
resource "aws_iam_policy" "risingwave_s3" {
  name   = "${var.cluster_name}-risingwave-s3"
  policy = data.aws_iam_policy_document.risingwave_s3.json
}

resource "aws_iam_role_policy_attachment" "risingwave_s3" {
  role       = aws_iam_role.risingwave_irsa.name
  policy_arn = aws_iam_policy.risingwave_s3.arn
}'''
if old in s:
    s = s.replace(old, new, 1); hits += 1

p.write_text(s)
print("edits applied:", hits, "(want 3)")
PY

echo
if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=deploy/terraform init -backend=false -no-color >/dev/null 2>&1 || true
  terraform -chdir=deploy/terraform validate -no-color || echo "VALIDATE FAILED"
  terraform -chdir=deploy/terraform fmt -check -diff deploy/terraform 2>/dev/null || true
else
  echo "terraform absent - not a validation failure"
fi

echo
git checkout -q -b fix/match-live-dev-estate
git --no-pager diff -- deploy/terraform/main.tf | cat
echo
echo "Clone: $D/repo"
echo "Two import addresses CHANGE because of edit 3:"
echo "  aws_iam_policy.risingwave_s3                 arn:aws:iam::<acct>:policy/<cluster>-risingwave-s3"
echo "  aws_iam_role_policy_attachment.risingwave_s3 <role-name>/<policy-arn>"
echo "aws_iam_role_policy.risingwave_s3 is GONE - do not try to import it."
