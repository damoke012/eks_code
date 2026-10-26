#!/usr/bin/env bash
# Publish the Argo CD deployment standard to Confluence (space UI, under CloudOps Administration).
#
#   bash scripts/push-argocd-standard-confluence.sh
#
# Written for Parul to compare the EKS Argo CD deployment against on-prem.
#
# Re-running UPDATES the page in place -- md2confluence.py looks the title up first,
# so this never creates a duplicate. The token comes from the gitignored
# scripts/push-to-confluence.sh, the same file the other doc pushes read. It is
# never printed; only which file it came from is.
set -uo pipefail

SRC=wip/argocd-standard/CONFLUENCE-argocd-deployment-standard.md
TITLE="How Argo CD is deployed on-prem, and what to copy for cloud"
PARENT=3631775785          # CloudOps Administration
SPACE=UI
TOOL=wip/tools/md2confluence.py
CREDS=scripts/push-to-confluence.sh

for f in "$SRC" "$TOOL" "$CREDS"; do
  if [ ! -f "$f" ]; then echo "NOT PUBLISHED - missing $f"; exit 1; fi
done

TOKEN="$(grep -m1 '^CONFLUENCE_TOKEN=' "$CREDS" | cut -d= -f2- | tr -d "\"'")"
if [ -z "$TOKEN" ]; then
  echo "NOT PUBLISHED - no CONFLUENCE_TOKEN line in $CREDS"; exit 1
fi
echo "  token source: $(basename "$CREDS")"

# The page title already carries the H1, so drop it from the body.
BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
tail -n +2 "$SRC" > "$BODY"
echo "  body lines: $(wc -l < "$BODY")  (source $(wc -l < "$SRC"))"
# Count header SEPARATORS, each cell of which must contain a dash. The looser
# '^\|[-: |]+\|$' also matches an empty header row like '| | |', which this very
# document has, and it reported 7 tables against the page's 6 -- a counter raising
# a false alarm about a page that was fine.
echo "  tables: $(grep -cE '^\|( *:?-+:? *\|)+$' "$BODY")  target: $SPACE / parent $PARENT"

JIRA_URL=https://usxpress.atlassian.net \
JIRA_USER=doke@usxpress.com \
JIRA_TOKEN="$TOKEN" \
  python3 "$TOOL" "$BODY" "$TITLE" "$PARENT" "$SPACE"

# --- read the page back: CREATED is the API's word, not evidence it rendered ---
PAGE=$(python3 - "$TOKEN" "$TITLE" "$SPACE" <<'PY'
import sys, json, base64, urllib.request, urllib.parse
tok, title, space = sys.argv[1], sys.argv[2], sys.argv[3]
auth = base64.b64encode(f"doke@usxpress.com:{tok}".encode()).decode()
q = ("https://usxpress.atlassian.net/wiki/rest/api/content"
     f"?spaceKey={space}&title={urllib.parse.quote(title)}&expand=body.storage,version,ancestors")
r = urllib.request.Request(q, headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
d = json.loads(urllib.request.urlopen(r).read())
if not d.get("results"):
    print("ABSENT"); sys.exit(0)
p = d["results"][0]; b = p["body"]["storage"]["value"]
print(p["id"], p["version"]["number"], p["ancestors"][-1]["id"] if p.get("ancestors") else "no-parent",
      len(b), b.count("<table>"), b.count("<h2>"), b.count("ac:name=\"code\""))
PY
)
echo "  readback: id/version/parent/chars/tables/h2/code-macros = $PAGE"
echo "  url: https://usxpress.atlassian.net/wiki/spaces/$SPACE/pages/${PAGE%% *}"
