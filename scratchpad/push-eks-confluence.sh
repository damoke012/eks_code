#!/usr/bin/env bash
# Publish the EKS Reference Architecture page to Confluence (space UI,
# under CloudOps Administration / 3631775785). Reuses the ADR-001 pattern.
set -euo pipefail
cd /workspaces/eks_code

CONF_BASE="https://usxpress.atlassian.net/wiki"
EMAIL="doke@usxpress.com"
SPACE_KEY="UI"
PARENT_ID="3631775785"          # CloudOps Administration
TITLE="USXpress Cloud Platform — EKS Reference Architecture"
BODY="/workspaces/eks_code/scratchpad/eks-confluence-body.xml"

# token: env first, else canonical scripts/push-to-confluence.sh (gitignored)
TOKEN="${ATLASSIAN_TOKEN:-${CONFLUENCE_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -f scripts/push-to-confluence.sh ]; then
  TOKEN="$(grep -m1 '^CONFLUENCE_TOKEN=' scripts/push-to-confluence.sh | cut -d= -f2- | tr -d "\"'")"
fi
[ -z "$TOKEN" ] && { echo "ERROR: no Confluence token (set ATLASSIAN_TOKEN or scripts/push-to-confluence.sh)"; exit 1; }

BODY_JSON="$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$BODY")"
RESP="$(curl -sS -u "$EMAIL:$TOKEN" -X POST "$CONF_BASE/rest/api/content" \
  -H 'Content-Type: application/json' \
  -d "{\"type\":\"page\",\"title\":\"$TITLE\",\"space\":{\"key\":\"$SPACE_KEY\"},\"ancestors\":[{\"id\":$PARENT_ID}],\"body\":{\"storage\":{\"value\":$BODY_JSON,\"representation\":\"storage\"}}}")"
python3 -c 'import json,sys
r=json.load(sys.stdin)
if r.get("_links"): print("✅ PAGE:", r["_links"]["base"]+r["_links"]["webui"])
else: print("❌ FAILED:\n"+json.dumps(r,indent=2))' <<<"$RESP"
