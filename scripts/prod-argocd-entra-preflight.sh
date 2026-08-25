#!/usr/bin/env bash
# INFRA-1639 -- everything that must be TRUE before op-prod is wired. READ-ONLY.
#
# op-prod is not op-qa with a different hostname. Verified 2026-08-25 it has neither
# configs.cm.url nor an rbac block, and the cluster has no persisted kubeconfig on
# this workstation, so its ClusterSecretStore has never been read.
#
#   scripts/prod-argocd-entra-preflight.sh
set -uo pipefail
# Resolve this BEFORE any cd. Gate 1 cds into the platform repo, which broke the
# relative lookup in gate 2 and reported the cluster as unreachable -- a check
# failing in a way indistinguishable from the thing it checks for.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BR=op-prod
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
ACCOUNT=937464026810
pass=0; fail=0; unk=0
ok(){ printf '   \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '   \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
huh(){ printf '   \033[33m????\033[0m  %s\n' "$1"; unk=$((unk+1)); }
val(){ printf '         %s\n' "$1"; }
say(){ printf '\n\033[1m== %s\033[0m\n' "$1"; }

say "1. Where op-prod keeps ExternalSecrets, and which apiVersion"
cd "$REPO" 2>/dev/null && git fetch -q origin || { echo "!! $REPO unavailable" >&2; exit 2; }
FILES=$(git grep -l 'kind: ExternalSecret' "origin/$BR" -- 'infrastructure/*.yaml' 2>/dev/null | sed "s|^origin/$BR:||")
if [ -n "$FILES" ]; then
  ok "$(printf '%s\n' "$FILES" | wc -l) ExternalSecret file(s) on the branch"
  printf '%s\n' "$FILES" | sed 's/^/         /' | head -8
  git grep -h -o 'external-secrets\.io/v[0-9a-z]*' "origin/$BR" -- '*.yaml' 2>/dev/null \
    | sort | uniq -c | sed 's/^/         /'
  ARGOCD_ES=$(printf '%s\n' "$FILES" | grep '^infrastructure/argocd' | head -1)
  [ -n "$ARGOCD_ES" ] && val "argocd ones live in: $(dirname "$ARGOCD_ES")" \
                      || no "none under infrastructure/argocd* -- the builder would guess"
else
  no "no ExternalSecret on op-prod at all -- nothing to copy the apiVersion from"
fi

say "2. Is the op-prod cluster reachable, and what is its ClusterSecretStore"
LIB="$SCRIPT_DIR/lib-onprem-ctx.sh"
if [ -f "$LIB" ] && command -v kubectl >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  if source "$LIB" && onprem_resolve_ctx "$BR" 2>/dev/null; then
    ok "resolved $ONPREM_CTX"
    kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" \
      get clustersecretstores.external-secrets.io \
      -o custom-columns=NAME:.metadata.name,REGION:.spec.provider.aws.region 2>&1 | sed 's/^/         /'
    kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" -n argocd \
      get deploy -o name 2>&1 | sed 's/^/         /'
  else
    no "no kubeconfig for $BR on this machine"
    val "the ExternalSecret would name a ClusterSecretStore nobody has verified exists"
  fi
else
  huh "kubectl or the lib unavailable"
fi

say "3. Can a human write the secret in $ACCOUNT"
if command -v aws >/dev/null 2>&1; then
  for P in ops-controller usx-prod; do
    A=$(aws sts get-caller-identity --profile "$P" --query Account --output text 2>&1)
    case "$A" in
      "$ACCOUNT") val "$P -> $A"
                  D=$(aws secretsmanager describe-secret --profile "$P" --region us-east-2 \
                        --secret-id "op-usxpress-prod/platform/argocd/azure-ad" 2>&1)
                  case "$D" in
                    *AccessDenied*)     no  "$P: AccessDenied -- needs the permission-set grant" ;;
                    *ResourceNotFound*) ok  "$P: reachable, secret absent (expected)" ;;
                    *ARN*)              ok  "$P: secret already exists" ;;
                    *)                  huh "$P: $(printf '%s' "$D" | head -1)" ;;
                  esac ;;
      *) val "$P -> ${A:0:60}" ;;
    esac
  done
else
  huh "aws not on PATH"
fi

say "4. Does op-prod even have an Argo route to land the callback on"
echo "   -- infrastructure/argocd-config on the branch --"
git ls-tree --name-only "origin/$BR" infrastructure/argocd-config/ 2>/dev/null | sed 's/^/         /'
VS=$(git grep -l 'kind: VirtualService' "origin/$BR" -- 'infrastructure/argocd*' 2>/dev/null)
if [ -n "$VS" ]; then
  ok "a VirtualService exists for argocd on the branch"
  printf '%s\n' "$VS" | sed "s|^origin/$BR:|         |"
else
  no "NO VirtualService for argocd on op-prod -- there is no route, so external-dns"
  val "publishes no record and the OIDC callback has nowhere to land. op-dev needed"
  val "one added (PR #126) before argocd.op-dev.usxpress.io resolved."
fi

R=$(dig +short argocd.op-prod.usxpress.io @1.1.1.1 2>/dev/null)
[ -n "$R" ] && { ok "argocd.op-prod.usxpress.io resolves"; printf '%s\n' "$R" | sed 's/^/         /'; } \
            || no "does not resolve -- prod has no Argo route yet; SSO would have nowhere to land"

printf '\n   PASS %d  FAIL %d  UNKNOWN %d\n' "$pass" "$fail" "$unk"
printf '   Nothing was created or changed.\n\n'
