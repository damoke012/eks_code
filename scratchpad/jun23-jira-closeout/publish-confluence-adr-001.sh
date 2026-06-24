#!/bin/bash
# Publish ADR-001 Observability Phase 0 page to Confluence.
# Space: UI, Parent: Talos (3320938539).
set -euo pipefail

CONFLUENCE_URL="https://usxpress.atlassian.net/wiki"
CONFLUENCE_EMAIL="doke@usxpress.com"
SPACE_KEY="UI"
TALOS_PAGE_ID="3320938539"
TITLE="Observability Phase 0 — Decision Lock (op-usxpress-dev)"
MD_FILE="/workspaces/eks_code/iaac-drafts/jun24-observability-phase0-adr/confluence/ADR-001-observability-phase0.md"

# Pull token from canonical source
CONFLUENCE_TOKEN=""
while IFS= read -r ln; do
  case "$ln" in
    CONFLUENCE_TOKEN=*)
      CONFLUENCE_TOKEN="${ln#CONFLUENCE_TOKEN=}"
      CONFLUENCE_TOKEN="${CONFLUENCE_TOKEN//\"/}"
      CONFLUENCE_TOKEN="${CONFLUENCE_TOKEN//\'/}"
      break
      ;;
  esac
done < /workspaces/eks_code/scripts/push-to-confluence.sh

if [ -z "$CONFLUENCE_TOKEN" ]; then
  echo "ERROR: CONFLUENCE_TOKEN not found in scripts/push-to-confluence.sh" >&2
  exit 1
fi

# Convert markdown -> Confluence storage HTML
BODY_HTML=$(python3 /workspaces/eks_code/scripts/md-to-confluence-v2.py "$MD_FILE")

# JSON-escape via python (handles quotes + newlines safely)
BODY_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$BODY_HTML")

# Create the page
RESPONSE=$(curl -sS -u "$CONFLUENCE_EMAIL:$CONFLUENCE_TOKEN" \
  -X POST "$CONFLUENCE_URL/rest/api/content" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"page\",
    \"title\": \"$TITLE\",
    \"space\": {\"key\": \"$SPACE_KEY\"},
    \"ancestors\": [{\"id\": $TALOS_PAGE_ID}],
    \"body\": {
      \"storage\": {
        \"value\": $BODY_JSON,
        \"representation\": \"storage\"
      }
    }
  }")

PAGE_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('id','ERROR'))" 2>/dev/null || echo "ERROR")

if [ "$PAGE_ID" = "ERROR" ] || [ -z "$PAGE_ID" ]; then
  echo "FAILED:"
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
  exit 1
fi

echo "Published Confluence page id $PAGE_ID"
echo "URL: $CONFLUENCE_URL/spaces/$SPACE_KEY/pages/$PAGE_ID"
