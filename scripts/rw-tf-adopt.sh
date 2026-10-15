#!/usr/bin/env bash
#
# rw-tf-adopt.sh <dev|qa> -- adopt an EXISTING RisingWave on-prem estate into
# Terraform state, then plan. It NEVER applies.
#
# WHY THIS EXISTS. Verified 2026-10-15: iaac-risingwave-onprem has no Terraform
# state anywhere in the dev account. Every bucket was searched; the only
# risingwave keys belong to other projects. So the S3 bucket, the IRSA role, the
# role policy, the five platform secrets and the five hand-made app secrets all
# exist and are managed by nothing. A first apply would 409 on all 26.
#
# The import is also the PROOF: a plan that shows no changes to any aws_
# resource demonstrates the module's config matches a real environment. That is
# non-destructive validation, and it is what makes prod safe later without
# inverting the promotion order by applying an unproven module there first.
#
# ⚠️ THE ONE DESTRUCTIVE OUTCOME, and why versions are imported too.
# ignore_changes = [secret_string] suppresses an UPDATE, not a CREATE. Import a
# secret but not its version and Terraform will CREATE a version -- overwriting
# a live credential with a generated value or a placeholder. Every secret here
# is imported as a PAIR.
#
# Acceptance criterion is NOT "zero changes". The six random_password/random_id
# resources are not in state either, so the plan will want to create them. That
# is inert: they feed secret_string, which ignore_changes protects. What must
# show no changes is every aws_ resource.

set -euo pipefail

ENVNAME="${1:-}"
MODE="${2:---dry-run}"

RED=$(tput setaf 1 2>/dev/null || true); GRN=$(tput setaf 2 2>/dev/null || true)
YEL=$(tput setaf 3 2>/dev/null || true); BLD=$(tput bold 2>/dev/null || true)
RST=$(tput sgr0 2>/dev/null || true)
die()  { printf '%s%s%s\n' "$RED" "$1" "$RST" >&2; exit 1; }
warn() { printf '%s⚠ %s%s\n' "$YEL" "$1" "$RST"; }
ok()   { printf '%s✓ %s%s\n' "$GRN" "$1" "$RST"; }
head2(){ printf '\n%s== %s ==%s\n' "$BLD" "$1" "$RST"; }

case "$ENVNAME" in
  dev) WANT_ACCT=700736442855; CLUSTER=op-usxpress-dev; OIDC=d3a7wcnazdrd6p.cloudfront.net ;;
  qa)  WANT_ACCT=527101283767; CLUSTER=op-usxpress-qa;  OIDC=d2t7d36wmf0hbm.cloudfront.net ;;
  prod)
    die "REFUSED. prod state is not adopted from a laptop. Rule 1: never mutate
production from this repo. Do prod through Octopus once dev and QA both plan clean." ;;
  *) die "usage: $0 <dev|qa> [--dry-run|--import]   (default --dry-run)" ;;
esac
case "$MODE" in --dry-run|--import) : ;; *) die "mode must be --dry-run or --import" ;; esac

for t in terraform aws jq gh; do command -v "$t" >/dev/null 2>&1 || die "$t is not installed"; done

# ── the profile, resolved by ACCOUNT and never by name ──────────────────────
# There is no op-dev profile on this box; dev is usx-dev. Resolve, never guess.
head2 "Resolving the AWS profile for account $WANT_ACCT"
PROFILE=""
for p in $(aws configure list-profiles 2>/dev/null); do
  a=$(aws sts get-caller-identity --profile "$p" --query Account --output text 2>/dev/null) || true
  if [ "$a" = "$WANT_ACCT" ]; then PROFILE="$p"; break; fi
done
[ -n "$PROFILE" ] || die "no configured profile has a live session for $WANT_ACCT.
Log in first. An empty --profile silently selects the DEFAULT profile."
ok "profile '$PROFILE' -> $WANT_ACCT"
export AWS_PROFILE="$PROFILE"

head2 "Backend coordinates (Octopus is the only source: s3 ls is denied to platform-admin)"
read -r -p "  S3_BUCKET for $ENVNAME: " S3_BUCKET
read -r -p "  TF_STATE_KEY for $ENVNAME: " TF_STATE_KEY
read -r -p "  s3_bucket_prefix (the Hummock bucket, e.g. risingwave-state-$CLUSTER): " BUCKET_PREFIX
[ -n "$S3_BUCKET" ] && [ -n "$TF_STATE_KEY" ] && [ -n "$BUCKET_PREFIX" ] \
  || die "all three are required; an empty backend value is how you init the wrong state"

head2 "Does a state file already exist at that key?"
if aws s3api head-object --bucket "$S3_BUCKET" --key "$TF_STATE_KEY" >/dev/null 2>&1; then
  warn "state ALREADY EXISTS at s3://$S3_BUCKET/$TF_STATE_KEY"
  warn "This script is for an UNMANAGED estate. Read the existing state first."
  read -r -p "  type CONTINUE to proceed anyway: " c
  [ "$c" = "CONTINUE" ] || die "stopped"
else
  ok "no state at that key - consistent with an unmanaged estate"
fi

D=$(mktemp -d)
head2 "Cloning the module into $D"
gh repo clone variant-inc/iaac-risingwave-onprem "$D/repo" -- --depth 1 -q
cd "$D/repo/deploy/terraform"

