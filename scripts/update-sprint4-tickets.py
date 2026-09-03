#!/usr/bin/env python3
"""
Sprint 4 board update after the 2026-09-01 INFRA-1674 prod RisingWave session.

Three kinds of change, deliberately separated by how much evidence backs them:

  A. ASSIGN   — Unassigned on-prem platform items that are Doke's by ownership.
  B. COMMENT  — INFRA-1674 gets today's completion evidence. It STAYS In Progress:
                the stack is deployed and running, the console is not, so closing it
                now would record a finish that a licence still gates.
  C. CREATE   — tickets for work that was done or found today and is not on the board.

Everything a human should decide is NOT done automatically. `--review` prints those
candidates (status moves, Idris's items, anything this session cannot prove) so they can
be actioned by hand rather than guessed at from a screenshot.

DRY-RUN BY DEFAULT. Pass --go to execute.

Auth (WSL): export ATLASSIAN_TOKEN=...
"""
import base64, json, os, sys, urllib.error, urllib.parse, urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GO = "--go" in sys.argv
REVIEW = "--review" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
PROJECT = "INFRA"

# ── A. assignee fixes ────────────────────────────────────────────────────────
# All on-prem platform risk/infra items sitting Unassigned. Doke owns on-prem.
ASSIGN_TO_DOKE = ["INFRA-1662", "INFRA-1661", "INFRA-1660", "INFRA-1655", "INFRA-1663"]

# ── B. evidence comment on the ticket this session actually moved ────────────
C1674 = """INFRA-1674 status 2026-09-01 — RisingWave is deployed and RUNNING on op-usxpress-prod.

Terraform (Octopus release 0.5.6 -> production, TfApply armed for one run then disarmed):
Apply complete, 20 added, 0 changed, 0 destroyed; terraform_outputs.yml artifact captured.
Created in 937464026810/us-east-2: IRSA role op-usxpress-prod-risingwave (+ inline policy
risingwave-s3-access), s3://risingwave-state-op-usxpress-prod (versioning, SSE,
public-access-block), and five Secrets Manager entries under op-usxpress-prod/risingwave/.

Flux: variant-inc/iaac-talos-flux-cluster#38 merged to master. risingwave-operator and
risingwave-routes Ready; RisingWave CR reports RUNNING=True on v2.8.2 with the PostgreSQL
metastore and S3 state store bound. meta/compute/frontend/compactor, both ghostunnels and
pg-postgresql all 1/1. ServiceAccount carries the prod IRSA role. VirtualServices for
risingwave-dashboard and risingwave-overview are live and DNS resolves for both.
Prod's Dex callback was added to Entra registration e112d6ce-cc60-4884-9898-8fcc5b78b0b1
(dev and QA URIs preserved).

NOT DONE, and why this stays In Progress:
- risingwave-console is in CrashLoopBackOff. console_license_key holds the Terraform
  placeholder PLACEHOLDER_INJECT_REAL_LICENSE, and the console rejects it with
  "license verification failed: license must be a compact JWT". QA holds the same
  placeholder, so there is nothing to copy. Tracked separately (see linked licence tickets).
- rw-bootstrap-service-accounts is a downstream victim: it completes every group, user and
  grant, then crashloops on "relation \\"anclax.users\\" does not exist" — the console's own
  schema. The users and grants ARE applied.
- Velero Schedule risingwave-metastore exists; no COMPLETED backup yet.

Two failed prod deploys preceded the successful one, both 403 on the Terraform state
backend: S3_BUCKET in production scope held QA's bucket, and after correcting it the
release still deployed its frozen variable snapshot. Both are written up in the repo."""

# jira-update-2026-09-02.py carries the same INFRA-1674 evidence in a later, fuller form.
# Running both posts it twice, so pass --no-comment here when that script is also being run.
COMMENTS = {} if "--no-comment" in sys.argv else {"INFRA-1674": C1674}

