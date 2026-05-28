#!/usr/bin/env python3
"""
File the TCP/SNI ingress slate to INFRA.

Order:
1. POST umbrella story (tcp-sni-ingress-umbrella.md)
2. POST 6 sub-tasks (phase0..phase5) with parent = umbrella key

Frontmatter drives:
  - assignee: "Doke" -> looked up by name; "Idris Fagbemi" -> looked up; else unassigned
  - issuetype: "Story" or "Sub-task"
  - parent: "TBD-UMBRELLA" -> rewritten to the freshly-filed umbrella key
  - labels: list

Token from scripts/push-to-confluence.sh. Writes /tmp/tcp-sni-slate-results.json.
"""

import base64
import json
import re
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
DRAFTS_DIR = REPO_ROOT / "jira/drafts"
SENT_DIR = REPO_ROOT / "jira/sent"
RESULTS = Path("/tmp/tcp-sni-slate-results.json")

EMAIL = "doke@usxpress.com"
TOKEN = ""
for ln in (SCRIPTS_DIR / "push-to-confluence.sh").read_text().splitlines():
    if ln.startswith("CONFLUENCE_TOKEN="):
        TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
        break
assert TOKEN, "token not found in scripts/push-to-confluence.sh"
AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()


def api(method, path, body=None):
    url = f"https://usxpress.atlassian.net{path}"
    headers = {"Authorization": AUTH, "Accept": "application/json", "Content-Type": "application/json"}
    data = json.dumps(body).encode() if body is not None else None
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


# ---------- ADF (same as file-jira-slate.py) ----------

def parse_inline(text):
    nodes, cur, i = [], "", 0
    while i < len(text):
        m = re.match(r"`([^`]+)`", text[i:])
        if m:
            if cur:
                nodes.append({"type": "text", "text": cur}); cur = ""
            nodes.append({"type": "text", "text": m.group(1), "marks": [{"type": "code"}]})
            i += m.end(); continue
        m = re.match(r"\*\*([^*]+)\*\*", text[i:])
        if m:
            if cur:
                nodes.append({"type": "text", "text": cur}); cur = ""
            nodes.append({"type": "text", "text": m.group(1), "marks": [{"type": "strong"}]})
            i += m.end(); continue
        m = re.match(r"\[([^\]]+)\]\(([^)]+)\)", text[i:])
        if m:
            if cur:
                nodes.append({"type": "text", "text": cur}); cur = ""
            nodes.append({"type": "text", "text": m.group(1),
                          "marks": [{"type": "link", "attrs": {"href": m.group(2)}}]})
            i += m.end(); continue
        cur += text[i]; i += 1
    if cur:
        nodes.append({"type": "text", "text": cur})
    return nodes or [{"type": "text", "text": " "}]


