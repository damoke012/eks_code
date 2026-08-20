#!/usr/bin/env bash
# Audit every repository policy in the shared ECR account — INFRA-1643.
#
# The shared registry is pulled from by all three on-prem clusters and both EKS
# accounts. ECR authorises PER REPOSITORY: a repo with no policy is unreadable
# cross-account (INFRA-1633), and a repo with a loose policy is writable by
# anyone the policy names. Both failures are invisible until something breaks or
# something is overwritten.
#
# READ ONLY. Every call is a describe or a get.
#
#   scripts/audit-ecr-policies.sh --profile infra-common
#   scripts/audit-ecr-policies.sh --profile infra-common --region us-east-1
set -uo pipefail

PROFILE=""; REGION="us-east-2"; EXPECT_ACCOUNT="064859874041"
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --account) EXPECT_ACCOUNT="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROFILE" ] || { echo "usage: $0 --profile <name> [--region us-east-2]" >&2
                       echo "profiles available:" >&2; aws configure list-profiles >&2; exit 2; }

a() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

# Preflight. 'Unable to locate credentials' from inside the loop reads like a
# missing repository, so fail here instead.
ACC=$(a sts get-caller-identity --query Account --output text 2>&1)
if ! [[ "$ACC" =~ ^[0-9]{12}$ ]]; then
  echo "!! cannot authenticate with profile '$PROFILE': $ACC" >&2
  echo "   aws sso login --profile $PROFILE" >&2
  exit 1
fi
if [ "$ACC" != "$EXPECT_ACCOUNT" ]; then
  echo "!! profile '$PROFILE' is account $ACC, expected $EXPECT_ACCOUNT." >&2
  echo "   Refusing to report on the wrong registry." >&2
  exit 1
fi
echo "registry $ACC in $REGION, via profile $PROFILE"

WRITE_ACTIONS='PutImage|InitiateLayerUpload|UploadLayerPart|CompleteLayerUpload|BatchDeleteImage|DeleteRepository|SetRepositoryPolicy'
FINDINGS=0

echo
echo "== registry-level policy"
a ecr describe-registry --output json 2>/dev/null | python3 -m json.tool || echo "  (none)"

echo
printf '%-46s %-9s %-8s %s\n' REPOSITORY MUTABLE SCAN POLICY
printf '%-46s %-9s %-8s %s\n' "----------" "-------" "----" "------"

REPOS=$(a ecr describe-repositories --output json 2>/dev/null)
[ -z "$REPOS" ] && { echo "!! could not list repositories" >&2; exit 1; }

echo "$REPOS" | python3 -c '
import sys, json
for r in json.load(sys.stdin)["repositories"]:
    print("\t".join([r["repositoryName"],
                     r.get("imageTagMutability", "?"),
                     str(r.get("imageScanningConfiguration", {}).get("scanOnPush", "?"))]))
' | while IFS=$'\t' read -r NAME MUT SCAN; do
    POL=$(a ecr get-repository-policy --repository-name "$NAME" --query policyText --output text 2>/dev/null)
    if [ -z "$POL" ]; then
      printf '%-46s %-9s %-8s %s\n' "$NAME" "$MUT" "$SCAN" "NONE — unreadable cross-account"
      continue
    fi
    SUMMARY=$(echo "$POL" | python3 -c '
import sys, json, re
p = json.load(sys.stdin)
W = re.compile(r"'"$WRITE_ACTIONS"'")
bits = []
for st in p.get("Statement", []):
    if st.get("Effect") != "Allow":
        continue
    acts = st.get("Action", [])
    acts = [acts] if isinstance(acts, str) else acts
    pr = st.get("Principal", {})
    who = pr.get("AWS", pr) if isinstance(pr, dict) else pr
    who = [who] if isinstance(who, str) else who
    cond = st.get("Condition", {})
    org = None
    for c in cond.values():
        for k, v in (c.items() if isinstance(c, dict) else []):
            if "PrincipalOrgID" in k:
                org = v
    wildcard = any(w == "*" for w in who)
    writes = sorted({a for a in acts if W.search(a)})
    scope = f"org {org}" if org else ("ANY PRINCIPAL" if wildcard else f"{len(who)} account(s)")
    if writes:
        bits.append(f"WRITE({len(writes)}) to {scope}")
    else:
        bits.append(f"read to {scope}")
print("; ".join(bits) if bits else "no Allow statements")
')
    printf '%-46s %-9s %-8s %s\n' "$NAME" "$MUT" "$SCAN" "$SUMMARY"
  done

echo
echo "Read the WRITE rows in full before deciding — a write grant to a named"
echo "build account is normal; a write grant to an org or to ANY PRINCIPAL is not:"
echo "  aws --profile $PROFILE --region $REGION ecr get-repository-policy \\"
echo "      --repository-name <name-from-the-table-above> --query policyText --output text | python3 -m json.tool"
echo
echo "MUTABLE=MUTABLE means a tag can be moved onto different content. Anything"
echo "an on-prem cluster pulls should be IMMUTABLE, and pulled by digest anyway."
