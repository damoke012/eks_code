#!/usr/bin/env bash
#
# rw-values-qa-stage.sh -- stage values-qa.yaml so a promotion to QA is picked
# up at deploy time with every value already present.
#
# Five edits, none of which un-excludes anything. QA keeps running exactly the
# eight files it runs today.
#
#   1. REAPPLY_CHANGED: "true"
#      apply.sh line 191 hits `exit 1` on any file whose rendered content
#      changed since it was applied -- failing the WHOLE Job, not just that
#      file. Dev sets this; QA did not. Tim edits files, so without it his next
#      edit takes QA red. Prod keeps the default false, where forward-only
#      discipline is the point.
#
#   2. POSTGRES_SERVER / _HOST_NAME / _ENTITY_DB / _INTERNAL_PORT
#      SERVER and ENTITY_DB were present-and-EMPTY -- the exact signature that
#      wedged QA for nine days. The comment justifying that is also wrong and is
#      replaced: apply.sh selects files FIRST and then demands only what they
#      need ("selected 15 of 25 discovered, excluded 10", then the error).
#      Host measured on op-qa: pg-postgresql, same service name as dev.
#
#   3. MONGODB_DATABASE_BRAND: rw_qa, MONGODB_COLLECTION_BRAND: brands
#      Dev runs rw_dev/brands. Dev and QA share ONE non-prod Atlas user and the
#      connection string names no database, so rw_qa is the ONLY thing keeping
#      QA's Brand sink out of dev's collection. Copying dev's block would be
#      silent cross-environment contamination.
#
#   4. the "Three entries" comment, which sat above a list of ten.
#
#   5. three ExternalSecret entries: MONGODB_CONNECTION_STRING,
#      POSTGRES_ENTITY_USER, POSTGRES_ENTITY_PASSWORD.
#      ⚠️ Safe ONLY because both AWS secrets were created in the QA account on
#      2026-10-15. ESO writes a PARTIAL secret when a key cannot resolve and the
#      pod then dies at container creation with RESTARTS 0.
#
# Every anchor captures its indentation rather than assuming it: the first draft
# assumed four spaces, the file uses two, and four of five edits silently did
# nothing. The hits counter caught it; a diff alone might not have.
#
# Writes a branch and shows the diff. Does not push.

set -euo pipefail

D=$(mktemp -d)
gh repo clone variant-inc/risingwave-pipeline "$D/repo" -- --depth 1 -q
cd "$D/repo"

python3 - deploy/chart/values-qa.yaml <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
hits = 0
H = "pg-postgresql.risingwave.svc.cluster.local"

# Every anchor CAPTURES its indent rather than assuming it. The first version of
# this patch assumed 4 spaces, the file uses 2, and 4 of 5 edits silently did
# nothing -- the hits counter is what caught it.

p1 = re.compile(r'^([ \t]*)EXCLUDE_STRICT: "true"$', re.M)
m = p1.search(s)
if m:
    i = m.group(1)
    r = (m.group(0) + "\n"
         + i + "# QA works like dev. Without this, apply.sh hits `exit 1` on any file\n"
         + i + "# whose rendered content changed since it was applied -- failing the\n"
         + i + "# WHOLE Job, not just that file. Tim edits files; on QA that must\n"
         + i + "# re-apply. Prod keeps the default false, where forward-only matters.\n"
         + i + 'REAPPLY_CHANGED: "true"')
    s = p1.sub(lambda _: r, s, count=1); hits += 1

p2 = re.compile(r"^([ \t]*)# Empty in QA's overlay\..*?^[ \t]*POSTGRES_PORT:[ \t]*\"5432\"$", re.M | re.S)
m = p2.search(s)
if m:
    i = m.group(1)
    r = "\n".join([
        i + "# ⚠️ The comment that stood here was WRONG. It claimed apply.sh validates",
        i + "# every runtime value BEFORE applying EXCLUDE_RE, so these had to be",
        i + "# present-and-empty. It does not: it selects files first, then demands",
        i + "# only the values those files need. Measured 2026-10-14 -- the log reads",
        i + '# "selected 15 of 25 discovered, excluded 10" and only THEN errors.',
        i + "#",
        i + "# Empty was never required, and an empty value is the exact signature",
        i + "# that wedged QA for nine days: present and blank reads as configured.",
        i + "#",
        i + "# Host measured on op-qa 2026-10-15: the service is pg-postgresql, the",
        i + "# same name dev uses. POSTGRES_HOST_NAME is what PR #97's hook requires.",
        i + "POSTGRES_SERVER:        " + H,
        i + "POSTGRES_HOST_NAME:     " + H,
        i + "POSTGRES_ENTITY_DB:     entities",
        i + 'POSTGRES_PORT:          "5432"',
        i + 'POSTGRES_INTERNAL_PORT: "5432"',
    ])
    s = p2.sub(lambda _: r, s, count=1); hits += 1

