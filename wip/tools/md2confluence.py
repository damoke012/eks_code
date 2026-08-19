#!/usr/bin/env python3
"""Publish a markdown file to Confluence Cloud as a page.

    JIRA_URL=https://usxpress.atlassian.net JIRA_USER=... JIRA_TOKEN=... \
      python3 wip/tools/md2confluence.py <file.md> "<Page Title>" <parentPageId> [spaceKey]

Re-running with the same title UPDATES the page rather than creating a duplicate.
Handles headings, paragraphs, tables, fenced code, lists, blockquotes, rules,
bold, inline code, strikethrough and links. [[wiki-links]] become inline code.
"""
import re, sys, json, os, base64, urllib.request, urllib.error, urllib.parse

def esc(t): return t.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")

def inline(t):
    t = esc(t)
    t = re.sub(r'\[\[([a-z0-9-]+)\]\]', r'<code>\1</code>', t)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', t)
    t = re.sub(r'~~([^~]+)~~', r'<s>\1</s>', t)
    t = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', t)
    return t

def convert(md):
    out, i, lines = [], 0, md.split("\n")
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("```"):
            lang = ln[3:].strip() or "text"; i += 1; buf = []
            while i < len(lines) and not lines[i].startswith("```"): buf.append(lines[i]); i += 1
            i += 1
            body = "\n".join(buf).replace("]]>", "]]]]><![CDATA[>")
            out.append('<ac:structured-macro ac:name="code"><ac:parameter ac:name="language">'
                       + lang + '</ac:parameter><ac:plain-text-body><![CDATA['
                       + body + ']]></ac:plain-text-body></ac:structured-macro>')
            continue
        if re.match(r'^\s*\|.*\|\s*$', ln) and i+1 < len(lines) and re.match(r'^\s*\|[\s:|-]+\|\s*$', lines[i+1]):
            hdr = [c.strip() for c in ln.strip().strip('|').split('|')]; i += 2; rows = []
            while i < len(lines) and re.match(r'^\s*\|.*\|\s*$', lines[i]):
                rows.append([c.strip() for c in lines[i].strip().strip('|').split('|')]); i += 1
            t = "<table><tbody><tr>" + "".join(f"<th>{inline(c)}</th>" for c in hdr) + "</tr>"
            for r in rows: t += "<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>"
            out.append(t + "</tbody></table>"); continue
        m = re.match(r'^(#{1,6})\s+(.*)$', ln)
        if m:
            l = min(len(m.group(1)), 6)
            out.append(f"<h{l}>{inline(m.group(2))}</h{l}>"); i += 1; continue
        if re.match(r'^(---|___|\*\*\*)\s*$', ln): out.append("<hr/>"); i += 1; continue
        if ln.startswith(">"):
            buf = []
            while i < len(lines) and lines[i].startswith(">"): buf.append(lines[i].lstrip(">").strip()); i += 1
            para, blocks = [], []
            for b in buf:
                if b: para.append(b)
                elif para: blocks.append(" ".join(para)); para = []
            if para: blocks.append(" ".join(para))
            out.append("<blockquote>" + "".join(f"<p>{inline(p)}</p>" for p in blocks) + "</blockquote>"); continue
        if re.match(r'^\s*[-*]\s+', ln) or re.match(r'^\s*\d+\.\s+', ln):
            ordered = bool(re.match(r'^\s*\d+\.\s+', ln)); items = []
            while i < len(lines) and (re.match(r'^\s*[-*]\s+', lines[i]) or re.match(r'^\s*\d+\.\s+', lines[i])
                                      or (lines[i].startswith("  ") and lines[i].strip() and items)):
                cur = lines[i]
                if re.match(r'^\s*[-*]\s+', cur) or re.match(r'^\s*\d+\.\s+', cur):
                    items.append(re.sub(r'^\s*(?:[-*]|\d+\.)\s+', '', cur))
                else: items[-1] += " " + cur.strip()
                i += 1
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>" + "".join(f"<li>{inline(x)}</li>" for x in items) + f"</{tag}>"); continue
        if not ln.strip(): i += 1; continue
        buf = []
        while i < len(lines) and lines[i].strip() and not lines[i].startswith(("#","```",">","|")) \
              and not re.match(r'^\s*[-*]\s+', lines[i]) and not re.match(r'^\s*\d+\.\s+', lines[i]) \
              and not re.match(r'^(---|___|\*\*\*)\s*$', lines[i]):
            buf.append(lines[i].strip()); i += 1
        out.append(f"<p>{inline(' '.join(buf))}</p>")
    return "".join(out)

def main():
    URL = os.environ["JIRA_URL"].rstrip("/")
    AUTH = base64.b64encode(f'{os.environ["JIRA_USER"]}:{os.environ["JIRA_TOKEN"]}'.encode()).decode()

    def call(m, p, b=None):
        r = urllib.request.Request(URL + p, method=m, data=json.dumps(b).encode() if b else None,
            headers={"Authorization": "Basic " + AUTH, "Content-Type": "application/json",
                     "Accept": "application/json"})
        try:
            with urllib.request.urlopen(r) as x:
                raw = x.read(); return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            print("  HTTP", e.code, e.read().decode()[:400]); raise

    path, title, parent = sys.argv[1], sys.argv[2], sys.argv[3]
    space = sys.argv[4] if len(sys.argv) > 4 else "UI"
    html = convert(open(path).read())
    found = call("GET", f"/wiki/rest/api/content?spaceKey={space}&title={urllib.parse.quote(title)}&expand=version")
    if found.get("results"):
        pg = found["results"][0]
        r = call("PUT", f"/wiki/rest/api/content/{pg['id']}", {
            "id": pg["id"], "type": "page", "title": title, "space": {"key": space},
            "version": {"number": pg["version"]["number"] + 1, "message": "updated from repo"},
            "body": {"storage": {"value": html, "representation": "storage"}}})
        print(f"UPDATED v{r['version']['number']}  {title}")
    else:
        r = call("POST", "/wiki/rest/api/content", {
            "type": "page", "title": title, "space": {"key": space},
            "ancestors": [{"id": parent}],
            "body": {"storage": {"value": html, "representation": "storage"}}})
        print(f"CREATED {r['id']}  {title}")
    print(f"   {URL}/wiki/spaces/{space}/pages/{r['id']}")

if __name__ == "__main__":
    main()