def md_to_adf(md):
    lines = md.split("\n")
    content = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("```"):
            lang = line[3:].strip() or "text"
            buf = []; i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                buf.append(lines[i]); i += 1
            i += 1
            node = {"type": "codeBlock", "attrs": {"language": lang}}
            if buf:
                node["content"] = [{"type": "text", "text": "\n".join(buf)}]
            content.append(node); continue
        m = re.match(r"^(#{1,4})\s+(.*)", line)
        if m:
            content.append({"type": "heading", "attrs": {"level": len(m.group(1))},
                            "content": parse_inline(m.group(2))})
            i += 1; continue
        if re.match(r"^---+\s*$", line):
            content.append({"type": "rule"}); i += 1; continue
        if line.strip().startswith("|") and i + 1 < len(lines) and re.match(r"^[\s|:\-]+$", lines[i + 1].strip()):
            rows = [("h", [c.strip() for c in line.strip().strip("|").split("|")])]
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(("c", [c.strip() for c in lines[i].strip().strip("|").split("|")])); i += 1
            ncols = max(len(r[1]) for r in rows)
            tbl = []
            for kind, cells in rows:
                cells = cells + [""] * (ncols - len(cells))
                ct = "tableHeader" if kind == "h" else "tableCell"
                rc = [{"type": ct, "content": [{"type": "paragraph",
                       "content": parse_inline(c) if c.strip() else [{"type": "text", "text": " "}]}]} for c in cells]
                tbl.append({"type": "tableRow", "content": rc})
            content.append({"type": "table", "content": tbl}); continue
        if re.match(r"^[-*]\s+", line):
            items, is_task = [], False
            while i < len(lines) and re.match(r"^[-*]\s+", lines[i]):
                m = re.match(r"^[-*]\s+(.*)", lines[i]); t = m.group(1)
                cb = re.match(r"^\[([ xX])\]\s+(.*)", t)
                if cb:
                    is_task = True
                    items.append(("DONE" if cb.group(1).lower() == "x" else "TODO", cb.group(2)))
                else:
                    items.append((None, t))
                i += 1
            if is_task:
                tasks = [{"type": "taskItem", "attrs": {"localId": str(uuid.uuid4()), "state": st or "TODO"},
                          "content": parse_inline(t)} for st, t in items]
                content.append({"type": "taskList", "attrs": {"localId": str(uuid.uuid4())}, "content": tasks})
            else:
                lis = [{"type": "listItem",
                        "content": [{"type": "paragraph", "content": parse_inline(t)}]} for _, t in items]
                content.append({"type": "bulletList", "content": lis})
            continue
        if re.match(r"^\d+\.\s+", line):
            items = []
            while i < len(lines) and re.match(r"^\d+\.\s+", lines[i]):
                m = re.match(r"^\d+\.\s+(.*)", lines[i]); items.append(m.group(1)); i += 1
            lis = [{"type": "listItem",
                    "content": [{"type": "paragraph", "content": parse_inline(t)}]} for t in items]
            content.append({"type": "orderedList", "content": lis}); continue
        if not line.strip():
            i += 1; continue
        para = [line]; i += 1
        while i < len(lines):
            l = lines[i]
            if (not l.strip() or l.startswith("```") or re.match(r"^#{1,4}\s", l)
                    or l.strip().startswith("|") or re.match(r"^[-*]\s", l)
                    or re.match(r"^\d+\.\s", l) or re.match(r"^---+\s*$", l)):
                break
            para.append(l); i += 1
        content.append({"type": "paragraph", "content": parse_inline(" ".join(para))})
    if not content:
        content = [{"type": "paragraph", "content": [{"type": "text", "text": " "}]}]
    return {"type": "doc", "version": 1, "content": content}


# ---------- frontmatter ----------

def parse_draft(path):
    text = Path(path).read_text()
    fm, body = "", text
    if text.startswith("---"):
        parts = text.split("---", 2)
        if len(parts) >= 3:
            fm, body = parts[1], parts[2].strip()
    meta = {}
    for ln in fm.split("\n"):
        s = ln.rstrip()
        if not s.strip() or s.lstrip().startswith("#"):
            continue
        if ":" not in s:
            continue
        k, _, v = s.partition(":")
        k = k.strip(); v = re.sub(r"\s+#.*$", "", v).strip()
        if v.startswith("[") and v.endswith("]"):
            meta[k] = [x.strip() for x in v[1:-1].split(",") if x.strip()]
        else:
            meta[k] = v.strip('"').strip("'")
    return meta, body


def lookup_user(query):
    s, users = api("GET", f"/rest/api/3/user/search?query={urllib.parse.quote(query)}&maxResults=10")
    if not isinstance(users, list):
        return None
    for u in users:
        em = (u.get("emailAddress") or "").lower()
        nm = (u.get("displayName") or "").lower()
        ql = query.lower()
        if ql in nm or ql in em:
            return u.get("accountId")
    return users[0].get("accountId") if users else None


import urllib.parse