# ── C. tickets that do not exist yet ─────────────────────────────────────────
NEW = [
  {"summary": "Obtain a valid RisingWave Console licence key",
   "assignee": None,          # vendor dependency — set an owner by hand
   "relates": ["INFRA-1674"],
   "body": """The RisingWave Console licence has lapsed. console_license_key holds the literal
placeholder PLACEHOLDER_INJECT_REAL_LICENSE in BOTH op-usxpress-qa (527101283767) and
op-usxpress-prod (937464026810), so there is nothing to copy between environments.

The prod console refuses to start: "license verification failed: license must be a compact JWT".

Commercial/vendor dependency with no engineering work in it — tracked here so it is visible
rather than living in a chat thread. Owner: Steve -> Zach.

Acceptance criteria:
- A compact JWT licence key is available (three dot-separated parts, eyJ prefix)
- Its tier and expiry are recorded on this ticket
- Confirmed whether ONE key covers dev, QA and prod, or each cluster needs its own
- RisingWave's FREE-TIER licence has been asked about as a fast path: the console appears
  to require a well-formed licence, not necessarily a paid one
- Decision point: if this runs past two weeks, raise a follow-up to scale the prod console
  to zero so prod does not carry two permanently red workloads"""},

  {"summary": "Inject the RisingWave Console licence into QA and prod, and verify the console runs",
   "assignee": "doke",
   "relates": ["INFRA-1674"],
   "body": """Blocked by the licence ticket. Injecting the key is three steps and the middle one is
the one that gets missed.

Terraform creates console_license_key with ignore_changes, so the real value is written BY
HAND into Secrets Manager and will not be reverted by a later apply.

The console pod must then be RECREATED, not restarted in place: the value reaches the
container as an environment variable resolved at pod creation, so a crashlooping container
replays the old value indefinitely however green the Secret and ExternalSecret look.

Finally rw-bootstrap-service-accounts needs recreating. It currently completes every group,
user and grant and then crashloops on its last step against anclax.users, the console's own
schema. It is a downstream victim of the licence, not a separate fault.

Acceptance criteria:
- Real licence written to op-usxpress-prod/risingwave/console_license_key and
  op-usxpress-qa/risingwave/console_license_key, both as {"RW_LICENSE_KEY": "<jwt>"}, us-east-2
- Value read back and confirmed to be a compact JWT — a SecretSynced ExternalSecret is NOT
  evidence the content is valid
- risingwave-console is 2/2 Running on op-usxpress-prod
- rw-bootstrap-service-accounts reaches Completed
- QA's console state confirmed (unverified on 2026-09-01, op-qa was unreachable) and fixed
  if it is failing the same way
- scripts/rw-prod-status.sh gate 5 passes against a real licence
- An operator can log in to risingwave-dashboard.op-prod.usxpress.io through Entra"""},

  {"summary": "op-usxpress-prod Grafana VirtualService publishes a dev hostname",
   "assignee": "doke",
   "relates": [],
   "body": """Prod's Grafana VirtualService publishes grafana.op-dev.usxpress.io. A copied
VirtualService fails silently: external-dns creates the record from the annotation, so prod
either publishes a dev hostname or collides with dev's record.

Same class as the RisingWave route copies corrected under INFRA-1674 on 2026-08-31.

Acceptance criteria:
- Prod's Grafana VirtualService publishes a prod hostname
- Its external-dns target annotation points at the three prod platform node IPs
- scripts/onprem-dns-claims.sh dev qa prod reports no cross-environment hostname or target"""},
]

# Candidates this script deliberately will NOT touch.
REVIEW_ITEMS = [
  ("INFRA-1675", "Idris's RisingWave work — PR reviewed and approved 2026-08-31, he merged it. "
                 "Confirm it merged, then close. Not on the Sprint 4 board in the screenshot: "
                 "check whether it needs adding to the sprint."),
  ("INFRA-1639", "Argo CD SSO for application teams — sits TO DO, but SSO is live on all three "
                 "clusters (2026-08-25) and scripts/entra-argocd-cli-redirect.sh was written for "
                 "this ticket. Almost certainly In Progress or Done; needs your call on scope."),
  ("INFRA-1650", "Argo CD Git credential on op-usxpress-prod — sits TO DO, but branch "
                 "feat/argocd-repo-ssh-externalsecret has both files staged. Likely In Progress."),
  ("INFRA-1637", "Confluent credential rotation (Idris, In Progress) — the credentials were "
                 "still live as of this session. Confirm with Idris before it moves."),
  ("INFRA-1674", "Can close once the console licence lands. Left In Progress on purpose."),
]


def get_token():
    t = os.environ.get("ATLASSIAN_TOKEN") or os.environ.get("CONFLUENCE_TOKEN")
    if t:
        return t.strip()
    sys.exit("No token: export ATLASSIAN_TOKEN=... (run this on WSL)")


if REVIEW and not GO:
    print("Needs your decision — NOT changed by this script:\n")
    for k, why in REVIEW_ITEMS:
        print(f"  {k}: {why}\n")
    sys.exit(0)

AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{get_token()}".encode()).decode()


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


