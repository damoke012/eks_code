#!/usr/bin/env bash
# INFRA-1639 -- move Argo CD On-Prem from an SPA client to a WEB (confidential) client.
#
# WHY: Entra rejects server-side redemption of a code issued to an SPA client:
#   AADSTS9002327 "Tokens issued for the 'Single-Page Application' client-type may
#   only be redeemed via cross-origin requests."
# argocd-server redeems the code itself, from the backend, so the SPA client type --
# and with it the no-client-secret PKCE design -- does not apply. The cloud EKS
# fleet's own "Argo CD" registration uses web.redirectUris for the same reason.
#
# Stage 1 (--web) moves the three redirect URIs from spa to web. No secret involved.
# Stage 2 (--secret PROFILE) mints a client secret and writes it straight to Secrets
# Manager without ever printing it.
#
#   scripts/entra-argocd-to-web-client.sh --web
#   scripts/entra-argocd-to-web-client.sh --secret <aws-profile-for-account-700736442855>
set -uo pipefail
command -v az >/dev/null 2>&1 || { echo "!! az not on PATH -- run this on WSL" >&2; exit 2; }

APP_ID="42dc0c33-4c56-47a5-b207-d119272997aa"
SM_PATH="op-usxpress-dev/argocd/entra_oidc_client_secret"
SM_KEY="ENTRA_OIDC_CLIENT_SECRET"
DEV_ACCOUNT="700736442855"
URIS='["https://argocd.op-dev.usxpress.io/auth/callback","https://argocd.op-qa.usxpress.io/auth/callback","https://argocd.op-prod.usxpress.io/auth/callback"]'

case "${1:-}" in
--web)
  OBJID=$(az ad app show --id "$APP_ID" --query id -o tsv) || exit 1
  BODY=$(python3 -c '
import json,sys
print(json.dumps({"web": {"redirectUris": json.loads(sys.argv[1])},
                  "spa": {"redirectUris": []}}))' "$URIS")
  echo "== moving redirect URIs from spa to web on $APP_ID"
  az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$OBJID" \
     --headers 'Content-Type=application/json' --body "$BODY" || exit 1
  echo "== readback"
  az ad app show --id "$APP_ID" \
     --query '{web:web.redirectUris, spa:spa.redirectUris}' -o json
  echo
  echo "   Expected: 3 under web, EMPTY under spa. Both matter -- Entra picks the"
  echo "   client type from where the redirect URI is registered, and a URI left"
  echo "   under spa keeps the cross-origin restriction alive for that URI."
  ;;
--secret)
  PROFILE="${2:-}"
  [ -n "$PROFILE" ] || { echo "!! usage: $0 --secret <aws-profile>" >&2; exit 2; }
  aws configure list-profiles 2>/dev/null | grep -qx "$PROFILE" || {
    echo "!! no such AWS profile: '$PROFILE'" >&2
    echo "   configured: $(aws configure list-profiles 2>/dev/null | tr '\n' ' ')" >&2; exit 2; }
  ACCT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account -o tsv 2>/dev/null)
  [ "$ACCT" = "$DEV_ACCOUNT" ] || {
    echo "!! profile '$PROFILE' is account ${ACCT:-<unreadable>}, not op-dev ($DEV_ACCOUNT)." >&2
    echo "   Writing the secret to the wrong account would sync green and serve nothing." >&2
    exit 2; }

  # --append, or every other credential on this app is deleted. The value is shown
  # once and never again, so it goes straight into a variable and then into Secrets
  # Manager -- never to the terminal, never through a shell history line.
  echo "== minting a client secret on $APP_ID (append: existing credentials survive)"
  SECRET=$(az ad app credential reset --id "$APP_ID" --append \
             --display-name "argocd on-prem 2026-08-25" --years 2 \
             --query password -o tsv) || exit 1
  [ ${#SECRET} -ge 30 ] || { echo "!! secret looks wrong (${#SECRET} chars)" >&2; unset SECRET; exit 1; }
  echo "   captured ${#SECRET} chars"

  # JSON, not a bare string: ESO reads a property out of it. A raw string syncs
  # green and serves nothing usable -- the 2026-08-13 trap.
  PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({sys.argv[1]: sys.argv[2]}))' "$SM_KEY" "$SECRET")
  if aws secretsmanager describe-secret --profile "$PROFILE" --secret-id "$SM_PATH" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --profile "$PROFILE" \
      --secret-id "$SM_PATH" --secret-string "$PAYLOAD" --query VersionId -o text || exit 1
  else
    aws secretsmanager create-secret --profile "$PROFILE" \
      --name "$SM_PATH" --secret-string "$PAYLOAD" --query ARN -o text || exit 1
  fi
  unset SECRET PAYLOAD
  echo "   stored at $SM_PATH key $SM_KEY (account $ACCT)"
  ;;
*)
  echo "!! usage: $0 --web | $0 --secret <aws-profile>" >&2; exit 2 ;;
esac