p3 = re.compile(r'^([ \t]*)KAFKA_SCHEMA_REGISTRY_MESSAGE: .*$', re.M)
m = p3.search(s)
if m:
    i = m.group(1)
    r = (m.group(0) + "\n\n"
         + i + "# Dev runs rw_dev/brands. Dev and QA share ONE non-prod Atlas user and\n"
         + i + "# the connection string names no database, so rw_qa here is the ONLY\n"
         + i + "# thing keeping QA's Brand sink out of dev's collection. Nothing errors.\n"
         + i + "MONGODB_DATABASE_BRAND:   rw_qa\n"
         + i + "MONGODB_COLLECTION_BRAND: brands")
    s = p3.sub(lambda _: r, s, count=1); hits += 1

old = """# Three entries. op-usxpress-qa/... is built by etl.prefix from `environment`,
# so these paths cannot be copied wrong between environments."""
new = """# op-usxpress-qa/... is built by etl.prefix from `environment`, so these paths
# cannot be copied wrong between environments. FIVE paths now: root, postgres,
# kafka, mongodb, entity. (The old comment said "three entries" above a list of
# ten -- it meant paths, and it was already stale.)
#
# ⚠️ ORDER: the AWS secret must EXIST before its entry appears here. ESO writes
# a PARTIAL secret when a key cannot resolve -- SecretSyncedError, while still
# writing what it could -- and the pod then dies at container creation with
# RESTARTS 0. mongodb and entity were created in the QA account on 2026-10-15,
# which is what makes the three entries below safe to add."""
if old in s:
    s = s.replace(old, new, 1); hits += 1

p5 = re.compile(
    r'^([ \t]*)- secretKey: KAFKA_SCHEMA_REGISTRY_PASSWORD\n'
    r'([ \t]*)path: risingwave/kafka\n'
    r'[ \t]*property: kafka__schema_registry_api_secret$', re.M)
m = p5.search(s)
if m:
    i, j = m.group(1), m.group(2)
    r = (m.group(0) + "\n"
         + i + "- secretKey: MONGODB_CONNECTION_STRING\n"
         + j + "path: risingwave/mongodb\n"
         + j + "property: MONGODB_CONNECTION_STRING\n"
         + i + "- secretKey: POSTGRES_ENTITY_USER\n"
         + j + "path: risingwave/entity\n"
         + j + "property: username\n"
         + i + "- secretKey: POSTGRES_ENTITY_PASSWORD\n"
         + j + "path: risingwave/entity\n"
         + j + "property: password")
    s = p5.sub(lambda _: r, s, count=1); hits += 1

p.write_text(s)
print("edits applied:", hits, "(want 5)")
PY

echo
python3 -c "
import yaml,sys
d=yaml.safe_load(open('deploy/chart/values-qa.yaml'))
c=d['config']; e=d['externalSecret']['data']
need=['REAPPLY_CHANGED','POSTGRES_SERVER','POSTGRES_HOST_NAME','POSTGRES_ENTITY_DB',
      'POSTGRES_INTERNAL_PORT','MONGODB_DATABASE_BRAND','MONGODB_COLLECTION_BRAND']
miss=[k for k in need if not c.get(k)]
print('YAML parses. config keys:', len(c), ' externalSecret entries:', len(e))
print('paths:', sorted({x['path'] for x in e}))
print('MONGODB_DATABASE_BRAND =', repr(c.get('MONGODB_DATABASE_BRAND')), '(must be rw_qa, NOT rw_dev)')
print('EXCLUDE_RE untouched:', c['EXCLUDE_RE'].count('100-Brand') == 2)
if miss: print('** MISSING:', miss); sys.exit(1)
" || echo "VALIDATION FAILED"

echo
git checkout -q -b feat/qa-stage-for-promotion
git --no-pager diff -- deploy/chart/values-qa.yaml | cat
echo
echo "Clone: $D/repo"
echo "No exclusion was dropped. QA still runs the same eight files."
