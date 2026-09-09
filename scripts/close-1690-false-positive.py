#!/usr/bin/env python3
"""Withdraw INFRA-1690. It was a false positive and the defect was in my check, not the code.

Filed 2026-09-09 claiming a plaintext Postgres CDC password in
pipelines/employee/100-Sources.rw. There is none. Line 52 holds the placeholder
%POSTGRES_ENTITY_PASSWORD%, correctly uppercase, exactly the token apply.sh renders.

A wrong security ticket against a colleague's work does not get left on the board to be
quietly forgotten, so this comments with the cause and closes it.

DRY-RUN BY DEFAULT. Pass --go to write.
  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
  python3 scripts/close-1690-false-positive.py
  python3 scripts/close-1690-false-positive.py --go
"""
import base64, json, os, sys, urllib.error, urllib.request

GO = "--go" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
KEY = "INFRA-1690"
WANT = "Done"

BODY = """2026-09-09 — WITHDRAWN. False positive. There is no plaintext credential, and the defect was in my check rather than in the code.

WHAT IS ACTUALLY THERE
`pipelines/employee/100-Sources.rw` line 52 reads `password = '%POSTGRES_ENTITY_PASSWORD%'` — a placeholder token, correctly uppercase, exactly the form `apply.sh` renders at run time from the environment. It is the right pattern, not a hardcoded secret.

WHY I REPORTED IT WRONGLY
I redacted the line with two sed expressions run in sequence. The first rewrote a `%TOKEN%` placeholder to a safe label; the second rewrote any remaining quoted string to an unsafe label. Both ran on the same line, so the second matched the output of the first and overwrote the safe verdict with the unsafe one. Every placeholder in that file would have been reported as a literal. The check could only ever produce one answer.

WHAT THE PROPER SWEEP FOUND
`scripts/scan-pipeline-plaintext.sh` was written afterwards for AC5 here, and evaluates each line once with an ordered case rather than chained substitutions. Across all 24 `.rw`/`.sql` files on `master`: 7 RisingWave SECRET references, 3 placeholder tokens, 0 literal usernames, and 0 literal secrets.

So INFRA-1637's conversion is complete on `master` — Brand, employee and secret_manager all reference secrets or render placeholders, with nothing committed. That is a better result than the ticket that raised this claimed, and it is worth recording plainly.

WHAT REMAINS OPEN, AND IT IS NOT THIS
INFRA-1637 stays open for the reason already recorded there: the old Confluent key was replaced but never revoked, so it remains valid and present in git history. That needs a Confluent Cloud administrator other than Tim.

Closing this as withdrawn. No work is required from anyone."""


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


s, r = api("GET", "/rest/api/3/myself")
if s != 200:
    sys.exit(f"!! cannot authenticate to {BASE} (HTTP {s})")
print(f"authenticated as {r.get('displayName')}\n")

s, cur = api("GET", f"/rest/api/3/issue/{KEY}?fields=summary,status")
if s != 200:
    sys.exit(f"cannot read {KEY} ({s})")
now = cur["fields"]["status"]["name"]
print(f"{KEY}  [{now}]  {cur['fields']['summary'][:60]}")

if not GO:
    print(f"\n[DRY RUN] would comment ({len(BODY)} chars) and transition {now} -> {WANT}\n")
    print(BODY)
    sys.exit(0)

adf = {"type": "doc", "version": 1, "content":
       [{"type": "paragraph", "content": [{"type": "text", "text": p}]}
        for p in BODY.split("\n\n") if p.strip()]}
s, _ = api("POST", f"/rest/api/3/issue/{KEY}/comment", {"body": adf})
print(f"  comment: {'OK' if s in (200, 201) else f'FAIL {s}'}")

# Resolve the transition BY NAME -- ids differ per workflow.
s, tr = api("GET", f"/rest/api/3/issue/{KEY}/transitions")
match = [t for t in tr.get("transitions", []) if t["to"]["name"].lower() == WANT.lower()]
if not match:
    print(f"  transition to '{WANT}' unavailable. Reachable: "
          + ", ".join(t["to"]["name"] for t in tr.get("transitions", [])))
    sys.exit(0)
s, r2 = api("POST", f"/rest/api/3/issue/{KEY}/transitions", {"transition": {"id": match[0]["id"]}})
print(f"  {now} -> {WANT}: {'OK' if s in (200, 204) else f'FAIL {s} {r2}'}")