def main():
    # Pre-resolve user accountIds
    user_map = {}
    for name in ["Doke", "Idris Fagbemi"]:
        aid = lookup_user(name)
        print(f"  accountId[{name}] = {aid}")
        if aid:
            user_map[name] = aid

    # Project + issue types
    s, proj = api("GET", "/rest/api/3/project/INFRA")
    print(f"\nProject fetch status={s}, name={proj.get('name')}")
    type_id_by_name = {it.get("name"): it.get("id") for it in (proj.get("issueTypes") or [])}
    print(f"Issue types: {type_id_by_name}")

    order = [
        ("tcp-sni-ingress-umbrella", "umbrella"),
        ("tcp-sni-phase0-cert-manager", "subtask"),
        ("tcp-sni-phase1-gateway-listeners", "subtask"),
        ("tcp-sni-phase2-backend-tls", "subtask"),
        ("tcp-sni-phase3-cidr-allowlist", "subtask"),
        ("tcp-sni-phase4-np-audit", "subtask"),
        ("tcp-sni-phase5-runbook", "subtask"),
    ]

    umbrella_key = None
    results = {}

    for slug, kind in order:
        files = list(DRAFTS_DIR.glob(f"{slug}.md"))
        if not files:
            print(f"\n!! no draft for {slug}")
            results[slug] = {"status": "MISSING"}; continue
        path = files[0]
        meta, body = parse_draft(path)
        # If this is a subtask, rewrite the parent token now that we know the umbrella key
        if kind == "subtask" and umbrella_key:
            body = body.replace("TBD-UMBRELLA", umbrella_key)

        m = re.search(r"^#\s+(.+)$", body, re.MULTILINE)
        title = m.group(1) if m else slug
        title = re.sub(r"\*\*", "", title); title = re.sub(r"`", "", title)
        body_no_title = re.sub(r"^#\s+.+\n", "", body, count=1, flags=re.MULTILINE)
        adf = md_to_adf(body_no_title)

        # Labels
        labels = meta.get("labels", [])
        if isinstance(labels, str):
            labels = [labels]
        labels = [re.sub(r"[^A-Za-z0-9_\-.]", "-", l.strip()) for l in labels if l.strip()]

        # Issue type
        type_name = meta.get("issuetype", "Story" if kind == "umbrella" else "Sub-task")
        # Be lenient — accept "Subtask" too
        type_id = type_id_by_name.get(type_name) or type_id_by_name.get("Sub-task") or type_id_by_name.get("Subtask")
        if not type_id:
            print(f"!! cannot resolve issue type {type_name}, available: {list(type_id_by_name.keys())}")
            results[slug] = {"status": "FAIL", "err": "no issue type"}; continue

        payload_fields = {
            "project": {"key": "INFRA"},
            "summary": title,
            "description": adf,
            "issuetype": {"id": type_id},
            "labels": labels,
        }

        # Assignee
        a_name = meta.get("assignee")
        if a_name and a_name in user_map:
            payload_fields["assignee"] = {"accountId": user_map[a_name]}

        # Parent (for sub-tasks)
        if kind == "subtask":
            parent_key = umbrella_key
            if not parent_key:
                print("!! umbrella not filed yet, cannot create sub-task")
                results[slug] = {"status": "SKIP", "err": "no parent"}; continue
            payload_fields["parent"] = {"key": parent_key}

        print(f"\n[POST] {title[:90]} ({type_name})")
        s, resp = api("POST", "/rest/api/3/issue", {"fields": payload_fields})
        print(f"  HTTP {s}")
        if s in (200, 201):
            new_key = resp.get("key")
            print(f"  CREATED {new_key}")
            results[slug] = {"status": "OK", "key": new_key, "draft": str(path)}
            if kind == "umbrella":
                umbrella_key = new_key
        else:
            print(f"  err: {json.dumps(resp)[:500]}")
            results[slug] = {"status": "FAIL", "err": resp}

    print("\n=== SUMMARY ===")
    for slug, r in results.items():
        print(f"  {r.get('status'):5}  {r.get('key', '-'):14}  {slug}")
    RESULTS.write_text(json.dumps(results, indent=2))
    print(f"\nResults: {RESULTS}")
    return 0 if all(r.get("status") == "OK" for r in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
