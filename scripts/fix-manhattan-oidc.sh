#!/usr/bin/env bash
# Add a flexible federated identity credential to usx-gha-manhattan-deploy so that
# ANY branch of manhattan-dl-handler can authenticate, instead of adding one
# credential per branch by hand. Fourth occurrence: whitelistFix (2026-08-11),
# addCodesAndUpdateCols (2026-08-19), MAN-425 (2026-09-11), and one before those.
#
# Azure does an EXACT STRING MATCH on the token's sub claim. AADSTS700213 is not a
# permissions fault and there is no "restriction" to remove -- the entry is missing.
#
# Run on WSL, logged in to tenant bbb5a66d-5c9f-482a-969a-a40304b6bc8d.
# See .claude/skills/azure-oidc-federation/SKILL.md. INFRA-1649.
set -euo pipefail

OBJ=3ddc61b9-d96b-4ed1-85c2-efa1cfe3462d   # usx-gha-manhattan-deploy (appId 89e86365-dcfb-494a-a7e5-7b1d8bae2169)
NAME=gha-manhattan-dl-handler-any-branch
EXPR="claims['sub'] matches 'repo:usxpressinc/manhattan-dl-handler:ref:refs/heads/*'"

echo "== federated credentials on usx-gha-manhattan-deploy today =="
az ad app federated-credential list --id "$OBJ" \
  --query '[].{name:name,subject:subject}' -o table
N=$(az ad app federated-credential list --id "$OBJ" --query 'length(@)' -o tsv)
echo
echo "count: $N of 20 (Azure's hard cap per app registration)"

if az ad app federated-credential list --id "$OBJ" --query '[].name' -o tsv | grep -qx "$NAME"; then
  echo "already present: $NAME -- nothing to do."
  exit 0
fi

echo
read -r -p "create the any-branch credential on this registration? type yes: " ANS
[ "$ANS" = yes ] || { echo "aborted, nothing changed."; exit 1; }

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
python3 - "$TMP" "$NAME" "$EXPR" <<'PY'
import json, sys
path, name, expr = sys.argv[1], sys.argv[2], sys.argv[3]
# claimsMatchingExpression and subject are mutually exclusive: a flexible FIC has no subject.
json.dump({
    "name": name,
    "issuer": "https://token.actions.githubusercontent.com",
    "audiences": ["api://AzureADTokenExchange"],
    "description": "Any branch of manhattan-dl-handler. Deploy gating is enforced by ADO release triggers and version filters, not by this credential. INFRA-1649.",
    "claimsMatchingExpression": {"value": expr, "languageVersion": 1},
}, open(path, "w"))
PY

# az ad app federated-credential create does not yet understand claimsMatchingExpression.
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJ/federatedIdentityCredentials" \
  --headers 'Content-Type=application/json' --body "@$TMP" -o none

echo
echo "== after =="
az ad app federated-credential list --id "$OBJ" \
  --query '[].{name:name,subject:subject}' -o table
echo
echo "Re-run the failed job now. No PR merge, no workflow change needed."
echo "Clean up the per-branch credentials ONLY after a confirmed green run -- keep master and pull_request."
