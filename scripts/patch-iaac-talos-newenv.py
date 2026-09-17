#!/usr/bin/env python3
"""Close two gaps in variant-inc/iaac-talos that block creating a NEW environment.

  Gap 1  The Terraform state bucket has no automation. A backend cannot create its own
         bucket, so step 3 of a standup is a human in the AWS console.
         -> adds octopus/ensure-tfstate-bucket.sh, called from onprem-account-bootstrap.

  Gap 2  Both bootstrap workflows hardcode `options: [dev, qa, prod]` and a case statement
         over three ONPREM_BOOTSTRAP_ROLE_ARN_<ENV> secrets, so a fourth environment cannot
         be selected at all.
         -> free-text env + dynamic secret lookup. Adding an environment becomes a new
            SECRET, not a code change. Unmatched env FAILS LOUDLY instead of assuming an
            empty ARN -- today the case has no `*)` branch, so a typo produces an empty
            role and a confusing credentials error three steps later.

Run INSIDE a clone of iaac-talos on a branch. Idempotent: refuses if already applied.

    git checkout -b feat/new-env-bootstrap
    python3 patch-iaac-talos-newenv.py
    git diff
"""
import pathlib, sys

ROOT = pathlib.Path.cwd()
BOOT = ROOT / ".github/workflows/onprem-account-bootstrap.yaml"
SEED = ROOT / ".github/workflows/onprem-cluster-secrets.yaml"
SH   = ROOT / "octopus/ensure-tfstate-bucket.sh"

if not BOOT.exists() or not SEED.exists():
    sys.exit("ERROR: run this from the root of an iaac-talos clone (workflows not found).")
if SH.exists():
    sys.exit("ERROR: octopus/ensure-tfstate-bucket.sh already exists -- patch already applied.")

# ---------------------------------------------------------------- gap 1: the bucket
SH.write_text('''#!/usr/bin/env bash
# Create the Terraform state bucket for a cluster, if it does not exist.
#
# Why this exists: deploy/deploy.ps1 runs
#   terraform init -backend-config="bucket=$S3_BUCKET"
# A Terraform backend cannot create its own bucket, so before 2026-09-17 this was the one
# step of a cluster standup that had no automation at all -- a person in the AWS console.
#
# Idempotent. Safe to re-run. Settings are re-applied every time so a bucket that drifted
# (versioning switched off, encryption removed) is corrected rather than accepted.
set -euo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME must be set (e.g. op-usxpress-qa2)}"
REGION="${AWS_REGION:-us-east-2}"
BUCKET="${TFSTATE_BUCKET:-${CLUSTER_NAME}-tfstate}"

echo "[tfstate] account : $(aws sts get-caller-identity --query Account --output text)"
echo "[tfstate] bucket  : ${BUCKET}"
echo "[tfstate] region  : ${REGION}"

# head-bucket tells three different stories. Treat them differently.
#   exit 0   -> ours, exists
#   404      -> does not exist, create it
#   403      -> EXISTS AND IS SOMEONE ELSE'S. Never proceed; bucket names are global.
if err=$(aws s3api head-bucket --bucket "${BUCKET}" 2>&1); then
  echo "[tfstate] bucket already exists"
else
  case "${err}" in
    *404*|*"Not Found"*)
      echo "[tfstate] creating..."
      if [ "${REGION}" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
      else
        aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \\
          --create-bucket-configuration "LocationConstraint=${REGION}"
      fi
      aws s3api wait bucket-exists --bucket "${BUCKET}"
      echo "[tfstate] created"
      ;;
    *403*|*Forbidden*)
      echo "::error::Bucket ${BUCKET} exists but is not accessible from this account."
      echo "::error::S3 bucket names are GLOBAL. Pick a different cluster name or reuse it deliberately."
      printf '%s\\n' "${err}" | head -2
      exit 1
      ;;
    *)
      echo "::error::Unexpected failure probing ${BUCKET} -- this says nothing about whether it exists."
      printf '%s\\n' "${err}" | head -3
      exit 1
      ;;
  esac
fi

# Always (re-)apply. Terraform state is the record of the whole environment: losing a version
# to an overwrite is unrecoverable, so versioning is not optional.
aws s3api put-bucket-versioning --bucket "${BUCKET}" \\
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "${BUCKET}" \\
  --server-side-encryption-configuration \\
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-public-access-block --bucket "${BUCKET}" \\
  --public-access-block-configuration \\
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

# Read back rather than trusting the writes. A green put is not a valid value.
V=$(aws s3api get-bucket-versioning --bucket "${BUCKET}" --query Status --output text)
E=$(aws s3api get-bucket-encryption --bucket "${BUCKET}" \\
      --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \\
      --output text)
P=$(aws s3api get-public-access-block --bucket "${BUCKET}" \\
      --query PublicAccessBlockConfiguration.BlockPublicAcls --output text)
echo "[tfstate] verified: versioning=${V} encryption=${E} block_public_acls=${P}"
[ "${V}" = "Enabled" ] || { echo "::error::versioning is ${V}, expected Enabled"; exit 1; }
[ "${E}" = "AES256" ]  || { echo "::error::encryption is ${E}, expected AES256"; exit 1; }
[ "${P}" = "True" ]    || { echo "::error::public access block is ${P}, expected True"; exit 1; }

echo "[tfstate] OK -- set S3_BUCKET=${BUCKET} on the Octopus environment"
''')
SH.chmod(0o755)

