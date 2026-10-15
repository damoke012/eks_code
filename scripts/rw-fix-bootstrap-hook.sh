#!/usr/bin/env bash
#
# rw-fix-bootstrap-hook.sh -- stop the bootstrap hook failing on a database it
# does not own.
#
# What happened on dev 2026-10-15:
#
#   database entities exists
#   schema employee
#   ERROR:  permission denied for database entities
#
# CREATE SCHEMA needs CREATE on the database. Dev's `entities` was created by
# hand on 2026-10-09 and the admin role does not own it. CREATE PUBLICATION FOR
# ALL TABLES would have been the next failure for the same reason.
#
# ⚠️ The cost was not a failed Job. This is a Sync hook at wave 0 and
# etl-pipeline-apply is wave 1, so the failure stopped the WHOLE pipeline
# applying on dev. A bootstrap step must never be able to do that.
#
# The fix: ask the database, before touching it, whether we may create in it.
#
#   * An environment where this hook CREATED the database owns it, has CREATE,
#     and proceeds exactly as before. That is every new environment -- the case
#     the hook exists for.
#   * An environment where the database pre-existed and is owned by someone
#     else prints the exact GRANT needed and exits 0, leaving wave 1 to run.
#
# Reporting and continuing is right here because the hook is a convenience for
# a new environment, not a correctness gate for an existing one. If the schema
# really is missing, the applier at wave 1 fails on the actual statement that
# needs it -- a smaller, more precise failure than stopping everything.

set -euo pipefail

D=/tmp/rwhook; rm -rf "$D"
gh repo clone variant-inc/risingwave-pipeline "$D" -- --depth 1 -q
cd "$D"

python3 - <<'PY'
import pathlib, sys
p = pathlib.Path("deploy/chart/templates/bootstrap-database-job.yaml")
s = p.read_text()

anchor = "              # ---- schemas ---------------------------------------------------"
if anchor not in s:
    print("ABORT - schemas anchor not found"); sys.exit(1)

guard = '''              # ---- may we create in it? --------------------------------------
              # CREATE SCHEMA needs CREATE on the database, and CREATE PUBLICATION
              # FOR ALL TABLES needs more still. A database this hook did not
              # create may be owned by somebody else: dev's `entities` was made by
              # hand on 2026-10-09 and the admin does not own it, so these steps
              # failed and -- at sync wave 0 -- stopped the whole pipeline.
              #
              # Report and skip, never fail. A new environment created the database
              # a moment ago, owns it, and does not reach this branch.
              ME=$(exists "$BOOTSTRAP_DB" "select current_user")
              CAN=$(exists "$BOOTSTRAP_DB" "select has_database_privilege('${BOOTSTRAP_DB}', 'CREATE')")
              if [ "$CAN" != "t" ]; then
                echo "  SKIPPING schemas and publication"
                echo "    ${ME} has no CREATE on database ${BOOTSTRAP_DB}"
                echo "    This hook did not create that database, so it does not own it."
                echo "    To enable: GRANT CREATE ON DATABASE ${BOOTSTRAP_DB} TO ${ME};"
                echo "bootstrap: done (schemas and publication skipped)"
                printf "show wal_level;\\n" | psql -v ON_ERROR_STOP=1 -t -A -d "$BOOTSTRAP_DB"
                exit 0
              fi

'''
s = s.replace(anchor, guard + anchor, 1)
p.write_text(s)
print("guard inserted")
PY

echo
echo "=== the shell inside args: must still parse ==="
python3 - <<'PY'
import pathlib, re, sys
s = pathlib.Path("deploy/chart/templates/bootstrap-database-job.yaml").read_text()
m = re.search(r'^          args:\n            - \|\n(.*?)^      \{\{- if', s, re.S | re.M)
if not m:
    print("ABORT - could not extract the args block"); sys.exit(1)
body = "\n".join(l[14:] for l in m.group(1).splitlines())
pathlib.Path("/tmp/hook.sh").write_text(body)
print(f"extracted {len(body.splitlines())} lines to /tmp/hook.sh")
PY
bash -n /tmp/hook.sh && echo "shell syntax OK" || echo "** SHELL SYNTAX FAILED **"

echo
echo "=== guard present, and before the schema loop ==="
grep -n 'has_database_privilege\|---- schemas\|SKIPPING schemas' deploy/chart/templates/bootstrap-database-job.yaml

echo
git checkout -q -b fix/bootstrap-skip-unowned-database
git add deploy/chart/templates/bootstrap-database-job.yaml
git --no-pager diff --cached | cat
echo
echo "Clone: $D"
