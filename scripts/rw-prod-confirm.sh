#!/usr/bin/env bash
# INFRA-1674 — confirm every claim the prod plan rests on.
#
# READ-ONLY. Only describe/list/get calls. Nothing here mutates anything, in any
# account. Every AWS call is pinned to an explicitly resolved --profile, and the
# profile is resolved by asking STS which account it lands in — never by name.
#
# Claims under test:
#   1. op-usxpress-prod is account 937464026810
#   2. 786352483360 (the wrong ID in INFRA-1675) — is it one of ours?
#   3. QA's five secrets exist, and are named the way the module derives them
#   4. QA's bucket and IRSA role match the ${cluster_name} convention
#   5. prod's OIDC issuer is d3rxit8f4yvshu
#   6. QA's DNS records exist and prod's do not — and what QA points at
#   7. dex_entra_client_secret is genuinely absent from the Terraform
#   8. what value Terraform writes into console_license_key
#
# Usage: bash rw-prod-confirm.sh [path-to-iaac-risingwave-onprem-clone]

set -uo pipefail

REPO="${1:-$HOME/pr-work/iaac-risingwave-onprem}"
QA_ACCT=527101283767
PROD_ACCT=937464026810
DEV_ACCT=700736442855
MYSTERY_ACCT=786352483360

hr() { printf '\n=== %s\n' "$1"; }
ok() { printf '  OK       %s\n' "$1"; }
no() { printf '  MISMATCH %s\n' "$1"; }
info() { printf '           %s\n' "$1"; }

# ── Map every configured profile to the account it actually reaches ──────────
hr "profiles and the accounts they resolve to"
declare -A ACCT_PROFILE=()
while read -r p; do
  [ -z "$p" ] && continue
  acct=$(aws sts get-caller-identity --profile "$p" --query Account --output text 2>/dev/null)
  if [ -n "$acct" ] && [ "$acct" != "None" ]; then
    printf '  %-28s -> %s\n' "$p" "$acct"
    [ -z "${ACCT_PROFILE[$acct]:-}" ] && ACCT_PROFILE[$acct]="$p"
  else
    printf '  %-28s -> (no valid session)\n' "$p"
  fi
done < <(aws configure list-profiles 2>/dev/null)

hr "claim 1 + 2 — which accounts do we actually reach?"
for a in "$PROD_ACCT" "$QA_ACCT" "$DEV_ACCT"; do
  if [ -n "${ACCT_PROFILE[$a]:-}" ]; then ok "$a reachable via profile ${ACCT_PROFILE[$a]}"
  else info "$a — no profile with a live session (not proof it is wrong)"; fi
done
if [ -n "${ACCT_PROFILE[$MYSTERY_ACCT]:-}" ]; then
  no "$MYSTERY_ACCT IS one of ours — via ${ACCT_PROFILE[$MYSTERY_ACCT]}. Find out which cluster it is."
else
  info "$MYSTERY_ACCT — no profile reaches it. Still worth asking; absence here is not absence."
fi

QAP="${ACCT_PROFILE[$QA_ACCT]:-}"
PRODP="${ACCT_PROFILE[$PROD_ACCT]:-}"

# ── Claim 3 — QA's secrets, named as the module derives them ─────────────────
hr "claim 3 — QA secrets (account $QA_ACCT) under op-usxpress-qa/risingwave/"
if [ -z "$QAP" ]; then
  info "SKIPPED — no live QA profile. Re-run after logging in; do not read this as absence."
else
  for s in postgres root svc-reporting secret_store_private_key console_license_key dex_entra_client_secret; do
    path="op-usxpress-qa/risingwave/$s"
    if aws secretsmanager describe-secret --secret-id "$path" \
         --profile "$QAP" --region us-east-2 >/dev/null 2>&1; then
      ok "$path"
    else
      no "$path  (absent in QA)"
    fi
  done
fi

# ── Claim 4 — QA bucket + role names match ${cluster_name} convention ────────
hr "claim 4 — QA bucket and IRSA role naming (account $QA_ACCT)"
if [ -z "$QAP" ]; then
  info "SKIPPED — no live QA profile."
else
  info "buckets matching 'risingwave':"
  aws s3api list-buckets --profile "$QAP" \
    --query "Buckets[?contains(Name,'risingwave')].Name" --output text 2>/dev/null \
    | tr '\t' '\n' | sed 's/^/    /'
  if aws iam get-role --role-name op-usxpress-qa-risingwave --profile "$QAP" >/dev/null 2>&1; then
    ok "role op-usxpress-qa-risingwave exists -> prod convention is op-usxpress-prod-risingwave"
  else
    no "role op-usxpress-qa-risingwave NOT found — the naming convention assumption is wrong"
    info "roles matching 'risingwave':"
    aws iam list-roles --profile "$QAP" \
      --query "Roles[?contains(RoleName,'risingwave')].RoleName" --output text 2>/dev/null \
      | tr '\t' '\n' | sed 's/^/    /'
  fi
fi

# ── Claim 5 — prod OIDC issuer ───────────────────────────────────────────────
hr "claim 5 — prod OIDC issuer (expect d3rxit8f4yvshu)"
if [ -z "$PRODP" ]; then
  info "SKIPPED — no live prod profile."
else
  aws iam list-open-id-connect-providers --profile "$PRODP" \
    --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null \
    | tr '\t' '\n' | sed 's/^/    /'
  info "the prod issuer must appear above, or the IRSA trust policy will build and never assume"
fi

# ── Claim 6 — DNS ────────────────────────────────────────────────────────────
hr "claim 6 — DNS: QA resolves, prod does not"
for h in risingwave-dashboard rw-sql rw-postgres; do
  for env in qa prod; do
    fqdn="$h.op-$env.usxpress.io"
    ans=$(dig +short "$fqdn" 2>/dev/null | tr '\n' ' ')
    if [ -n "$ans" ]; then printf '  RESOLVES %-46s %s\n' "$fqdn" "$ans"
    else printf '  no rec   %s\n' "$fqdn"; fi
  done
done
info "QA's answers are the targets to quote in the networking request"

# ── Claims 7 + 8 — read the Terraform, no AWS ────────────────────────────────
hr "claim 7 — is dex_entra_client_secret in the Terraform?"
if [ ! -d "$REPO/deploy/terraform" ]; then
  info "SKIPPED — no clone at $REPO"
else
  if grep -rn "dex_entra_client_secret" "$REPO/deploy/terraform/" 2>/dev/null | sed 's/^/    /' | grep -q .; then
    no "it IS referenced — re-read; the 'five of six' claim is wrong"
  else
    ok "absent from all of deploy/terraform — it is hand-created, and gated on the Entra registration"
  fi

  hr "claim 8 — what value does Terraform write into console_license_key?"
  awk '/resource "aws_secretsmanager_secret_version" "console_license_key"/,/^}/' \
    "$REPO/deploy/terraform/secrets.tf" | sed 's/^/    /'
  info "if that is a literal placeholder, creating the secret does not make the console work"

  hr "bonus — are the import blocks gone on this branch?"
  # grep -c prints 0 AND exits 1 on no match, so `|| echo 0` would append a second 0.
  n=$(grep -c '^import {' "$REPO/deploy/terraform/secrets.tf" 2>/dev/null); n=${n:-0}
  [ "$n" = "0" ] && ok "0 import blocks" || no "$n import blocks still present"
fi

hr "done"
info "MISMATCH lines are the ones that change the plan. SKIPPED is not a pass."