# ---------------------------------------------------------------- gap 2: the dropdowns
OLD_CHOICE_BOOT = """      target_env:
        description: 'Target environment (which AWS account)'
        required: true
        type: choice
        options: [dev, qa, prod]"""
NEW_CHOICE_BOOT = """      target_env:
        description: 'Environment key -- dev, qa, prod, or a new one (needs a matching secret)'
        required: true
        type: string"""

OLD_CHOICE_SEED = """      target_env:
        description: 'Target environment'
        required: true
        type: choice
        options: [dev, qa, prod]"""
NEW_CHOICE_SEED = """      target_env:
        description: 'Environment key -- dev, qa, prod, or a new one (needs a matching secret)'
        required: true
        type: string"""

OLD_CASE = """      - name: Select account role
        id: role
        run: |
          case "${{ inputs.target_env }}" in
            dev)  echo "arn=${{ secrets.ONPREM_BOOTSTRAP_ROLE_ARN_DEV }}"  >> "$GITHUB_OUTPUT" ;;
            qa)   echo "arn=${{ secrets.ONPREM_BOOTSTRAP_ROLE_ARN_QA }}"   >> "$GITHUB_OUTPUT" ;;
            prod) echo "arn=${{ secrets.ONPREM_BOOTSTRAP_ROLE_ARN_PROD }}" >> "$GITHUB_OUTPUT" ;;
          esac"""
NEW_CASE = """      # Adding an environment is a new SECRET, not a code change. The old case
      # statement had no *) branch, so an unmatched value produced an EMPTY arn and
      # failed three steps later inside configure-aws-credentials, which reads as a
      # permissions problem. This fails here, naming the secret it looked for.
      - name: Select account role
        id: role
        env:
          ROLE_ARN: ${{ secrets[format('ONPREM_BOOTSTRAP_ROLE_ARN_{0}', inputs.target_env)] }}
        run: |
          set -euo pipefail
          ENV_UPPER=$(printf '%s' "${{ inputs.target_env }}" | tr '[:lower:]' '[:upper:]')
          if [ -z "${ROLE_ARN:-}" ]; then
            echo "::error::No value for secret ONPREM_BOOTSTRAP_ROLE_ARN_${ENV_UPPER}."
            echo "::error::Create that repository secret with the bootstrap role ARN for"
            echo "::error::environment '${{ inputs.target_env }}', then re-run. Nothing was changed."
            exit 1
          fi
          echo "arn=${ROLE_ARN}" >> "$GITHUB_OUTPUT\""""

BUCKET_STEP = """      - name: Ensure Terraform state bucket
        if: ${{ !inputs.dry_run }}
        env:
          CLUSTER_NAME: ${{ inputs.cluster_name }}
          AWS_REGION: us-east-2
        run: bash octopus/ensure-tfstate-bucket.sh
      - name: Apply bootstrap policy"""

def edit(path, pairs):
    txt = path.read_text()
    for old, new in pairs:
        n = txt.count(old)
        if n != 1:
            sys.exit(f"ERROR: {path.name}: anchor found {n} times, expected 1:\n{old[:120]}")
        txt = txt.replace(old, new)
    path.write_text(txt)
    print(f"patched {path}")

edit(BOOT, [
    (OLD_CHOICE_BOOT, NEW_CHOICE_BOOT),
    (OLD_CASE, NEW_CASE),
    ("      - name: Apply bootstrap policy", BUCKET_STEP),
])
edit(SEED, [
    (OLD_CHOICE_SEED, NEW_CHOICE_SEED),
    (OLD_CASE, NEW_CASE),
])
print(f"created {SH}")
print("\nNow: git diff   -- read it in full, including lines you did not mean to change.")
