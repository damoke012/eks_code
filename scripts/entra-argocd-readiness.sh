#!/usr/bin/env bash
# INFRA-1639 -- the two facts that decide HOW the Entra OIDC build is written.
#
# READ-ONLY. Two questions the earlier preflight could not answer:
#
#   A. Can this identity create an app registration RIGHT NOW, or after activating a
#      PIM role? `az rest /me/memberOf/directoryRole` lists only ACTIVE roles, so an
#      eligible-but-not-activated Application Administrator is invisible to it. That
#      is why the preflight said FAIL while the operator has the access.
#
#   B. Does Argo CD on this cluster support PKCE? If it does, the OIDC client needs
#      NO client secret -- which deletes the ExternalSecret, the Secrets Manager
#      write (no op-dev AWS profile exists on this box), and the rotation burden that
#      the RisingWave shared-app note flagged as its top open risk.
#
#   scripts/entra-argocd-readiness.sh op-dev
set -uo pipefail
BR="${1:-}"
case "$BR" in op-dev|op-qa|op-prod) : ;; *)
  echo "!! usage: $0 <op-dev|op-qa|op-prod>" >&2; exit 2 ;; esac

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()  { printf '   \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { printf '   \033[31mFAIL\033[0m  %s\n' "$1"; }
huh() { printf '   \033[33m????\033[0m  %s\n' "$1"; }
val() { printf '         %s\n' "$1"; }

say "A. Directory roles -- active now, and eligible via PIM"
if command -v az >/dev/null 2>&1; then
  ACTIVE=$(az rest --method GET \
    --url 'https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?$select=displayName' \
    -o json 2>/dev/null | python3 -c '
import sys,json
try: print("; ".join(r.get("displayName","?") for r in json.load(sys.stdin).get("value",[])) or "(none active)")
except Exception: print("(unreadable)")')
  val "active   : $ACTIVE"

  # PIM eligibility. Two APIs, because tenants differ on which is enabled.
  ME=$(az ad signed-in-user show --query id -o tsv 2>/dev/null)
  ELIG=""
  for U in \
    "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances?\$filter=principalId eq '$ME'&\$expand=roleDefinition" \
    "https://graph.microsoft.com/beta/roleManagement/directory/roleEligibilitySchedules?\$filter=principalId eq '$ME'&\$expand=roleDefinition" ; do
    R=$(az rest --method GET --url "$U" -o json 2>/dev/null) || continue
    E=$(printf '%s' "$R" | python3 -c '
import sys,json
try:
    v=json.load(sys.stdin).get("value",[])
    print("; ".join((x.get("roleDefinition") or {}).get("displayName","?") for x in v))
except Exception: print("")')
    [ -n "$E" ] && { ELIG="$E"; break; }
  done
  val "eligible : ${ELIG:-(none found, or the PIM API is not readable by this identity)}"

  case "$ACTIVE$ELIG" in
    *Application\ Administrator*|*Cloud\ Application\ Administrator*|*Global\ Administrator*)
      ok "an app-admin role is held or activatable -- creation is available"
      case "$ACTIVE" in
        *Administrator*) val "already active; no activation step needed" ;;
        *) val "ACTIVATE FIRST, in the portal (PIM > My roles > Activate), then re-run:" 
           val "  https://portal.azure.com/#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/aadmigratedroles" ;;
      esac ;;
    *) huh "no app-admin role seen in either list -- if creation still works, the"
       val "grant is arriving by a path neither API exposes. Prove it with the create." ;;
  esac
else
  huh "az not on PATH -- run on WSL"
fi

say "B. Argo CD version on $BR, and whether PKCE is available"
LIB="$(dirname "${BASH_SOURCE[0]}")/lib-onprem-ctx.sh"
if [ -f "$LIB" ] && command -v kubectl >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$LIB"
  if onprem_resolve_ctx "$BR"; then
    IMG=$(kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" -n argocd \
            get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    val "argocd-server image : ${IMG:-<not found>}"
    VER="${IMG##*:}"
    MAJ="${VER%%.*}"; REST="${VER#*.}"; MIN="${REST%%.*}"
    if [ -n "${MAJ:-}" ] && [ -n "${MIN:-}" ] && printf '%s%s' "$MAJ" "$MIN" | grep -qE '^[0-9]+$'; then
      if [ "$MAJ" -gt 2 ] || { [ "$MAJ" -eq 2 ] && [ "$MIN" -ge 8 ]; }; then
        ok "v$VER supports enablePKCEAuthentication -- a PUBLIC client, no client secret"
      else
        no "v$VER predates dependable PKCE support -- a confidential client and a secret are needed"
      fi
    else
      huh "could not parse a version from the image tag"
    fi
    DEX=$(kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" -n argocd \
            get deploy argocd-dex-server -o name 2>/dev/null)
    val "dex deployment      : ${DEX:-<none>}  (the OIDC route removes it)"
  else
    huh "could not resolve a kubeconfig for $BR"
  fi
else
  huh "kubectl or lib-onprem-ctx.sh unavailable -- run on WSL"
fi

printf '\n   Nothing was created or changed by this script.\n\n'
