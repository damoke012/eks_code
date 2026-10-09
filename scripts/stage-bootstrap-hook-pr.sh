#!/usr/bin/env bash
# Stage the database-bootstrap hook as a PR branch in variant-inc/risingwave-pipeline.
#
# Builds from a FRESH clone, never from wip/ -- a PR assembled by copying a stale
# wip file reverted an ApplicationSet's repoURL and took delivery down for 18
# hours on 2026-08-20 (CLAUDE.md rule 7).
#
# Read-only against every cluster. It clones, edits, prints the diff and STOPS.
# It does not commit, push or open a PR: read the diff first.
set -euo pipefail

REPO=variant-inc/risingwave-pipeline
BRANCH=feat/bootstrap-database-hook
WORK=$(mktemp -d)
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../wip/onprem-app-cicd/bootstrap" && pwd)

echo "== cloning $REPO fresh into $WORK"
gh repo clone "$REPO" "$WORK/repo" -- --depth 1 >/dev/null
cd "$WORK/repo"
git checkout -q -b "$BRANCH"

CHART=deploy/chart
cp "$SRC_DIR/bootstrap-database-job.yaml" "$CHART/templates/bootstrap-database-job.yaml"
echo "== added $CHART/templates/bootstrap-database-job.yaml"

python3 - "$CHART" <<'PY'
import sys, pathlib
chart = pathlib.Path(sys.argv[1])

# ---- 1. values.yaml: the defaults, OFF ---------------------------------------
v = chart / "values.yaml"
s = v.read_text()
assert "bootstrap:" not in s, "values.yaml already has a bootstrap block"
s = s.rstrip() + """

# Create the database this pipeline's SQL expects, before applying any of it.
#
# OFF here on purpose. In a repo where every environment shares one branch, a new
# behaviour that defaults ON reaches production on merge. An environment opts in
# by setting bootstrap.enabled in its OWN values file.
#
# Dev's objects were created by hand on 2026-10-09; this is that work as code.
bootstrap:
  enabled: false
  database: ""             # e.g. entities
  role: ""                 # the owning role, created with LOGIN REPLICATION
  schemas: []              # e.g. [employee]
  publication: ""          # a CDC publication FOR ALL TABLES; empty skips it
  # The owning role's password. This key must ALSO appear in externalSecret.data
  # or it will not exist in the Secret and the Job will not start.
  passwordKey: BOOTSTRAP_ROLE_PASSWORD
  # Admin credentials: CREATE DATABASE, a REPLICATION role and a publication FOR
  # ALL TABLES all require superuser.
  adminUserKey: PG_USER
  adminPasswordKey: PG_PASSWORD
"""
v.write_text(s)
print("  values.yaml: bootstrap defaults added (enabled: false)")

# ---- 2. job.yaml: move the applier to wave 1 --------------------------------
j = chart / "templates" / "job.yaml"
s = j.read_text()
old = '    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded\n'
assert s.count(old) == 1, "job.yaml hook-delete-policy line not found exactly once"
assert "sync-wave" not in s, "job.yaml already has a sync-wave"
s = s.replace(old, old + '    # Wave 1: the bootstrap hook is wave 0, so the database exists before\n'
                         '    # any SQL is applied to it. With bootstrap disabled this is a single\n'
                         '    # wave and the ordering is identity.\n'
                         '    argocd.argoproj.io/sync-wave: "1"\n')
j.write_text(s)
print("  job.yaml: apply hook moved to sync-wave 1")

# ---- 3. values-dev.yaml: turn it on, and add the credential -----------------
d = chart / "values-dev.yaml"
s = d.read_text()
assert "bootstrap:" not in s, "values-dev.yaml already has a bootstrap block"
assert "BOOTSTRAP_ROLE_PASSWORD" not in s, "values-dev.yaml already has the key"

# Prepend the entry to externalSecret.data. Order in the list is irrelevant; the
# Job's env list is GENERATED from it, so the two cannot drift apart.
marker = "externalSecret:\n"
assert s.count(marker) == 1, "values-dev.yaml externalSecret block not found once"
head, tail = s.split(marker, 1)
dmark = "  data:\n"
assert tail.count(dmark) >= 1, "externalSecret.data not found in values-dev.yaml"
pre, post = tail.split(dmark, 1)
entry = ("    # The rw_entity_app password, created by hand 2026-10-09 and now also\n"
         "    # declared in iaac-risingwave-onprem's secrets.tf.\n"
         "    - secretKey: BOOTSTRAP_ROLE_PASSWORD\n"
         "      path: risingwave/entity\n"
         "      property: password\n")
s = head + marker + pre + dmark + entry + post

s = s.rstrip() + """

# Dev only. These four objects exist already -- every statement is idempotent, so
# the first run on dev is a no-op that proves the hook before any environment
# relies on it to create something.
bootstrap:
  enabled: true
  database: entities
  role: rw_entity_app
  schemas: [employee]
  publication: rw_employee_pub
"""
d.write_text(s)
print("  values-dev.yaml: bootstrap enabled + BOOTSTRAP_ROLE_PASSWORD wired")
PY

echo
echo "================ git diff ================"
git --no-pager diff
git --no-pager status --short
echo "========================================="
echo
echo "Clone is at: $WORK/repo"
echo "If the diff is right, from that directory:"
echo "  git add -A && git commit -m 'feat(chart): bootstrap the application database as a sync hook'"
echo "  git push -u origin $BRANCH"
echo "  gh pr create --repo $REPO --base master --fill"
