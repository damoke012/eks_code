#!/usr/bin/env bash
# INFRA-1674: do the things manifests/op-usxpress-prod would REFERENCE actually exist?
#
# READ ONLY. describe/get/head only — no create, no put, no update. Safe against prod.
#
# The manifests are the easy half. Every ExternalSecret in them names a Secrets Manager
# path in the PROD account; the ServiceAccount names an IRSA role; the RisingWave CR names
# an S3 bucket. If those are absent the stack reports SecretSynced and comes up empty —
# the failure this repo has hit twice already.
#
#   scripts/rw-prod-prereqs.sh                 # profile ops-controller
#   scripts/rw-prod-prereqs.sh <aws-profile>
set -uo pipefail

PROFILE="${1:-ops-controller}"
ACCOUNT="937464026810"
REGION="${AWS_REGION:-us-east-2}"
ROLE="op-usxpress-prod-risingwave"
BUCKET="risingwave-state-op-usxpress-prod"
SECRETS=(
  op-usxpress-prod/risingwave/postgres
  op-usxpress-prod/risingwave/root
  op-usxpress-prod/risingwave/svc-reporting
  op-usxpress-prod/risingwave/secret_store_private_key
  op-usxpress-prod/risingwave/console_license_key
  op-usxpress-prod/risingwave/dex_entra_client_secret
)

echo "profile ${PROFILE}  region ${REGION}  expecting account ${ACCOUNT}"
who=$(aws --profile "$PROFILE" sts get-caller-identity --query Account --output text 2>&1)
if [ "$who" != "$ACCOUNT" ]; then
  echo "REFUSING: profile ${PROFILE} resolves to '${who}', not prod ${ACCOUNT}" >&2
  echo "  aws sso login --profile ${PROFILE}" >&2
  exit 1
fi
echo "identity ok: ${who}"
echo

echo "== Secrets Manager (six paths the ExternalSecrets name) =="
missing=0
for s in "${SECRETS[@]}"; do
  out=$(aws --profile "$PROFILE" --region "$REGION" secretsmanager describe-secret \
          --secret-id "$s" --query '[Name,LastChangedDate]' --output text 2>&1)
  case "$out" in
    *ResourceNotFound*) printf '  MISSING  %s\n' "$s"; missing=$((missing+1)) ;;
    *AccessDenied*)     printf '  DENIED   %s   (cannot tell — fix the permission first)\n' "$s" ;;
    *)                  printf '  exists   %-52s %s\n' "$s" "$(echo "$out" | awk '{print $2}')" ;;
  esac
done

echo
echo "== IRSA role the ServiceAccount names =="
out=$(aws --profile "$PROFILE" iam get-role --role-name "$ROLE" \
        --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Federated' --output text 2>&1)
case "$out" in
  *NoSuchEntity*) echo "  MISSING  ${ROLE}"; missing=$((missing+1)) ;;
  *AccessDenied*) echo "  DENIED   ${ROLE}" ;;
  *)              echo "  exists   ${ROLE}"
                  echo "           trusts: ${out}"
                  case "$out" in
                    *d3rxit8f4yvshu*) echo "           OK — prod OIDC issuer" ;;
                    *) echo "           ⚠ NOT prod's issuer d3rxit8f4yvshu — check before trusting this" ;;
                  esac ;;
esac

echo
echo "== S3 bucket the RisingWave CR names =="
out=$(aws --profile "$PROFILE" --region "$REGION" s3api head-bucket --bucket "$BUCKET" 2>&1)
if [ -z "$out" ]; then echo "  exists   ${BUCKET}"
else
  case "$out" in
    *404*|*NotFound*) echo "  MISSING  ${BUCKET}"; missing=$((missing+1)) ;;
    *403*)            echo "  DENIED   ${BUCKET} (exists but not readable by this profile)" ;;
    *)                echo "  ?        ${BUCKET}: $(echo "$out" | head -1)" ;;
  esac
fi

echo
echo "== DNS for the hostnames the routes and certs would publish =="
for h in risingwave-dashboard.op-prod.usxpress.io rw-sql.op-prod.usxpress.io rw-postgres.op-prod.usxpress.io; do
  a=$(getent hosts "$h" 2>/dev/null | awk '{print $1}' | paste -sd, -)
  printf '  %-46s %s\n' "$h" "${a:-does not resolve}"
done

echo
echo "---"
if [ "$missing" -gt 0 ]; then
  echo "${missing} prerequisite(s) MISSING. Creating manifests/op-usxpress-prod before these"
  echo "exist gives you green ExternalSecrets with empty values — see the QA etcd-backup and"
  echo "Wiz cases. Build the prerequisites first."
else
  echo "No missing prerequisites detected. Verify the SECRET VALUES too — existence is not"
  echo "validity, and a placeholder secret has bitten us before (QA talosconfig)."
fi
