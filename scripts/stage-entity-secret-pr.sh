#!/usr/bin/env bash
# Stage the entity secret into iaac-risingwave-onprem's secrets.tf as a PR branch.
#
# Builds from a FRESH clone. Prints the diff and STOPS -- nothing is committed,
# pushed or applied. Read-only against AWS and every cluster.
set -euo pipefail

REPO=variant-inc/iaac-risingwave-onprem
BRANCH=feat/entity-secret-in-terraform
WORK=$(mktemp -d)

echo "== cloning $REPO fresh into $WORK"
gh repo clone "$REPO" "$WORK/repo" -- --depth 1 >/dev/null
cd "$WORK/repo"
git checkout -q -b "$BRANCH"

python3 - <<'PY'
import pathlib, re
p = pathlib.Path("deploy/terraform/secrets.tf")
s = p.read_text()

assert 'resource "random_password" "entity"' not in s, "entity already declared"
assert 'aws_secretsmanager_secret" "entity"' not in s, "entity secret already declared"

# Mirror the existing generator's arguments instead of guessing at them: the
# comment above it says special=false because punctuation causes quoting bugs
# that only appear under load, and the length should not differ per secret.
m = re.search(r'resource "random_password" "postgres" \{\n(.*?)\n\}\n', s, re.S)
assert m, "could not read the random_password postgres block to mirror"
body = m.group(1)
print("  mirroring random_password arguments:")
for line in body.splitlines():
    print("   ", line.strip())

block = '''
// ── Entity application user ─────────────────────────────────────────────────
// The role the Employee CDC source authenticates as, inside the application
// database the chart's bootstrap sync hook creates. Dev's role and secret were
// created BY HAND on 2026-10-09 to unblock Tim; this is the declaration.
//
// ⚠️ ADOPT, DO NOT RECREATE. Dev's secret exists already and Terraform does not
// know it, so dev's plan shows "1 to add" until it is imported ONCE:
//
//   terraform import aws_secretsmanager_secret.entity \\
//     op-usxpress-dev/risingwave/entity
//   terraform import aws_secretsmanager_secret_version.entity \\
//     'op-usxpress-dev/risingwave/entity|3292d0e2-6d52-4e93-a508-38249acbd77d'
//
// Both, not just the first. Importing only the secret leaves the VERSION absent
// from state, so the next apply writes a new one from random_password and
// ROTATES the password dev's replication slot is authenticating with. That is
// the one change in this PR that can stop a working pipeline.
//
// Deliberately NOT `import` blocks: those are evaluated in every environment,
// and QA and prod have no entity secret, so they would fail there -- the way
// five bare import blocks broke prod's first plan.
resource "random_password" "entity" {
__BODY__
}

resource "aws_secretsmanager_secret" "entity" {
  name                    = "${local.sm_prefix}/entity"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "entity" {
  secret_id = aws_secretsmanager_secret.entity.id
  secret_string = jsonencode({
    username = "rw_entity_app"
    password = random_password.entity.result
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
'''.replace("__BODY__", body)

p.write_text(s.rstrip() + "\n" + block)
print("  secrets.tf: entity secret declared")
PY

echo
echo "================ git diff ================"
git --no-pager diff
echo "========================================="
echo
echo "Clone is at: $WORK/repo"
echo
echo "⛔ IMPORT BEFORE ANY APPLY REACHES DEV. Order matters:"
echo "   1. import the two resources into DEV state (see the comment in the diff)"
echo "   2. terraform plan -> dev must read '0 to add, 0 to change, 0 to destroy'"
echo "   3. only then merge"
