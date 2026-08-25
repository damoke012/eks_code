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
# SM_PATH is derived per cluster below; never a literal.
CRED_NAME="argocd-on-prem"   # stable: the script clears its own prior credential by this name
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
--check)
  CHECK_BR="${2:-op-dev}"
  # Do not assume the region or the store. Read them off the cluster.
  LIB="$(dirname "${BASH_SOURCE[0]}")/lib-onprem-ctx.sh"
  # shellcheck source=/dev/null
  source "$LIB"; onprem_resolve_ctx "$CHECK_BR" || exit 1
  K=(kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX")
  echo "== ClusterSecretStores on $CHECK_BR"
  "${K[@]}" get clustersecretstores.external-secrets.io \
     -o custom-columns=NAME:.metadata.name,REGION:.spec.provider.aws.region,SERVICE:.spec.provider.aws.service 2>&1
  echo
  echo "== an existing ExternalSecret, for the key convention actually in use"
  "${K[@]}" get externalsecrets.external-secrets.io -A \
     -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STORE:.spec.secretStoreRef.name,KEY:.spec.data[0].remoteRef.key 2>&1 | head -15
  echo
  echo "== grafana's azure-ad ExternalSecret -- the closest working analogue on this"
  echo "   cluster; the new one should mirror its shape, not invent a third."
  "${K[@]}" -n grafana get externalsecrets.external-secrets.io grafana-azure-ad-creds \
     -o jsonpath='{.spec}' 2>&1 | python3 -m json.tool 2>/dev/null || true
  echo
  echo "   The REGION column is what --secret writes to. A secret written to any"
  echo "   other region reports SecretSynced against nothing."
  ;;
--groups)
  # ApplicationGroup emits only groups ASSIGNED to the app. That is configured and
  # verified here, yet the id_token carried no groups claim at all on 2026-08-25
  # 14:29Z. SecurityGroup emits every security group the user belongs to, which is
  # a strictly wider set, so it distinguishes "Entra will not emit groups for this
  # app" from "ApplicationGroup specifically is not producing them".
  #
  # Overage is the reason to prefer ApplicationGroup: past ~200 groups Entra drops
  # the claim and sends _claim_names instead. This user is in 4, so SecurityGroup
  # is safe here -- but that is a fact about this directory, not a general licence.
  MODE="${2:-}"
  case "$MODE" in SecurityGroup|ApplicationGroup) : ;; *)
    echo "!! --groups takes SecurityGroup or ApplicationGroup (got '${MODE:-}')" >&2; exit 2 ;; esac
  OBJID=$(az ad app show --id "$APP_ID" --query id -o tsv) || exit 1
  BODY=$(python3 -c '
import json,sys
print(json.dumps({"groupMembershipClaims": sys.argv[1],
                  "optionalClaims": {"idToken": [{"name": "groups", "essential": False,
                                                  "additionalProperties": []}],
                                     "accessToken": [], "saml2Token": []}}))' "$MODE")
  echo "== setting groupMembershipClaims to $MODE"
  az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$OBJID" \
     --headers 'Content-Type=application/json' --body "$BODY" || exit 1
  az ad app show --id "$APP_ID" \
     --query '{groupMembershipClaims:groupMembershipClaims, idTokenClaims:optionalClaims.idToken}' -o json
  echo
  echo "   Sign out of Argo completely and sign in again in a fresh private window."
  echo "   A token already issued will not gain the claim."
  ;;
--secret)
  BR="${2:-}"; PROFILE="${3:-}"
  case "$BR" in op-dev|op-qa|op-prod) : ;; *)
    echo "!! usage: $0 --secret <op-dev|op-qa|op-prod> <aws-profile>" >&2; exit 2 ;; esac
  [ -n "$PROFILE" ] || { echo "!! usage: $0 --secret $BR <aws-profile>" >&2; exit 2; }
  CLUSTER="op-usxpress-${BR#op-}"
  SM_PATH="$CLUSTER/platform/argocd/azure-ad"
  case "$BR" in
    op-dev)  WANT_ACCOUNT=700736442855 ;;
    op-qa)   WANT_ACCOUNT=527101283767 ;;
    op-prod) WANT_ACCOUNT=937464026810
             if [ "${ALLOW_PROD_WRITE:-}" != "yes" ]; then
               echo "!! $BR is PRODUCTION. This writes a new secret into account $WANT_ACCOUNT." >&2
               echo "   Nothing has been done. To proceed deliberately, re-run as:" >&2
               echo "     ALLOW_PROD_WRITE=yes $0 --secret op-prod $PROFILE" >&2
               exit 3
             fi ;;
  esac
  CRED_NAME="argocd-on-prem-$BR"
  aws configure list-profiles 2>/dev/null | grep -qx "$PROFILE" || {
    echo "!! no such AWS profile: '$PROFILE'" >&2
    echo "   configured: $(aws configure list-profiles 2>/dev/null | tr '\n' ' ')" >&2; exit 2; }
  ACCT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>&1)
  case "$ACCT" in
    *"SSO session"*|*"Token has expired"*)
      echo "!! profile '$PROFILE' has an expired SSO session. Run:" >&2
      echo "   aws sso login --profile $PROFILE" >&2; exit 2 ;;
  esac
  [ "$ACCT" = "$WANT_ACCOUNT" ] || {
    echo "!! profile '$PROFILE' is account ${ACCT:-<unreadable>}, not $BR ($WANT_ACCOUNT)." >&2
    echo "   Writing the secret to the wrong account would sync green and serve nothing." >&2
    exit 2; }

  LIB="$(dirname "${BASH_SOURCE[0]}")/lib-onprem-ctx.sh"
  # shellcheck source=/dev/null
  source "$LIB"; onprem_resolve_ctx "$BR" || exit 1
  REGION=$(kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" \
             get clustersecretstores.external-secrets.io default \
             -o jsonpath='{.spec.provider.aws.region}' 2>/dev/null)
  [ -n "${REGION:-}" ] || { echo "!! could not read the region from op-dev's ClusterSecretStore." >&2
                            echo "   Run: $0 --check $BR" >&2; exit 1; }
  echo "== region $REGION, read from $BR's own ClusterSecretStore (not defaulted)"

  # Order matters. A credential's value is shown ONCE; if the store write then
  # fails, the credential survives on the app with nobody holding its value -- an
  # orphan. So: clear any credential this script left behind before, mint, and if
  # the write fails, delete the one just minted before exiting.
  OLD=$(az ad app credential list --id "$APP_ID" \
          --query "[?displayName=='$CRED_NAME'].keyId" --output tsv 2>/dev/null)
  for k in $OLD; do
    echo "   removing a previous '$CRED_NAME' credential ($k) -- its value was never stored"
    az ad app credential delete --id "$APP_ID" --key-id "$k" || exit 1
  done

  # --append, or every other credential on this app is deleted.
  echo "== minting a client secret (append: any credential not named '$CRED_NAME' survives)"
  CRED=$(az ad app credential reset --id "$APP_ID" --append \
           --display-name "$CRED_NAME" --years 2 -o json) || exit 1
  SECRET=$(printf '%s' "$CRED" | python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])')
  KEYID=$(printf '%s' "$CRED" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("keyId",""))')
  # az does not always return keyId on reset. Without it the cleanup below cannot
  # fire, so look it up by the display name this script controls.
  [ -n "${KEYID:-}" ] || KEYID=$(az ad app credential list --id "$APP_ID" \
        --query "[?displayName=='$CRED_NAME'].keyId | [0]" --output tsv 2>/dev/null)
  unset CRED
  [ ${#SECRET} -ge 30 ] || { echo "!! secret looks wrong (${#SECRET} chars)" >&2; unset SECRET; exit 1; }
  echo "   captured ${#SECRET} chars, keyId ${KEYID:-<unknown>}"

  abort_orphan() {
    echo "!! the store write failed. Deleting the credential just minted so it does" >&2
    echo "   not linger with nobody holding its value." >&2
    [ -n "${KEYID:-}" ] && az ad app credential delete --id "$APP_ID" --key-id "$KEYID" >/dev/null 2>&1
    unset SECRET PAYLOAD
    exit 1
  }

  # JSON with the SAME property names grafana's azure-ad secret uses, so the
  # ExternalSecret is a copy of a working one rather than a new convention.
  PAYLOAD=$(python3 -c '
import json,sys; print(json.dumps({"client_id": sys.argv[1], "client_secret": sys.argv[2]}))' \
    "$APP_ID" "$SECRET")
  if aws secretsmanager describe-secret --profile "$PROFILE" --region "$REGION" \
       --secret-id "$SM_PATH" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --profile "$PROFILE" --region "$REGION" \
      --secret-id "$SM_PATH" --secret-string "$PAYLOAD" \
      --query VersionId --output text || abort_orphan
  else
    aws secretsmanager create-secret --profile "$PROFILE" --region "$REGION" \
      --name "$SM_PATH" --secret-string "$PAYLOAD" \
      --query ARN --output text || abort_orphan
  fi
  unset SECRET PAYLOAD
  echo "   stored at $SM_PATH (account $ACCT, region $REGION) with keys client_id, client_secret"
  ;;
*)
  echo "!! usage: $0 --web | $0 --check <cluster> | $0 --groups <SecurityGroup|ApplicationGroup> | $0 --secret <cluster> <aws-profile>" >&2; exit 2 ;;
esac
