#!/usr/bin/env python3
"""File the plaintext Postgres CDC credential found in pipelines/employee/100-Sources.rw.

Found on 2026-09-09 while verifying INFRA-1637, and OUT OF THAT TICKET'S SCOPE: 1637 covers
Confluent credentials, and every Confluent property in that file is now a `secret` reference.
This is a different credential that has therefore never been anyone's action item.

Carries no credential material, no hostname and no database name. Whoever picks this up
reads them from the file; they do not belong in a ticket, in this repo, or in chat.

DRY-RUN BY DEFAULT. Pass --go to create.
  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
  python3 scripts/file-employee-cdc-plaintext.py
  python3 scripts/file-employee-cdc-plaintext.py --go
"""
import base64, json, os, sys, urllib.error, urllib.parse, urllib.request

GO = "--go" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")

TITLE = "SECURITY: plaintext Postgres CDC credentials in pipelines/employee/100-Sources.rw"
LABELS = ["security", "secrets", "risingwave", "onprem"]

BODY = """Found 2026-09-09 while verifying INFRA-1637. Not covered by that ticket, which scopes Confluent credentials only — so this has never been on anyone's list.

WHAT
`pipelines/employee/100-Sources.rw` on `master` of variant-inc/risingwave-pipeline defines `pg_employees_source` as a postgres-cdc source with connector, hostname, port, username, password, database name, schema, slot and publication all written as literals. Line 52 is the password.

WHY IT MATTERS MORE THAN A NORMAL APP PASSWORD
Postgres CDC requires a role with REPLICATION privilege plus read access to the published tables. That is a privileged database account, not a read-only application user, and it can stream the contents of every table in the publication.

SCOPE, STATED PLAINLY
The repository is corporate GitHub Enterprise, so exposure is internal rather than public. The file is currently excluded from deployment — the QA cutover's EXCLUDE_RE holds back `employee/` pending application Postgres provisioning — so nothing is running with it today. Neither of those closes it: the value is in git history, and history survives every later change to repository permissions.

WHAT GOOD LOOKS LIKE — the pattern already exists in this repo
`pipelines/Brand/100-sources.rw` was converted under INFRA-1637 and now reads every Confluent property as `secret <name>` against RisingWave SECRET objects. The same file's Kafka properties are already converted. Only the postgres-cdc block was missed.

ACCEPTANCE CRITERIA
1. The postgres-cdc credentials in `employee/100-Sources.rw` are referenced through RisingWave SECRET objects, matching the Brand pattern.
2. Secret records exist in this environment's AWS Secrets Manager, created by Terraform through Octopus — not hand-created in the console.
3. The password is ROTATED, and the old value is invalidated in Postgres. Replacing without invalidating leaves the posture unchanged; that is the exact gap still open on INFRA-1637.
4. The CDC role is confirmed least-privilege: REPLICATION plus SELECT on the published tables, nothing more.
5. A repository-wide sweep confirms no other literal credential remains — this one was missed because the search was for Confluent, and the file's own header truthfully says only that SASL credentials were removed.

NOTE ON HOW THIS WAS MISSED
INFRA-1637's header comment in this file claims exactly what it did — "Confluent Cloud SASL credentials are referenced via RisingWave SECRET objects" — and does not claim the file is free of plaintext. The Brand file does make that broader claim, and is accurate. The narrower wording was correct and was read as the broader one."""


def token():
    t = os.environ.get("ATLASSIAN_TOKEN") or os.environ.get("CONFLUENCE_TOKEN")
    if t:
        return t.strip()
    sys.exit("No token: read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo")


AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{token()}".encode()).decode()


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method, headers={
        "Authorization": AUTH, "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:400]}


# Jira reports an unauthorised read as 404 and an unauthorised create as 400 "project does
# not exist" -- neither says "bad token". Preflight first. See lint-jira-preflight.sh.
s, r = api("GET", "/rest/api/3/myself")
if s != 200:
    print(f"!! cannot authenticate to {BASE} (HTTP {s})")
    print("   read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo")
    sys.exit(1)
print(f"authenticated as {r.get('displayName')}\n")

s, proj = api("GET", "/rest/api/3/project/INFRA")
if s != 200:
    sys.exit(f"cannot read project INFRA ({s}): {proj}")
types = {it["name"]: it["id"] for it in proj.get("issueTypes", [])}

# An API-created ticket lands in the BACKLOG, not the active sprint -- move it on the board.
s, sr = api("GET", "/rest/api/3/search?jql=" +
            urllib.parse.quote('project=INFRA AND summary ~ "plaintext Postgres CDC"') + "&maxResults=5")
hits = [h["key"] for h in sr.get("issues", [])] if s == 200 else []
if hits:
    print(f"~~ similar tickets already exist: {hits} -- check before creating\n")

if not GO:
    print(f"[DRY RUN] would create a {list(types)[0] if types else 'Task'}-style Task in INFRA:\n")
    print(f"  summary: {TITLE}")
    print(f"  labels : {LABELS}")
    print(f"\n{BODY}\n")
    print("Re-run with --go to create.")
    sys.exit(0)

fields = {"project": {"key": "INFRA"}, "summary": TITLE[:250],
          "issuetype": {"id": types.get("Task")},
          "labels": LABELS,
          "description": {"type": "doc", "version": 1, "content":
                          [{"type": "paragraph", "content": [{"type": "text", "text": p}]}
                           for p in BODY.split("\n\n") if p.strip()]}}
s, resp = api("POST", "/rest/api/3/issue", {"fields": fields})
if s == 201:
    print(f"  + {resp['key']}  {TITLE[:60]}")
    print(f"  {BASE}/browse/{resp['key']}")
    print("  NOTE: API-created issues land in the BACKLOG. Move it onto the sprint on the board.")
else:
    print(f"  !! FAILED {s} {resp}")
