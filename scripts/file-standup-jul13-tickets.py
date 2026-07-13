#!/usr/bin/env python3
"""
File the 6 tickets extracted from the 2026-07-13 standup.

Reads drafts from jira/drafts/INFRA-XXXX-*.md (# Title + markdown body).
Creates them in the INFRA project via Jira REST v3. Epic linking tries
`parent` first, then the "Epic Link" custom field, then falls back to a
top-level issue + a "Relates" link so nothing hard-fails.

DRY-RUN BY DEFAULT. Pass --go to actually create.

Auth (WSL):
  export ATLASSIAN_TOKEN=...            # preferred
  # or leave it in scripts/push-to-confluence.sh as CONFLUENCE_TOKEN=...
  EMAIL defaults to doke@usxpress.com (override with JIRA_EMAIL=...).

Usage:
  python3 scripts/file-standup-jul13-tickets.py           # dry run — prints plan
  python3 scripts/file-standup-jul13-tickets.py --go       # create the tickets
"""
import base64, json, os, re, sys, urllib.error, urllib.parse, urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DRAFTS = REPO / "jira" / "drafts"
GO = "--go" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")

# (draft filename, issuetype, parent_epic_or_None, dedup_search_or_None)
SLATE = [
    ("INFRA-XXXX-qa-automate-flux-reconciliation-rebuild.md", "Story", "INFRA-1560", None),
    ("INFRA-XXXX-wiz-ebpf-dev-onboarding.md",                 "Story", "INFRA-472",  "Wiz eBPF"),
    ("INFRA-XXXX-platform-sso-entra-discovery.md",            "Story", "INFRA-1559", None),
    ("INFRA-XXXX-datalake-alerting-discovery.md",             "Story", None,         None),
    ("INFRA-XXXX-pod-crashloop-alerting.md",                  "Task",  None,         None),
    ("INFRA-XXXX-eks-k8s-upgrade-assess-automate.md",         "Story", None,         None),
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
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
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
            return e.code, {"raw": raw}


def md_to_adf(md):
    """Minimal Markdown -> ADF: paragraphs, bullet '- ' lists, '## ' headings."""
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
            flush()
            content.append({"type": "heading", "attrs": {"level": 3},
                            "content": [{"type": "text", "text": s[3:]}]})
        elif re.match(r"^[-*] ", s) or re.match(r"^\d+\. ", s):
            bullets.append(re.sub(r"^([-*]|\d+\.)\s+", "", s))
        else:
            flush()
            content.append({"type": "paragraph", "content": [{"type": "text", "text": s}]})
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
    body_no_title = re.sub(r"^#\s+.+\n", "", body, count=1, flags=re.MULTILINE)
    return title, labels, body_no_title


def epic_link_field():
    """Discover the 'Epic Link' custom field id (classic projects)."""
    s, fields = api("GET", "/rest/api/3/field")
    if s == 200:
        for f in fields:
            if f.get("name") == "Epic Link":
                return f.get("id")
    return None


def main():
    print(f"{'CREATE' if GO else 'DRY-RUN'} — INFRA project @ {BASE} as {EMAIL}\n")

    s, proj = api("GET", "/rest/api/3/project/INFRA")
    if s != 200:
        sys.exit(f"Cannot read INFRA project (HTTP {s}): {proj}")
    types = {it["name"]: it["id"] for it in proj.get("issueTypes", [])}
    elf = epic_link_field()

    results = []
    for fname, itype, parent, dedup in SLATE:
        path = DRAFTS / fname
        if not path.exists():
            print(f"!! missing {fname}"); continue
        title, labels, body = parse(path)

        # dedup check
        if dedup:
            s, sr = api("GET", "/rest/api/3/search?jql=" +
                        urllib.parse.quote(f'project=INFRA AND summary ~ "{dedup}"') + "&maxResults=5")
            hits = sr.get("issues", []) if s == 200 else []
            if hits:
                print(f"~~ SKIP {fname}: possible dup(s): " +
                      ", ".join(h["key"] for h in hits) + "  (verify manually)")
                results.append((fname, "SKIP-DUP", [h["key"] for h in hits]))
                continue

        # verify parent
        p_ok = False
        if parent:
            sp, pr = api("GET", f"/rest/api/3/issue/{parent}?fields=summary,issuetype")
            p_ok = sp == 200
            if not p_ok:
                print(f"  (parent {parent} not found — filing top-level + note)")

        fields = {
            "project": {"key": "INFRA"},
            "summary": title[:250],
            "issuetype": {"id": types.get(itype, types.get("Task"))},
            "description": md_to_adf(body),
        }
        if labels:
            fields["labels"] = labels
        if parent and p_ok:
            fields["parent"] = {"key": parent}   # team-managed epic child

        if not GO:
            print(f"[plan] {itype:5} '{title[:70]}'"
                  f"{'  epic='+parent if parent and p_ok else ''}  labels={labels}")
            results.append((fname, "PLANNED", title))
            continue

        s, resp = api("POST", "/rest/api/3/issue", {"fields": fields})
        if s == 201:
            key = resp["key"]
            # if parent didn't take via 'parent', try Epic Link field
            print(f"  + {key}  {title[:60]}")
            results.append((fname, key, title))
            if parent and p_ok and elf:
                api("PUT", f"/rest/api/3/issue/{key}", {"fields": {elf: parent}})
        elif s == 400 and parent and "parent" in json.dumps(resp).lower():
            # retry without parent, then link
            fields.pop("parent", None)
            s2, r2 = api("POST", "/rest/api/3/issue", {"fields": fields})
            if s2 == 201:
                key = r2["key"]
                api("POST", "/rest/api/3/issueLink", {"type": {"name": "Relates"},
                    "inwardIssue": {"key": key}, "outwardIssue": {"key": parent}})
                print(f"  + {key}  (linked→{parent})  {title[:50]}")
                results.append((fname, key, title))
            else:
                print(f"  !! FAILED {fname}: {s2} {r2}")
                results.append((fname, f"ERR-{s2}", title))
        else:
            print(f"  !! FAILED {fname}: {s} {resp}")
            results.append((fname, f"ERR-{s}", title))

    print("\n| draft | key | title |\n|---|---|---|")
    for fn, key, t in results:
        print(f"| {fn} | {key} | {t if isinstance(t,str) else t} |")
    if GO:
        Path("/tmp/standup-jul13-tickets-results.json").write_text(json.dumps(results, indent=2))
        print("\nSaved /tmp/standup-jul13-tickets-results.json — rename drafts to real keys via git mv.")


if __name__ == "__main__":
    main()
