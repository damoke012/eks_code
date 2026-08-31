#!/usr/bin/env python3
"""
Close the ACTIVE sprint on INFRA board 322 and carry every NOT-DONE issue into the
next sprint.

Order matters and is not negotiable: issues are moved FIRST, the sprint is closed
LAST. Closing a sprint with incomplete issues still in it makes Jira decide where
they go, and what it decides depends on board config you cannot see from here.

"Done" is judged by statusCategory == done, not by status NAME. Boards rename
statuses; the category is stable.

DRY-RUN BY DEFAULT. It prints the exact plan and changes nothing. Pass --go.

    read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
    python3 scripts/roll-sprint.py                    # show the plan
    python3 scripts/roll-sprint.py --go               # do it
    python3 scripts/roll-sprint.py --to "UI Sprint 4" # name the target explicitly
    python3 scripts/roll-sprint.py --no-close         # move only, leave sprint open
"""
import base64, json, os, re, sys, urllib.error, urllib.parse, urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GO = "--go" in sys.argv
NO_CLOSE = "--no-close" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
BOARD = 322

TO_NAME = None
if "--to" in sys.argv:
    i = sys.argv.index("--to")
    if i + 1 >= len(sys.argv):
        sys.exit("--to needs a sprint name")
    TO_NAME = sys.argv[i + 1]


def get_token():
    t = os.environ.get("ATLASSIAN_TOKEN") or os.environ.get("CONFLUENCE_TOKEN")
    if t:
        return t.strip()
    f = REPO / "scripts" / "push-to-confluence.sh"
    if f.exists():
        for ln in f.read_text().splitlines():
            if ln.strip().startswith("CONFLUENCE_TOKEN="):
                return ln.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("No token: set ATLASSIAN_TOKEN (or CONFLUENCE_TOKEN in push-to-confluence.sh)")


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


def die(msg, payload=None):
    print(f"\nABORT: {msg}")
    if payload:
        print(f"       {json.dumps(payload)[:400]}")
    sys.exit(1)


# ---- 1. the active sprint ----------------------------------------------------
st, r = api("GET", f"/rest/agile/1.0/board/{BOARD}/sprint?state=active")
if st != 200:
    die(f"cannot read board {BOARD} sprints (HTTP {st})", r)
active = r.get("values", [])
if not active:
    die(f"board {BOARD} has no ACTIVE sprint — nothing to close")
if len(active) > 1:
    print("Board has more than one active sprint:")
    for s in active:
        print(f"  {s['id']}  {s['name']}")
    die("refusing to guess which one to close")
cur = active[0]
print(f"active sprint : {cur['id']}  {cur['name']}")
print(f"                {cur.get('startDate','?')[:10]} -> {cur.get('endDate','?')[:10]}")

# ---- 2. its issues, split by status CATEGORY ---------------------------------
done, carry = [], []
start_at = 0
while True:
    st, r = api("GET", f"/rest/agile/1.0/sprint/{cur['id']}/issue"
                       f"?startAt={start_at}&maxResults=100"
                       f"&fields=summary,status,assignee")
    if st != 200:
        die(f"cannot read issues of sprint {cur['id']} (HTTP {st})", r)
    for it in r.get("issues", []):
        f = it["fields"]
        cat = (f["status"].get("statusCategory") or {}).get("key", "")
        who = (f.get("assignee") or {}).get("displayName", "unassigned")
        row = (it["key"], f["status"]["name"], who, f["summary"][:62])
        (done if cat == "done" else carry).append(row)
    start_at += r.get("maxResults", 0)
    if start_at >= r.get("total", 0):
        break

print(f"\nDONE, stays in {cur['name']}  ({len(done)})")
for k, s, w, t in sorted(done):
    print(f"  {k:<12} {s:<14} {w:<22} {t}")
print(f"\nNOT DONE, carries forward  ({len(carry)})")
for k, s, w, t in sorted(carry):
    print(f"  {k:<12} {s:<14} {w:<22} {t}")

if not carry:
    print("\nNothing to carry. Close the sprint in the Jira UI if that is all you wanted.")

# ---- 3. find or create the target sprint -------------------------------------
if TO_NAME:
    target_name = TO_NAME
else:
    m = re.search(r"(\d+)\s*$", cur["name"])
    if not m:
        die(f"cannot derive the next name from {cur['name']!r} — pass --to \"UI Sprint 4\"")
    target_name = cur["name"][:m.start(1)] + str(int(m.group(1)) + 1)

target = None
for state in ("future", "active"):
    st, r = api("GET", f"/rest/agile/1.0/board/{BOARD}/sprint?state={state}")
    if st != 200:
        continue
    for s in r.get("values", []):
        if s["name"].strip().lower() == target_name.strip().lower():
            target = s
            break
    if target:
        break

print()
if target:
    print(f"target sprint : {target['id']}  {target['name']}  (exists, state={target['state']})")
else:
    print(f"target sprint : {target_name!r}  (does NOT exist — will be created)")

print(f"\nplan          : move {len(carry)} issue(s) -> {target_name}")
print(f"                {'close' if not NO_CLOSE else 'LEAVE OPEN'} {cur['name']} (id {cur['id']})")

if not GO:
    print("\nDRY RUN — nothing changed. Re-run with --go to execute.")
    sys.exit(0)

# ---- 4. execute: create, move, THEN close ------------------------------------
if not target:
    st, r = api("POST", "/rest/agile/1.0/sprint",
                {"name": target_name, "originBoardId": BOARD})
    if st not in (200, 201):
        die(f"could not create sprint {target_name!r} (HTTP {st})", r)
    target = r
    print(f"  created sprint {target['id']}  {target['name']}")

if carry:
    keys = [k for k, _, _, _ in carry]
    for i in range(0, len(keys), 50):          # API caps the batch
        batch = keys[i:i + 50]
        st, r = api("POST", f"/rest/agile/1.0/sprint/{target['id']}/issue",
                    {"issues": batch})
        if st not in (200, 204):
            die(f"move failed for {batch} (HTTP {st}) — sprint NOT closed", r)
        print(f"  moved {len(batch)}: {', '.join(batch)}")

    # verify before closing: re-read the old sprint and confirm nothing incomplete
    st, r = api("GET", f"/rest/agile/1.0/sprint/{cur['id']}/issue"
                       f"?maxResults=100&fields=status")
    if st != 200:
        die("cannot verify the move — sprint NOT closed", r)
    left = [it["key"] for it in r.get("issues", [])
            if (it["fields"]["status"].get("statusCategory") or {}).get("key") != "done"]
    if left:
        die(f"{len(left)} issue(s) still not done in {cur['name']}: {', '.join(left)} "
            f"— sprint NOT closed")
    print("  verified: no incomplete issues remain in the old sprint")

if NO_CLOSE:
    print(f"\n--no-close given: {cur['name']} left open.")
    sys.exit(0)

st, r = api("POST", f"/rest/agile/1.0/sprint/{cur['id']}", {"state": "closed"})
if st not in (200, 204):
    die(f"could not close {cur['name']} (HTTP {st}) — issues WERE moved", r)
print(f"  closed {cur['name']} (id {cur['id']})")
print(f"\nDone. {len(carry)} issue(s) now in {target['name']}.")
