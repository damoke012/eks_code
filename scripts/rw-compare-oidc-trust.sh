#!/usr/bin/env bash
# Compare the GHA OIDC trust policy on dev's poc role against QA's, which is known good.
#
# Run after "Could not assume role with OIDC: Not authorized to perform
# sts:AssumeRoleWithWebIdentity". AWS returns that identical message whether the role does
# not exist, the trust does not name this repo, or the trust names it with a condition the
# token does not satisfy -- so read the policy rather than guessing which.
#
# QA's poc role is the reference: risingwave-pipeline's secret.yaml assumed it successfully
# on 2026-09-14 and created 12 Kafka secrets. Diff against the thing that works.
#
#   bash scripts/rw-compare-oidc-trust.sh
#
# READ ONLY. Finds each profile by account id, so no profile name is assumed.
set -uo pipefail
command -v aws >/dev/null || { echo "aws CLI not installed"; exit 3; }
command -v jq  >/dev/null || { echo "jq not installed: sudo apt-get install -y jq"; exit 3; }

find_profile() {  # $1 = account id
  for P in $(aws configure list-profiles 2>/dev/null); do
    A=$(aws sts get-caller-identity --profile "$P" --query Account --output text 2>/dev/null)
    [ "$A" = "$1" ] && { echo "$P"; return 0; }
  done
  return 1
}

show() {  # $1 = env, $2 = account id
  ENVN="$1"; ACC="$2"
  echo "================ op-usxpress-$ENVN  ($ACC)"
  P=$(find_profile "$ACC") || {
    echo "  no logged-in profile resolves to $ACC -- cannot read, NOT concluding anything."
    echo; return; }
  echo "  profile: $P"
  for KIND in poc pipeline; do
    R="gha-op-usxpress-$ENVN-risingwave-$KIND-secrets"
    if ! DOC=$(aws iam get-role --profile "$P" --role-name "$R" \
                 --query 'Role.AssumeRolePolicyDocument' --output json 2>&1); then
      case "$DOC" in
        *NoSuchEntity*) echo "  -- $R: DOES NOT EXIST" ;;
        *AccessDenied*) echo "  -- $R: cannot read IAM as $P (says nothing about the role)" ;;
        *) echo "  -- $R: unexpected: $(echo "$DOC" | head -1)" ;;
      esac
      continue
    fi
    echo "  -- $R"
    echo "$DOC" | jq -r '.Statement[] | "     principal: \(.Principal.Federated // .Principal)"'
    echo "$DOC" | jq -r '.Statement[].Condition // {} | to_entries[] | .value | to_entries[]
                         | "     \(.key) = \(.value | if type=="array" then join(" | ") else . end)"'
    aws iam list-role-policies --profile "$P" --role-name "$R" \
      --query 'PolicyNames' --output text 2>/dev/null \
      | tr '\t' '\n' | sed 's/^/     inline policy: /'
  done
  echo
}

show qa  527101283767   # reference: this one works
show dev 700736442855   # the one that just failed
echo "The sub condition must match repo:variant-inc/risingwave-pipeline:ref:refs/heads/dev"
echo "for a push to the dev branch. A sub pinned to one branch, or to the upstream"
echo "usxpressinc/risingwave-poc repo, produces exactly the error seen."
