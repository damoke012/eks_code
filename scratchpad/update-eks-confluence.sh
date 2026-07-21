#!/usr/bin/env bash
set -euo pipefail
cd /workspaces/eks_code
CONF_BASE="https://usxpress.atlassian.net/wiki"
EMAIL="doke@usxpress.com"
PAGE_ID="4627202050"
TITLE="USXpress Cloud Platform — EKS Reference Architecture"
BODY="/workspaces/eks_code/scratchpad/eks-confluence-body.xml"
[ -z "${ATLASSIAN_TOKEN:-}" ] && { echo "no token"; exit 1; }

CUR="$(curl -sS -u "$EMAIL:$ATLASSIAN_TOKEN" "$CONF_BASE/rest/api/content/$PAGE_ID?expand=version" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"]["number"])')"
NEXT=$((CUR+1))
echo "current version $CUR -> $NEXT"

BODY_JSON="$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$BODY")"
RESP="$(curl -sS -u "$EMAIL:$ATLASSIAN_TOKEN" -X PUT "$CONF_BASE/rest/api/content/$PAGE_ID" \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"$PAGE_ID\",\"type\":\"page\",\"title\":\"$TITLE\",\"version\":{\"number\":$NEXT},\"body\":{\"storage\":{\"value\":$BODY_JSON,\"representation\":\"storage\"}}}")"
python3 -c 'import json,sys
r=json.load(sys.stdin)
if r.get("_links"): print("✅ UPDATED v%s:"%r["version"]["number"], r["_links"]["base"]+r["_links"]["webui"])
else: print("❌ FAILED:\n"+json.dumps(r,indent=2))' <<<"$RESP"
