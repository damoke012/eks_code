#!/usr/bin/env python3
"""Full scope of the UI Sprint 6 tickets assigned to you, so closeability can be judged.

READ ONLY. Makes no change of any kind — there is no --go.

Enumerates the sprint from /rest/agile/1.0/sprint/<id>/issue, NOT from a JQL on
customfield_10010. A wrong custom-field name returns 200 with the field absent, which
is indistinguishable from "no sprint" — so sprint membership is verified at the
destination. The JQL path is kept only as a fallback and says when it was used.

    read -rsp 'Atlassian API token: ' T; export ATLASSIAN_TOKEN="$T"; echo
    python3 scripts/sprint6-detail.py
    python3 scripts/sprint6-detail.py --sprint 6290 --chars 1600
"""
import importlib.util, os, sys, urllib.parse

spec = importlib.util.spec_from_file_location(
    "closer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv


def arg(flag, default):
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


SPRINT = arg("--sprint", "6290")          # UI Sprint 6
CHARS = int(arg("--chars", "1100"))


def flatten(node, out):
    """ADF -> plain text. Descriptions are ADF documents, not strings."""
    if isinstance(node, dict):
        t = node.get("type")
        if t == "text":
            out.append(node.get("text", ""))
        elif t in ("hardBreak", "paragraph", "heading", "listItem", "codeBlock"):
            out.append("\n")
        for k in ("content",):
            for c in node.get(k, []) or []:
                flatten(c, out)
    elif isinstance(node, list):
        for c in node:
            flatten(c, out)
    return out


def text_of(field):
    if not field:
        return ""
    if isinstance(field, str):
        return field
    s = "".join(flatten(field, []))
    return " ".join(s.split("\n\n")).strip()


def main():
    print("== sprint6-detail  [READ ONLY]\n")

    status, me = m.api("GET", "/rest/api/3/myself")
    if status != 200 or not isinstance(me, dict) or not me.get("accountId"):
        print(f"!! token NOT PROVEN: /myself returned {status} {str(me)[:200]}", file=sys.stderr)
        print("   Nothing was read; an unproven token reads as an empty sprint.", file=sys.stderr)
        sys.exit(2)
    mine = me["accountId"]
    print(f"authenticated as: {me.get('displayName')} <{me.get('emailAddress')}>\n")

    fields = "summary,status,assignee,updated,description,labels,issuetype,parent"
    issues, source = None, ""
    q = urllib.parse.urlencode({"fields": fields, "maxResults": 100})
    s, body = m.api("GET", f"/rest/agile/1.0/sprint/{SPRINT}/issue?{q}")
    if s == 200 and isinstance(body, dict) and "issues" in body:
        issues, source = body["issues"], f"/rest/agile/1.0/sprint/{SPRINT}/issue"
    else:
        detail = (body.get("errorMessages") or body.get("raw") or body) if isinstance(body, dict) else body
        print(f"!! agile endpoint {s}: {str(detail)[:160]}", file=sys.stderr)
        jql = f"sprint = {SPRINT} ORDER BY key ASC"
        q2 = urllib.parse.urlencode({"jql": jql, "fields": fields, "maxResults": 100})
        for path in (f"/rest/api/3/search/jql?{q2}", f"/rest/api/3/search?{q2}"):
            s2, b2 = m.api("GET", path)
            if s2 == 200 and isinstance(b2, dict) and "issues" in b2:
                issues, source = b2["issues"], f"FALLBACK JQL ({path.split('?')[0]})"
                break
    if issues is None:
        print("!! could not enumerate the sprint by either route.", file=sys.stderr)
        sys.exit(2)

    print(f"sprint {SPRINT} enumerated via: {source}")
    print(f"issues in sprint: {len(issues)}")

    ours = [i for i in issues
            if ((i["fields"].get("assignee") or {}) or {}).get("accountId") == mine]
    print(f"assigned to you : {len(ours)}\n")

    for i in sorted(ours, key=lambda x: x["key"]):
        f = i["fields"]
        st = (f.get("status") or {}).get("name", "?")
        print("=" * 78)
        print(f"{i['key']}  [{st}]  updated {f.get('updated','')[:10]}")
        print(f"  {f.get('summary','')}")
        labels = f.get("labels") or []
        if labels:
            print(f"  labels: {', '.join(labels)}")
        d = text_of(f.get("description"))
        if d:
            print(f"\n  {d[:CHARS]}{' ...[truncated]' if len(d) > CHARS else ''}")
        sc, cb = m.api("GET", f"/rest/api/3/issue/{i['key']}/comment?maxResults=2&orderBy=-created")
        if sc == 200 and isinstance(cb, dict):
            for c in (cb.get("comments") or [])[-2:]:
                who = (c.get("author") or {}).get("displayName", "?")
                when = (c.get("created") or "")[:10]
                body_t = text_of(c.get("body"))[:400]
                print(f"\n  -- comment {when} {who}: {body_t}")
        print()

    print("=" * 78)
    print(f"{len(ours)} ticket(s) assigned to you in sprint {SPRINT}")


if __name__ == "__main__":
    main()
