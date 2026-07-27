#!/usr/bin/env bash
# validate-register.sh — self-confirm prod register values BEFORE asking teams.
# EVERYTHING here is READ-ONLY (sts get-caller-identity, s3 ls, iam list-*,
# route53 list-*). No mutation, no apply, safe against prod.
#
# Run on WSL where the AWS SSO profiles live. Profiles per memory:
#   dev  = usx-dev        (expect acct 700736442855)
#   qa   = usx-qa         (expect acct 527101283767)
#   prod = ops-controller (expect acct 937464026810)  <-- the one we're confirming
#
# Prereq: aws sso login --profile ops-controller   (and usx-qa if not cached)
#
#   bash validate-register.sh

set -uo pipefail
REGION=us-east-2
DEV_PROFILE=usx-dev
QA_PROFILE=usx-qa
PROD_PROFILE=ops-controller

EXPECT_DEV=700736442855
EXPECT_QA=527101283767
EXPECT_PROD=937464026810

hr(){ printf '%.0s─' {1..70}; echo; }

# ── 1. Account confirmation — validates "on-prem reuses cloud per-env account"
hr; echo "1. ACCOUNT CONFIRMATION (turns 'inferred' into 'verified')"; hr
for pair in "$DEV_PROFILE:$EXPECT_DEV:dev" "$QA_PROFILE:$EXPECT_QA:qa" "$PROD_PROFILE:$EXPECT_PROD:PROD"; do
  prof="${pair%%:*}"; rest="${pair#*:}"; expect="${rest%%:*}"; label="${rest#*:}"
  got=$(aws sts get-caller-identity --profile "$prof" --query Account --output text 2>/dev/null)
  if [ -z "$got" ]; then
    echo "  [$label] $prof -> NOT LOGGED IN (run: aws sso login --profile $prof)"
  elif [ "$got" = "$expect" ]; then
    echo "  [$label] $prof -> $got  ✓ matches expected"
  else
    echo "  [$label] $prof -> $got  ✗ EXPECTED $expect — STOP, mapping is wrong"
  fi
done
echo "  If PROD shows 937464026810 ✓, the account inference is CONFIRMED —"
echo "  cloud only needs to confirm the STATE BUCKET, not the account."

# ── 2. Prod state bucket — may already exist (would resolve that blocker)
hr; echo "2. PROD STATE BUCKET (does one already exist in the prod account?)"; hr
aws s3 ls --profile "$PROD_PROFILE" 2>/dev/null | grep -iE "tf-state|talos-state|terraform" \
  && echo "  ^ candidate state bucket(s) above — confirm one is for iaac/talos" \
  || echo "  none matching tf-state/terraform — cloud must create one (or it's named oddly; review full list: aws s3 ls --profile $PROD_PROFILE)"

# ── 3. Prod IRSA OIDC (phase-2, but check if cloud already provisioned it)
hr; echo "3. PROD IRSA — OIDC provider + oidc bucket already there?"; hr
aws iam list-open-id-connect-providers --profile "$PROD_PROFILE" --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null \
  | tr '\t' '\n' | grep -i cloudfront \
  && echo "  ^ a CloudFront-fronted OIDC provider exists (QA-style IRSA)" \
  || echo "  no cloudfront OIDC provider yet — expected for greenfield; cloud drops ONPREM_BOOTSTRAP_ROLE_ARN_PROD in phase 2"
aws s3 ls --profile "$PROD_PROFILE" 2>/dev/null | grep -i irsa-oidc \
  && echo "  ^ irsa-oidc bucket present" || echo "  no irsa-oidc bucket yet (phase 2)"

# ── 4. DNS — the prod domain may be discoverable from Route53 zones
hr; echo "4. DNS DOMAIN (Route53 hosted zones in the prod account)"; hr
aws route53 list-hosted-zones --profile "$PROD_PROFILE" \
  --query 'HostedZones[].{name:Name,private:Config.PrivateZone}' --output table 2>/dev/null \
  || echo "  could not list zones (permission or login) — ask CySec/networking for the prod zone"
echo "  Pick the zone prod ingress should live under; that's the value the DNS ask needs."

# ── 5. Reference: what QA actually uses (concrete 'match this' for the infra ask)
hr; echo "5. QA REFERENCE VALUES (hand these to infra as 'prod equivalent of…')"; hr
echo "  From the verified QA Octopus vars:"
echo "    datastore     = USXD1NTXPROD-SC1"
echo "    network_name  = 10.10.82 (vLAN 82) Prod"
echo "    content_lib   = dev-cluster / talos-v1.11.1"
echo "    VIP           = 10.10.82.51 (QA)  -> prod needs its own on the plan"
echo "  Ask infra: same vLAN/datastore or dedicated for prod?"

hr; echo "SUMMARY: items 1–4 you can often CLOSE yourself; 5 + the VIP still need"
echo "networking/infra. Anything ✓ above is a blocker you can strike now."
hr
