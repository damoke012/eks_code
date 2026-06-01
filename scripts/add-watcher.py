#!/usr/bin/env python3
"""
Add a Jira user as watcher to one or more issues.

Reuses the auth pattern from file-jira-slate.py (token from push-to-confluence.sh).

Usage:
    python3 scripts/add-watcher.py <user-query> <issue-key> [<issue-key> ...]
    python3 scripts/add-watcher.py --account-id <id> <issue-key> [...]

Examples:
    python3 scripts/add-watcher.py "Steve Duck" INFRA-472 INFRA-1492 INFRA-1494
    python3 scripts/add-watcher.py --account-id 613970717eb35f00693f47e9 INFRA-1492

In non-interactive contexts (codespace/CI), use --account-id to skip the
disambiguation prompt that fires when multiple users match the query.
"""

import base64
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"

EMAIL = "doke@usxpress.com"
TOKEN = ""
for ln in (SCRIPTS_DIR / "push-to-confluence.sh").read_text().splitlines():
    if ln.startswith("CONFLUENCE_TOKEN="):
        TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
        break
assert TOKEN, "token not found in scripts/push-to-confluence.sh"
AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()


def api(method, path, body=None, raw_body=None):
    url = f"https://usxpress.atlassian.net{path}"
    headers = {
        "Authorization": AUTH,
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    if raw_body is not None:
        data = raw_body.encode()
    elif body is not None:
        data = json.dumps(body).encode()
    else:
        data = None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as r:
            txt = r.read().decode()
            return r.status, (json.loads(txt) if txt else {})
    except urllib.error.HTTPError as e:
        body_txt = e.read().decode()
        try:
            return e.code, json.loads(body_txt)
        except Exception:
            return e.code, {"raw": body_txt[:600]}


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)

    # Non-interactive path: --account-id <id> <issue> [issue...]
    if sys.argv[1] == "--account-id":
        if len(sys.argv) < 4:
            print(__doc__)
            sys.exit(2)
        account_id = sys.argv[2]
        issues = sys.argv[3:]
        print(f"Using accountId: {account_id}\n")
    else:
        query = sys.argv[1]
        issues = sys.argv[2:]

        print(f"Looking up user: {query}")
        s, users = api("GET", f"/rest/api/3/user/search?query={urllib.parse.quote(query)}&maxResults=20")
        if not isinstance(users, list) or not users:
            print(f"!! no users matched: {query}")
            print(json.dumps(users, indent=2)[:500])
            sys.exit(1)

        if len(users) == 1:
            u = users[0]
        else:
            print(f"\n{len(users)} matches — pick one:")
            for i, u in enumerate(users):
                print(f"  [{i}] {u.get('displayName')} <{u.get('emailAddress')}>  id={u.get('accountId')}")
            if not sys.stdin.isatty():
                print("\n!! multiple matches in non-interactive mode; re-run with --account-id <id>")
                sys.exit(2)
            idx = int(input("index: ").strip())
            u = users[idx]

        account_id = u.get("accountId")
        print(f"\nUsing: {u.get('displayName')} <{u.get('emailAddress')}>  id={account_id}\n")

    results = {}
    for key in issues:
        # Watchers POST takes the accountId as a JSON-encoded STRING (not an object).
        # E.g.: -d '"712020:..."'
        s, resp = api("POST", f"/rest/api/3/issue/{key}/watchers",
                      raw_body=json.dumps(account_id))
        if s in (200, 204):
            print(f"  OK  {key}  +watcher")
            results[key] = "OK"
        else:
            print(f"  FAIL {key}  HTTP {s}  {json.dumps(resp)[:200]}")
            results[key] = f"FAIL {s}"

    print(f"\nSummary: {sum(1 for v in results.values() if v == 'OK')}/{len(results)} succeeded")
    return 0 if all(v == "OK" for v in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
