#!/usr/bin/env python3
"""
File the 2 secret-rotation tickets and pull the operational one into the sprint.

Creates in INFRA from jira/drafts/INFRA-XXXX-entra-secret-rotation.md and
INFRA-XXXX-secret-rotation-automation.md. On --go, adds the rotation ticket
(not the future automation one) to board 322's active sprint.

DRY-RUN BY DEFAULT. Pass --go to create + add-to-sprint.
Auth (WSL): export ATLASSIAN_TOKEN=...
"""
import base64, json, os, re, sys, urllib.error, urllib.parse, urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DRAFTS = REPO / "jira" / "drafts"
GO = "--go" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
BOARD = 322

# (draft, issuetype, add_to_sprint)
SLATE = [
    ("INFRA-XXXX-entra-secret-rotation.md",     "Story", True),
    ("INFRA-XXXX-secret-rotation-automation.md", "Story", False),
]


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
            return e.code, {"raw": raw[:300]}


def md_to_adf(md):
    content, bullets = [], []

    def flush():
        nonlocal bullets
        if bullets:
            content.append({"type": "bulletList", "content": [
                {"type": "listItem", "content": [
                    {"type": "paragraph", "content": [{"type": "text", "text": b}]}]} for b in bullets]})
            bullets = []
    for line in md.splitlines():
        s = line.strip()
        if not s:
            flush(); continue
        if s.startswith("## "):
            flush(); content.append({"type": "heading", "attrs": {"level": 3},
                                     "content": [{"type": "text", "text": s[3:]}]})
        elif re.match(r"^[-*] ", s) or re.match(r"^\d+\. ", s):
            bullets.append(re.sub(r"^([-*]|\d+\.)\s+", "", s))
        else:
            flush(); content.append({"type": "paragraph", "content": [{"type": "text", "text": s}]})
    flush()
    return {"type": "doc", "version": 1, "content": content or [
        {"type": "paragraph", "content": [{"type": "text", "text": " "}]}]}


def parse(path):
    body = path.read_text()
    m = re.search(r"^#\s+(.+)$", body, re.MULTILINE)
    title = re.sub(r"[*`]", "", m.group(1)).strip() if m else path.stem
    labels = []
    lm = re.search(r"^\*\*Labels\*\*:\s*(.+)$", body, re.MULTILINE)
    if lm:
        labels = [re.sub(r"[^A-Za-z0-9_.\-]", "-", x.strip()) for x in lm.group(1).split(",") if x.strip()]
    return title, labels, re.sub(r"^#\s+.+\n", "", body, count=1, flags=re.MULTILINE)


def active_sprint():
    s, r = api("GET", f"/rest/agile/1.0/board/{BOARD}/sprint?state=active")
    vs = r.get("values", []) if s == 200 else []
    return (vs[0]["id"], vs[0].get("name")) if vs else (None, None)


def main():
    print(f"{'CREATE' if GO else 'DRY-RUN'} — INFRA @ {BASE} as {EMAIL}\n")
    s, proj = api("GET", "/rest/api/3/project/INFRA")
    if s != 200:
        sys.exit(f"Cannot read INFRA (HTTP {s}): {proj}")
    types = {it["name"]: it["id"] for it in proj.get("issueTypes", [])}

    # dedup guard: skip if a very similar summary already exists
    created, sprint_targets = [], []
    for fname, itype, to_sprint in SLATE:
        path = DRAFTS / fname
        if not path.exists():
            print(f"!! missing {fname}"); continue
        title, labels, bodymd = parse(path)

        key_terms = "secret rotation" if "rotation" in fname else title[:20]
        s, sr = api("GET", "/rest/api/3/search?jql=" +
                    urllib.parse.quote(f'project=INFRA AND summary ~ "{key_terms}"') + "&maxResults=5")
        hits = [h["key"] for h in sr.get("issues", [])] if s == 200 else []
        if hits:
            print(f"~~ possible existing match for '{title[:40]}': {hits} (verify; not skipping create)")

        if not GO:
            print(f"[plan] {itype} '{title[:60]}'  sprint={to_sprint}  labels={labels}"
                  + (f"  (similar: {hits})" if hits else ""))
            continue

        fields = {"project": {"key": "INFRA"}, "summary": title[:250],
                  "issuetype": {"id": types.get(itype, types.get("Task"))},
                  "description": md_to_adf(bodymd)}
        if labels:
            fields["labels"] = labels
        s, resp = api("POST", "/rest/api/3/issue", {"fields": fields})
        if s == 201:
            key = resp["key"]
            print(f"  + {key}  {title[:55]}")
            created.append((fname, key))
            if to_sprint:
                sprint_targets.append(key)
        else:
            print(f"  !! FAILED {fname}: {s} {resp}")

    if GO and sprint_targets:
        sid, sname = active_sprint()
        if sid:
            s, r = api("POST", f"/rest/agile/1.0/sprint/{sid}/issue", {"issues": sprint_targets})
            print(f"\n  sprint {sid} '{sname}' += {sprint_targets}: "
                  f"{'OK' if s in (200,204) else f'FAIL {s} {r}'}")
        else:
            print(f"\n  !! no active sprint on board {BOARD} — add {sprint_targets} manually")

    if GO and created:
        print("\n| draft | key |\n|---|---|")
        for fn, k in created:
            print(f"| {fn} | {k} |")
        print("\nRename drafts to real keys (git mv to jira/sent/) and commit.")
    if not GO:
        print("\nDry-run only — re-run with --go to create + add to sprint.")


if __name__ == "__main__":
    main()