def adf(text):
    return {"type": "doc", "version": 1, "content":
            [{"type": "paragraph", "content": [{"type": "text", "text": p}]}
             for p in text.split("\n\n") if p.strip()]}


def find_account(query):
    s, r = api("GET", f"/rest/api/3/user/search?query={urllib.parse.quote(query)}")
    if s != 200 or not r:
        return None
    return r[0].get("accountId")


def preflight():
    """Prove the token works before any call that matters.

    Jira answers an unauthorised issue read with 404 "does not exist" and an
    unauthorised create with 400 "target project doesn't exist". Both read as
    permission problems rather than auth ones, so a bad token looks exactly like
    a missing ticket. Second occurrence: 2026-08-20 (eleven failed calls) and
    2026-09-03 (nine), both from a placeholder token pasted out of an instruction.
    close-sprint3-tickets.py has carried this check since the first one."""
    s, r = api("GET", "/rest/api/3/myself")
    if s != 200:
        tok = os.environ.get("ATLASSIAN_TOKEN", "")
        print(f"!! cannot authenticate to {BASE} as {EMAIL}  (HTTP {s})")
        if len(tok) < 20 or tok.startswith("<"):
            print(f"   ATLASSIAN_TOKEN looks wrong: {len(tok)} characters.")
            print("   Set it without putting it in shell history:")
            print("     read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo")
        else:
            print("   Plausible length, so it may be expired or revoked.")
            print("   Mint a new one: https://id.atlassian.com/manage-profile/security/api-tokens")
        sys.exit(1)
    print(f"authenticated as {r.get('displayName')} <{r.get('emailAddress', EMAIL)}>")

print(f"{'EXECUTING' if GO else 'DRY RUN'} — {EMAIL} @ {BASE}\n")
preflight()

# Resolve the one assignee we set automatically, and fail loudly if ambiguous.
doke_id = find_account(EMAIL) or find_account("Dare Oke")
print(f"assignee 'doke' -> accountId {doke_id}\n" if doke_id else
      "!! could not resolve Doke's accountId — assignments will be skipped\n")

print("== A. assign unassigned on-prem items")
for key in ASSIGN_TO_DOKE:
    s, cur = api("GET", f"/rest/api/3/issue/{key}?fields=assignee,summary")
    if s != 200:
        print(f"  {key}: cannot read ({s}) — skipped"); continue
    who = (cur["fields"].get("assignee") or {}).get("displayName")
    if who:
        print(f"  {key}: already assigned to {who} — left alone"); continue
    if not GO:
        print(f"  [plan] {key} -> Doke   ({cur['fields']['summary'][:60]})"); continue
    s, r = api("PUT", f"/rest/api/3/issue/{key}", {"fields": {"assignee": {"accountId": doke_id}}})
    print(f"  {key}: {'OK' if s in (200, 204) else f'FAIL {s} {r}'}")

print("\n== B. status comment")
for key, body in COMMENTS.items():
    if not GO:
        print(f"  [plan] comment on {key} ({len(body)} chars)"); continue
    s, r = api("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf(body)})
    print(f"  {key}: {'OK' if s in (200, 201) else f'FAIL {s} {r}'}")

print("\n== C. create missing tickets")
created = {}
for spec in NEW:
    if not GO:
        print(f"  [plan] create: {spec['summary']}"); continue
    fields = {"project": {"key": PROJECT}, "summary": spec["summary"],
              "description": adf(spec["body"]), "issuetype": {"name": "Task"}}
    if spec["assignee"] == "doke" and doke_id:
        fields["assignee"] = {"accountId": doke_id}
    s, r = api("POST", "/rest/api/3/issue", {"fields": fields})
    if s in (200, 201):
        created[spec["summary"]] = r["key"]
        print(f"  created {r['key']}: {spec['summary']}")
        for other in spec["relates"]:
            api("POST", "/rest/api/3/issueLink", {"type": {"name": "Relates"},
                "outwardIssue": {"key": r["key"]}, "inwardIssue": {"key": other}})
            print(f"    linked {r['key']} relates {other}")
    else:
        print(f"  FAIL {s} {r}")

# The licence injection ticket is blocked by the licence ticket. Link them once both exist.
if GO and len(created) >= 2:
    keys = list(created.values())
    api("POST", "/rest/api/3/issueLink", {"type": {"name": "Blocks"},
        "outwardIssue": {"key": keys[0]}, "inwardIssue": {"key": keys[1]}})
    print(f"\n  linked {keys[0]} blocks {keys[1]}")

print("\nRun with --review to see what needs your decision and was left untouched.")
