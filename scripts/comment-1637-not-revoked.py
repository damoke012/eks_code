#!/usr/bin/env python3
"""INFRA-1637 — record Idris's answer: the old Confluent key was REPLACED, not REVOKED.

Comment only, no transition. The ticket stays open deliberately: rotation is done, the
revocation half of the AC is not, and a replaced-but-not-revoked key is still a working
credential. Confluent Cloud administration sits with Tim, who is on leave, so the next
action is finding a second administrator rather than waiting for him.

Contains no credential material and never will. Do not paste the key into this file, this
repo, or the ticket -- the whole finding is that it is already in more places than intended.

DRY-RUN BY DEFAULT. Pass --go to write.
  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
  python3 scripts/comment-1637-not-revoked.py          # shows what it would post
  python3 scripts/comment-1637-not-revoked.py --go
"""
import base64, json, os, sys, urllib.error, urllib.request

GO = "--go" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
KEY = "INFRA-1637"

BODY = """2026-09-09 — Idris confirms the old Confluent key was REPLACED, not REVOKED.

Keeping this open. The AC has two halves and only one is met:

1. No plaintext Confluent credentials in the catalog tables — DONE, 2026-08-18, moved to
   secret references. That was the right fix and it is finished.
2. The old key revoked — NOT DONE. A replaced key is still a valid key. It remains present
   in git history, so it is a live credential with a wider audience than intended. Rotation
   without revocation leaves the security posture where it started.

Scope, stated plainly rather than alarmed: the repository is on corporate GitHub
Enterprise, so the exposure is internal rather than public. That lowers the severity. It
does not close the finding — a credential in history survives every later change to
repository permissions, and revocation is the control that makes the rotation real.

Next action is not Idris's. Confluent Cloud administration sits with Tim, who is on leave,
so this needs a second administrator rather than a wait of unknown length. Nathaniel and
Anthony are the obvious people to ask, since they are running the Confluent to S3
migration.

Two things needed before this can be closed:
- A named Confluent Cloud administrator other than Tim.
- The blast radius of the old key — read-only on one topic, or cluster-wide write? That
  decides whether this waits for Tim's return or is escalated this week.

No credential value appears in this comment, in the linked scripts, or in eks_code."""


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


# Jira answers an unauthorised read with 404, which reads as a permissions problem rather
# than an auth one. Enforced by scripts/lint-jira-preflight.sh after it cost two sessions.
s, r = api("GET", "/rest/api/3/myself")
if s != 200:
    print(f"!! cannot authenticate to {BASE} as {EMAIL} (HTTP {s})")
    sys.exit(1)
print(f"authenticated as {r.get('displayName')}\n")

s, cur = api("GET", f"/rest/api/3/issue/{KEY}?fields=summary,status")
if s != 200:
    sys.exit(f"cannot read {KEY} ({s})")
print(f"{KEY}  [{cur['fields']['status']['name']}]  {cur['fields']['summary'][:60]}")

if not GO:
    print(f"\n[DRY RUN] would post a comment of {len(BODY)} chars, and NOT transition:\n")
    print(BODY)
    print("\nRe-run with --go to post.")
    sys.exit(0)

adf = {"type": "doc", "version": 1, "content":
       [{"type": "paragraph", "content": [{"type": "text", "text": p}]}
        for p in BODY.split("\n\n") if p.strip()]}
s, r = api("POST", f"/rest/api/3/issue/{KEY}/comment", {"body": adf})
print(f"  comment: {'OK' if s in (200, 201) else f'FAIL {s} {r}'}")
print("  status deliberately unchanged — the revocation half of the AC is still open.")
