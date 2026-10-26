#!/usr/bin/env python3
"""Show the current sprint on board 322, straight from Jira. READ ONLY.

    python3 scripts/board-now.py            # the sprint that is running now
    python3 scripts/board-now.py --sprint N # a specific sprint id
    python3 scripts/board-now.py --backlog  # sprintless INFRA issues too

There is no --go. This script makes no write of any kind.

Token: ATLASSIAN_TOKEN or CONFLUENCE_TOKEN from the environment, else the
untracked scripts/push-to-confluence.sh. It PRINTS which source it used --
a silent fallback is how a run authenticates with nothing in the environment
and nobody notices which identity wrote.
"""
import base64, json, os, sys, urllib.request, urllib.error, datetime

SITE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
BOARD = int(os.environ.get("JIRA_BOARD", "322"))
CREDS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "push-to-confluence.sh")


def die(msg):
    print(f"NOT MEASURED - {msg}")
    sys.exit(1)


def token():
    for var in ("ATLASSIAN_TOKEN", "CONFLUENCE_TOKEN"):
        t = os.environ.get(var)
        if t:
            print(f"   token source: ${var}")
            return t
    if os.path.exists(CREDS):
        for line in open(CREDS):
            if line.startswith("CONFLUENCE_TOKEN="):
                print(f"   token source: {os.path.basename(CREDS)}")
                return line.split("=", 1)[1].strip().strip("\"'")
    die("no Atlassian token in the environment or in push-to-confluence.sh")


AUTH = None


def api(path):
    r = urllib.request.Request(SITE + path, headers={
        "Authorization": "Basic " + AUTH, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(r) as x:
            return json.loads(x.read())
    except urllib.error.HTTPError as e:
        die(f"HTTP {e.code} on {path}: {e.read().decode()[:200]}")



def jql_search(q):
    import urllib.parse
    d = api("/rest/api/3/search/jql?maxResults=30"
            "&fields=summary,status,assignee,updated"
            "&jql=" + urllib.parse.quote(q))
    print(f"\n=== {len(d.get('issues', []))} match: {q}")
    for i in d.get("issues", []):
        f = i["fields"]
        who = (f.get("assignee") or {}).get("displayName") or "UNASSIGNED"
        print(f"   {i['key']:<12} {f['status']['name']:<13} {who:<18} {f['summary'][:58]}")

def main():
    global AUTH
    AUTH = base64.b64encode(f"{EMAIL}:{token()}".encode()).decode()
    me = api("/rest/api/3/myself")
    print(f"   authenticated as {me.get('displayName')} <{me.get('emailAddress')}>")
    if "--jql" in sys.argv:
        jql_search(sys.argv[sys.argv.index("--jql") + 1]); return

    sprints, start = [], 0
    while True:
        d = api(f"/rest/agile/1.0/board/{BOARD}/sprint?startAt={start}&maxResults=50")
        sprints += d.get("values", [])
        if d.get("isLast", True):
            break
        start += 50

    want = None
    if "--sprint" in sys.argv:
        sid = int(sys.argv[sys.argv.index("--sprint") + 1])
        want = next((s for s in sprints if s["id"] == sid), None)
        if not want:
            die(f"sprint {sid} is not on board {BOARD}")
    else:
        today = datetime.datetime.now(datetime.timezone.utc)
        for s in sprints:
            sd, ed = s.get("startDate"), s.get("endDate")
            if not sd or not ed:
                continue
            a = datetime.datetime.fromisoformat(sd.replace("Z", "+00:00"))
            b = datetime.datetime.fromisoformat(ed.replace("Z", "+00:00"))
            if a <= today <= b and s.get("state") != "closed":
                want = s
                break
        if not want:
            open_s = [s for s in sprints if s.get("state") != "closed"]
            die(f"no sprint covers today; open sprints: "
                + ", ".join(f"{s['id']} {s['name']} ({s.get('state')})" for s in open_s))

    print(f"\n=== sprint {want['id']}  {want['name']}  state={want.get('state')}")
    print(f"    {want.get('startDate','?')[:10]} -> {want.get('endDate','?')[:10]}\n")

    issues, start = [], 0
    while True:
        d = api(f"/rest/agile/1.0/sprint/{want['id']}/issue?startAt={start}"
                "&maxResults=50&fields=summary,status,assignee,issuetype,updated")
        issues += d.get("issues", [])
        if start + 50 >= d.get("total", 0):
            break
        start += 50

    by_status = {}
    for i in issues:
        by_status.setdefault(i["fields"]["status"]["name"], []).append(i)
    for st in sorted(by_status):
        print(f"-- {st}  ({len(by_status[st])})")
        for i in sorted(by_status[st], key=lambda x: x["key"]):
            f = i["fields"]
            who = (f.get("assignee") or {}).get("displayName") or "UNASSIGNED"
            print(f"   {i['key']:<12} {who:<18} {f['updated'][:10]}  {f['summary'][:62]}")
        print()
    print(f"   {len(issues)} issues in sprint {want['id']}")


main()
