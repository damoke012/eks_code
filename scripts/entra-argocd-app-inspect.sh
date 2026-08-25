#!/usr/bin/env bash
# INFRA-1639 -- inspect the app registrations that already do Argo CD OIDC in this tenant.
#
# READ-ONLY. The preflight found that USX already runs Argo CD on Entra OIDC natively
# (four /auth/callback URIs on the "Argo CD" registration, cloud EKS fleet). That makes
# reuse a live option -- but only if this identity OWNS the app, and only if what the
# cloud fleet already decided about group claims suits on-prem too.
#
# Ownership is PER-APP. Being able to update the `risingwave` registration proves
# ownership of THAT app, not tenant-wide application write -- the preflight's gate 2
# says creation is denied, so ownership is the only lever left.
#
#   scripts/entra-argocd-app-inspect.sh
set -uo pipefail
command -v az >/dev/null 2>&1 || { echo "!! az not on PATH -- run this on WSL" >&2; exit 2; }

ME=$(az ad signed-in-user show --query id -o tsv 2>/dev/null)
MYUPN=$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null)
[ -n "$ME" ] || { echo "!! could not read the signed-in user" >&2; exit 1; }
echo "signed in as $MYUPN ($ME)"

# The three registrations in play. risingwave is the ownership control: update is
# already PROVEN there (2026-08-13), so whatever this script prints for it is what
# "I can update this" looks like.
APPS="
56078536-f4a3-4f92-810e-5106787019a8|Argo CD (cloud EKS fleet, 4 callbacks, 2 of them prod)
64d3523e-19bd-455d-a907-78f1bc2a3874|XT Argo Dev (sandbox, dex-style callback)
e112d6ce-cc60-4884-9898-8fcc5b78b0b1|risingwave (CONTROL -- update proven 2026-08-13)
"

printf '%s\n' "$APPS" | while IFS='|' read -r APPID LABEL; do
  [ -n "${APPID:-}" ] || continue
  printf '\n\033[1m== %s\033[0m\n   %s\n' "$APPID" "$LABEL"

  OWNERS=$(az ad app owner list --id "$APPID" \
             --query '[].{id:id,upn:userPrincipalName}' -o json 2>&1)
  if [ "$(printf '%s' "$OWNERS" | tr -d '[:space:]')" = "[]" ]; then
    # An empty JSON array is a real answer, not a failure: the read succeeded and the
    # app has ZERO registered owners. Nobody can update it without a directory role.
    printf '   \033[31mOWNER    NONE -- the app has no owners at all; only an\033[0m\n'
    printf '   \033[31m                 Application Administrator can change it\033[0m\n'
  elif printf '%s' "$OWNERS" | grep -q '"id"'; then
    if printf '%s' "$OWNERS" | grep -q "$ME"; then
      printf '   \033[32mOWNER    yes -- az ad app update would be accepted\033[0m\n'
    else
      printf '   \033[31mOWNER    no  -- update denied; someone on this list must do it\033[0m\n'
    fi
    printf '%s\n' "$OWNERS" | python3 -c '
import sys,json
try:
    for o in json.load(sys.stdin): print("            %s" % (o.get("upn") or o.get("id")))
except Exception: pass'
  else
    printf '   \033[33mOWNER    unreadable: %s\033[0m\n' "$(printf '%s' "$OWNERS" | head -1)"
  fi

  # How this app emits groups -- the question gate 4 raised. usx-cloud-admin is
  # cloud-only (no on-prem sync), so sam_account_name is NOT available to it and
  # object IDs are the only form a token can carry for that group.
  CFG=$(az ad app show --id "$APPID" \
          --query '{groupClaims:groupMembershipClaims,optional:optionalClaims,uris:web.redirectUris}' \
          -o json 2>&1)
  if printf '%s' "$CFG" | grep -q 'groupClaims'; then
    printf '%s\n' "$CFG" | sed 's/^/            /'
  else
    printf '   \033[33mCONFIG   unreadable: %s\033[0m\n' "$(printf '%s' "$CFG" | head -1)"
  fi
done

printf '\n   Nothing was created or changed by this script.\n\n'
