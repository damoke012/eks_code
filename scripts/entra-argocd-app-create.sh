#!/usr/bin/env bash
# INFRA-1639 -- create the on-prem Argo CD app registration in Entra, once, for all
# three clusters. Dry-run by default; --create performs the writes.
#
# WHY A NEW REGISTRATION, not the existing "Argo CD" (56078536-...):
#   that one serves four cloud EKS instances, two of them PRODUCTION, and has ZERO
#   registered owners. `az ad app update --web-redirect-uris` REPLACES the list, so a
#   single mistake there takes out prod Argo for the cloud fleet. The RisingWave note
#   of 2026-08-13 lists "separate app registrations per environment" as its top open
#   risk for exactly this reason. On-prem gets its own.
#
# WHY NO CLIENT SECRET:
#   registered as a PUBLIC client with SPA redirect URIs, so Argo uses PKCE
#   (enablePKCEAuthentication). That removes the client secret entirely, and with it
#   the ExternalSecret, the Secrets Manager write (there is no op-dev AWS profile on
#   this machine), and every future rotation. Confirm PKCE support first:
#     scripts/entra-argocd-readiness.sh op-dev
#
# WHY ONE APP FOR THREE CLUSTERS:
#   the redirect URI is what separates them, and all three are registered up front so
#   QA and prod need no further Entra work. Access is still per-cluster, because
#   policy.csv lives on each cluster.
#
#   scripts/entra-argocd-app-create.sh            # dry run: print every call
#   scripts/entra-argocd-app-create.sh --create
set -uo pipefail
DO_IT=false; [ "${1:-}" = "--create" ] && DO_IT=true
command -v az >/dev/null 2>&1 || { echo "!! az not on PATH -- run this on WSL" >&2; exit 2; }

APP_NAME="Argo CD On-Prem"
GROUP="usx-cloud-admin"
GROUP_ID="b9a1ff74-efa1-4b20-be8a-8706a5ab2636"   # verified 2026-08-25, cloud-only group
URIS='["https://argocd.op-dev.usxpress.io/auth/callback","https://argocd.op-qa.usxpress.io/auth/callback","https://argocd.op-prod.usxpress.io/auth/callback"]'
DEFAULT_ACCESS_ROLE="00000000-0000-0000-0000-000000000000"

run() {
  if $DO_IT; then
    printf '\033[36m+ %s\033[0m\n' "$*" >&2
    "$@"
  else
    printf '\033[90mwould run: %s\033[0m\n' "$*" >&2
  fi
}

# ------------------------------------------------------------------ idempotence
EXIST=$(az ad app list --all --filter "displayName eq '$APP_NAME'" --query '[0].appId' -o tsv 2>/dev/null)
if [ -n "${EXIST:-}" ] && [ "$EXIST" != "None" ]; then
  echo "== '$APP_NAME' already exists: $EXIST -- reusing, not creating"
  APPID="$EXIST"
else
  echo "== creating '$APP_NAME'"
  if $DO_IT; then
    APPID=$(az ad app create --display-name "$APP_NAME" \
              --sign-in-audience AzureADMyOrg --query appId -o tsv) || {
      echo "!! create failed. If this is a permissions error, activate the PIM role first:" >&2
      echo "   scripts/entra-argocd-readiness.sh op-dev" >&2; exit 1; }
    echo "   appId $APPID"
  else
    run az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg
    APPID="APPID-ASSIGNED-ON-CREATE"
  fi
fi

# ------------------------------------------- SPA redirect URIs + the groups claim
# `az ad app update` has no SPA flag, so this goes through Graph directly. SPA (not
# web) is what makes it a public client, which is what allows PKCE without a secret.
# groupMembershipClaims=ApplicationGroup mirrors the cloud fleet's "Argo CD" app: only
# groups ASSIGNED to this app appear in the token, which also avoids the >200-group
# overage claim that would silently drop groups altogether.
BODY=$(python3 -c '
import json,sys
print(json.dumps({
  "spa": {"redirectUris": json.loads(sys.argv[1])},
  "groupMembershipClaims": "ApplicationGroup",
  "optionalClaims": {"idToken": [{"name": "groups", "essential": False, "additionalProperties": []}],
                     "accessToken": [], "saml2Token": []},
}))' "$URIS")
echo "== redirect URIs (SPA), group claims"
printf '   %s\n' "$BODY"
if $DO_IT; then
  OBJID=$(az ad app show --id "$APPID" --query id -o tsv)
  run az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$OBJID" \
      --headers 'Content-Type=application/json' --body "$BODY"
else
  echo "   would PATCH https://graph.microsoft.com/v1.0/applications/<objectId of $APPID>"
fi

# ----------------------------------- service principal + assign the RBAC group
echo "== service principal, assignment-required, and the $GROUP assignment"
if $DO_IT; then
  SPID=$(az ad sp show --id "$APPID" --query id -o tsv 2>/dev/null)
  [ -n "${SPID:-}" ] || SPID=$(az ad sp create --id "$APPID" --query id -o tsv)
  echo "   servicePrincipal $SPID"
  # Only assigned principals may sign in -- and with ApplicationGroup claims, the
  # assignment is also what puts the group into the token.
  run az ad sp update --id "$SPID" --set appRoleAssignmentRequired=true
  ASSIGN=$(python3 -c '
import json,sys
print(json.dumps({"principalId": sys.argv[1], "resourceId": sys.argv[2], "appRoleId": sys.argv[3]}))' \
    "$GROUP_ID" "$SPID" "$DEFAULT_ACCESS_ROLE")
  run az rest --method POST \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SPID/appRoleAssignedTo" \
      --headers 'Content-Type=application/json' --body "$ASSIGN"
else
  echo "   would create the SP, set appRoleAssignmentRequired=true,"
  echo "   and assign group $GROUP ($GROUP_ID) with the default-access role"
fi

# --------------------------------------------------- the block Argo needs
TENANT=$(az account show --query tenantId -o tsv 2>/dev/null)
cat <<OUT

== Argo CD side -- this is what goes into configs.cm (no Dex, no secret)

      oidc.config: |
        name: Entra
        issuer: https://login.microsoftonline.com/$TENANT/v2.0
        clientID: $APPID
        enablePKCEAuthentication: true
        requestedScopes: ["openid", "profile", "email", "groups"]

    and configs.rbac.policy.csv:

        # $GROUP -- Entra emits the group OBJECT ID, not the name, because the
        # group is cloud-only (no on-prem AD sync), so a display name is not
        # available in the token. Verified 2026-08-25.
        g, $GROUP_ID, role:admin

OUT
$DO_IT || echo "   DRY RUN -- nothing was created. Re-run with --create."