cat > adopt.auto.tfvars <<VARS
cluster_name     = "$CLUSTER"
oidc_issuer      = "$OIDC"
s3_bucket_prefix = "$BUCKET_PREFIX"
VARS
ok "wrote adopt.auto.tfvars (throwaway clone, never committed)"

head2 "terraform init"
terraform init -input=false -reconfigure \
  -backend-config="bucket=$S3_BUCKET" \
  -backend-config="key=$TF_STATE_KEY" \
  -backend-config="region=us-east-2" \
  -backend-config="encrypt=true" >/dev/null || die "init failed - check the coordinates"
ok "initialised"

B="$HOME/rw-tf-$ENVNAME-state-$(date +%Y%m%d-%H%M%S).json"
terraform state pull > "$B" 2>/dev/null || true
ok "state backed up to $B ($(wc -c < "$B") bytes)"
printf '  already in state: '
terraform state list 2>/dev/null | wc -l

# ── build the address -> identifier table ───────────────────────────────────
SM_PREFIX="$CLUSTER/risingwave"
ROLE="$CLUSTER-risingwave"
TBL=$(mktemp)

add() { printf '%s\t%s\n' "$1" "$2" >> "$TBL"; }

add "aws_s3_bucket.risingwave"                                  "$BUCKET_PREFIX"
add "aws_s3_bucket_versioning.risingwave"                        "$BUCKET_PREFIX"
add "aws_s3_bucket_server_side_encryption_configuration.risingwave" "$BUCKET_PREFIX"
add "aws_s3_bucket_public_access_block.risingwave"               "$BUCKET_PREFIX"
add "aws_iam_role.risingwave_irsa"                               "$ROLE"
add "aws_iam_role_policy.risingwave_s3"                          "$ROLE:risingwave-s3-access"

# resource name -> SECRET name. svc_reporting is svc-reporting: underscore in
# the Terraform address, HYPHEN in the AWS secret. Getting this wrong imports
# nothing and reports success.
PLATFORM="postgres:postgres root:root svc_reporting:svc-reporting"
PLATFORM="$PLATFORM secret_store_private_key:secret_store_private_key"
PLATFORM="$PLATFORM console_license_key:console_license_key"
APP="entity:entity grafana:grafana kafka:kafka mongodb:mongodb"
APP="$APP dex_entra_client_secret:dex_entra_client_secret"

MISSING=""
for pair in $PLATFORM $APP; do
  rname="${pair%%:*}"; sname="${pair##*:}"
  idx=""
  case " $APP " in *" $pair "*) idx="[0]" ;; esac   # secrets-app.tf is count-gated
  full="$SM_PREFIX/$sname"
  arn=$(aws secretsmanager describe-secret --secret-id "$full" --query ARN --output text 2>/dev/null) || true
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then
    MISSING="$MISSING $full"
    continue
  fi
  vid=$(aws secretsmanager describe-secret --secret-id "$full" --query VersionIdsToStages --output json 2>/dev/null \
        | jq -r 'to_entries[] | select(.value[] == "AWSCURRENT") | .key' | head -1) || true
  add "aws_secretsmanager_secret.$rname$idx" "$arn"
  if [ -n "$vid" ]; then
    add "aws_secretsmanager_secret_version.$rname$idx" "$arn|$vid"
  else
    warn "$full has no AWSCURRENT version - version NOT imported, so a plan will"
    warn "  want to CREATE one. Do not apply until that is understood."
  fi
done

head2 "Import table ($(wc -l < "$TBL") resources)"
printf '  %-62s %s\n' "ADDRESS" "IDENTIFIER"
while IFS=$'\t' read -r a i; do printf '  %-62s %s\n' "$a" "$i"; done < "$TBL"
[ -n "$MISSING" ] && { warn "not present in AWS, so nothing to import (apply would create them):"; for m in $MISSING; do printf '    %s\n' "$m"; done; }

if [ "$MODE" = "--dry-run" ]; then
  head2 "DRY RUN - nothing imported"
  printf '  Re-run with --import once the table above is right:\n    %s %s --import\n' "$0" "$ENVNAME"
  exit 0
fi

head2 "Importing"
read -r -p "  type IMPORT to write $(wc -l < "$TBL") resources into state: " c
[ "$c" = "IMPORT" ] || die "stopped, nothing written"
FAILED=0
while IFS=$'\t' read -r a i; do
  if terraform state list 2>/dev/null | grep -qxF "$a"; then
    printf '  skip (already in state) %s\n' "$a"; continue
  fi
  if terraform import -input=false -var="manage_app_secrets=true" "$a" "$i" >/dev/null 2>&1; then
    ok "imported $a"
  else
    warn "FAILED $a  <- $i"; FAILED=$((FAILED + 1))
  fi
done < "$TBL"
printf '\n  failures: %s\n' "$FAILED"

head2 "Plan - READ THIS, do not apply"
terraform plan -input=false -var="manage_app_secrets=true" -no-color > "$D/plan.txt" 2>&1 || true
tail -40 "$D/plan.txt"
printf '\n  full plan: %s\n' "$D/plan.txt"
echo
warn "PASS = no changes to any aws_ resource. The 6 random_password/random_id"
warn "creates are expected and inert."
warn "STOP if the plan wants to replace or update any aws_secretsmanager_secret_version:"
warn "that is a live credential. Restore from $B"
echo
printf '%sThis script does not apply. Applies go through Octopus.%s\n' "$BLD" "$RST"
