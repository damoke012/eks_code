#!/usr/bin/env bash
#
# rw-disable-bootstrap-dev.sh -- set bootstrap.enabled false in values-dev.yaml.
#
# PR #97 merged with bootstrap.enabled TRUE on dev, on the belief that dev's
# four objects already existed so the hook would be an idempotent no-op. Three
# of the four were fine; the fourth was not:
#
#   role rw_entity_app exists, leaving its password alone
#   database entities exists
#   schema employee
#   ERROR:  permission denied for database entities
#
# Dev's admin user (PG_USER) can connect to `entities` but cannot CREATE in it.
# The database was created by hand on 2026-10-09 and the admin does not own it.
# "Idempotent" was true of the SQL and false of the PERMISSIONS.
#
# This matters beyond a failed Job: the hook is a Sync hook at wave 0 and
# etl-pipeline-apply is wave 1, so a failing wave 0 means NOTHING applies on
# dev. A merge broke a working environment, which is the exact thing the
# off-by-default design was meant to prevent -- and it was defeated by turning
# it on for dev in the same PR.
#
# Setting it false restores dev to precisely its previous behaviour. The hook
# stays in the chart, off everywhere, until it can handle a database it does
# not own.

set -euo pipefail

D=/tmp/rwboot; rm -rf "$D"
gh repo clone variant-inc/risingwave-pipeline "$D" -- --depth 1 -q
cd "$D"

python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path("deploy/chart/values-dev.yaml")
s = p.read_text()
pat = re.compile(r'^(\s*)enabled:\s*true\s*$', re.M)
# Only the one inside the bootstrap block. Find bootstrap:, then its enabled.
m = re.search(r'^bootstrap:\s*$', s, re.M)
if not m:
    print("ABORT - no bootstrap block in values-dev.yaml"); sys.exit(1)
tail = s[m.end():]
em = pat.search(tail)
if not em:
    print("ABORT - bootstrap.enabled: true not found"); sys.exit(1)
start = m.end() + em.start()
end = m.end() + em.end()
s = s[:start] + em.group(1) + "enabled: false" + s[end:]
p.write_text(s)
print("set bootstrap.enabled false")
PY

python3 -c "
import yaml
d=yaml.safe_load(open('deploy/chart/values-dev.yaml'))
b=d['bootstrap']
print('bootstrap:', b)
assert b['enabled'] is False, 'NOT disabled'
assert 'appSecret' in d, 'appSecret lost'
print('appSecret still present:', d['appSecret']['enabled'])
"

git checkout -q -b fix/disable-bootstrap-on-dev
git add deploy/chart/values-dev.yaml
git --no-pager diff --cached | cat
echo
echo "Clone: $D"
