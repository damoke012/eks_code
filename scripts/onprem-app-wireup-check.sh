#!/usr/bin/env bash
# Walk the delivery relay for one on-prem environment, read-only, and print a
# verdict per gate. Written because every gate in this relay fails GREEN:
# on 2026-10-09 op-dev had eight green ticks and zero rows.
#
# Gates 3-6 are the ones a script can settle. Gates 1-2 are repo questions,
# 7-9 need SQL against the target. See .claude/skills/onprem-app-wireup/SKILL.md
#
# Usage:  bash scripts/onprem-app-wireup-check.sh dev|qa|prod
# Never mutates anything. Every failure says FAIL or NOT MEASURED and why.
set -uo pipefail

ENV="${1:-}"
case "$ENV" in
  dev)
    KC="$HOME/.kube/op-usxpress-dev-fresh.yaml"; ENDPOINT='10.10.82.50:6443'
    AWS_PROFILE_ENV=usx-dev ;;
  qa)
    KC="$HOME/.kube/op-usxpress-qa-sso.yaml";    ENDPOINT='10.10.82.51:6443'
    AWS_PROFILE_ENV=usx-qa ;;
  prod)
    KC="$HOME/.kube/op-usxpress-prod.yaml";      ENDPOINT='6443'
    AWS_PROFILE_ENV=usx-prod ;;
  *)
    echo "usage: $0 dev|qa|prod"; exit 2 ;;
esac

NS=app-risingwave
SECRET=etl-pipeline-credentials
CM_IMAGE=etl-pipeline-image
CM_ENDPOINTS=etl-pipeline-endpoints
APP=risingwave-etl
ECR_PROFILE=infra-common          # 064859874041, the shared registry account
SM_PREFIX="op-usxpress-${ENV}"
PASS=0; FAIL=0; SKIP=0
ok(){   printf 'PASS         %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf 'FAIL         %s\n' "$1"; FAIL=$((FAIL+1)); }
skip(){ printf 'NOT MEASURED %s\n' "$1"; SKIP=$((SKIP+1)); }

echo "=== delivery relay, op-usxpress-${ENV} ==="

# ── gate 0: are we talking to the cluster we named ──────────────────────────
# An empty --context silently selects the CURRENT context, so resolve by
# endpoint and refuse to continue on a mismatch.
CLUSTER_OK=0
if [ ! -f "$KC" ]; then
  skip "cluster: $KC is missing on this box"
elif ! command -v nc >/dev/null 2>&1; then
  skip "cluster: nc absent, cannot test reachability"
elif ! nc -z -w 5 "${ENDPOINT%%:*}" "${ENDPOINT##*:}" >/dev/null 2>&1; then
  skip "cluster: ${ENDPOINT} unreachable — corp VPN down, NOT a cluster fault"
else
  S=$(kubectl --kubeconfig="$KC" config view -o jsonpath='{.clusters[*].cluster.server}')
  N=$(echo "$S" | wc -w)
  if [ "$N" != "1" ] || ! echo "$S" | grep -q "$ENDPOINT"; then
    bad "cluster: $KC holds $N server(s) and not solely $ENDPOINT — nothing queried"
  else
    # An open port is not an authenticated session. On 2026-10-09 this script
    # reported "FAIL digest" and "FAIL secret" for QA against a cluster whose
    # objects were both present and healthy: the SSO session behind the
    # kubeconfig's aws-iam-authenticator had expired, every kubectl returned
    # empty through 2>/dev/null, and empty read as absent. A check that invents
    # findings is worse than no check -- it is the exact defect this script was
    # written to prevent ([[transport-failure-not-a-verdict]]).
    #
    # So prove the credential with one cheap API call before judging anything.
    if ! kubectl --kubeconfig="$KC" get --raw /version >/dev/null 2>&1; then
      skip "cluster: ${ENDPOINT} answers but the credential does not work"
      skip "         refresh it (aws sso login --profile <the kubeconfig's AWS_PROFILE>)"
      skip "         NOTHING below was measured; these are not findings"
    else
      ok "cluster: $KC resolves to $ENDPOINT only, and the credential works"
      CLUSTER_OK=1
    fi
  fi
fi

# ── gate 5 (first, it names the repository the rest depend on) ──────────────
VALUES_REPO=""; LIVE_DIGEST=""
if [ "$CLUSTER_OK" = 1 ]; then
  LIVE_DIGEST=$(kubectl --kubeconfig="$KC" -n "$NS" get cm "$CM_IMAGE" \
                  -o jsonpath='{.data.digest}' 2>/dev/null)
  if [ -z "$LIVE_DIGEST" ]; then
    bad "digest: ConfigMap $CM_IMAGE has no digest — nothing pinned"
  else
    ok "digest: $NS/$CM_IMAGE = ${LIVE_DIGEST:0:19}"
  fi
fi

# ── gate 3+4: is that digest in the registry, and may this cluster pull it ──
if [ -z "$LIVE_DIGEST" ]; then
  skip "registry: no live digest to look up"
elif ! command -v aws >/dev/null 2>&1; then
  skip "registry: aws absent"
else
  FOUND=""
  for R in risingwave/poc-pipeline risingwave/etl-pipeline; do
    if aws ecr describe-images --profile "$ECR_PROFILE" --region us-east-2 \
         --repository-name "$R" --image-ids imageDigest="$LIVE_DIGEST" \
         --query 'imageDetails[0].imagePushedAt' --output text >/dev/null 2>&1; then
      FOUND="$R"; break
    fi
  done
  if [ -z "$FOUND" ]; then
    bad "registry: ${LIVE_DIGEST:0:19} is in NEITHER known repository"
  else
    ok "registry: digest present in $FOUND"
    # A new repository has NO policy and a cross-account pull 403s on the
    # manifest HEAD. Absence here is the single most common cause.
    if aws ecr get-repository-policy --profile "$ECR_PROFILE" --region us-east-2 \
         --repository-name "$FOUND" --query policyText --output text >/dev/null 2>&1; then
      ok "registry: $FOUND carries a repository policy"
    else
      bad "registry: $FOUND has NO repository policy — on-prem pull will 403"
    fi
  fi
fi

# ── gate 6: is the secret COMPLETE, not merely synced ──────────────────────
if [ "$CLUSTER_OK" != 1 ]; then
  skip "secret: cluster not reachable"
else
  COND=$(kubectl --kubeconfig="$KC" -n "$NS" get externalsecret "$SECRET" \
           -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)
  KEYS=$(kubectl --kubeconfig="$KC" -n "$NS" get secret "$SECRET" -o json 2>/dev/null \
           | jq -r '.data | keys | length' 2>/dev/null)
  WANT=$(kubectl --kubeconfig="$KC" -n "$NS" get externalsecret "$SECRET" \
           -o jsonpath='{.spec.data[*].secretKey}' 2>/dev/null | wc -w)
  if [ -z "${KEYS:-}" ] || [ "$WANT" = "0" ]; then
    bad "secret: $SECRET not found, or declares no data entries"
  elif [ "$KEYS" != "$WANT" ]; then
    # ESO writes a PARTIAL secret on error; the pod then dies at container
    # creation with RESTARTS 0, invisible to restart alerts.
    bad "secret: $KEYS of $WANT keys present (reason=$COND) — PARTIAL write"
  else
    ok "secret: $KEYS of $WANT keys present (reason=$COND)"
  fi
  # A deliberate blank is a real value and fails the whole applier run.
  BLANKS=$(kubectl --kubeconfig="$KC" -n "$NS" get cm "$CM_ENDPOINTS" -o json 2>/dev/null \
             | jq -r '.data | to_entries[] | select(.value == "") | .key' 2>/dev/null | tr '\n' ' ')
  if [ -n "${BLANKS// /}" ]; then
    bad "config: empty-string values present — $BLANKS"
  else
    ok "config: no empty-string values in $CM_ENDPOINTS"
  fi
  # An exclusion that matches nothing is why a run demands systems you lack.
  EX=$(kubectl --kubeconfig="$KC" -n "$NS" get cm "$CM_ENDPOINTS" \
         -o jsonpath='{.data.EXCLUDE_RE}' 2>/dev/null)
  printf 'INFO         exclude_re: %s\n' "${EX:-<unset>}"
  printf 'INFO         verify every alternative above matches a REAL path\n'
fi

# ── the hook, whose Job is deleted on success AND on failure ───────────────
if [ "$CLUSTER_OK" != 1 ]; then
  skip "hook: cluster not reachable"
else
  H=$(kubectl --kubeconfig="$KC" -n argocd get application "$APP" \
        -o jsonpath='{range .status.operationState.syncResult.resources[*]}{.hookType}{" "}{.hookPhase}{"\n"}{end}' \
        2>/dev/null | grep -i sync | head -1)
  case "$H" in
    *Succeeded) ok   "hook: $H (durable record, the Job itself is deleted either way)" ;;
    "")         skip "hook: no syncResult recorded yet" ;;
    *)          bad  "hook: $H" ;;
  esac
fi

echo
echo "pass=$PASS fail=$FAIL not_measured=$SKIP"
echo "A clean sweep is NOT a working pipeline. Finish at the destination:"
echo "  row counts in the target, and an object the NEW code renames."
[ "$FAIL" -eq 0 ]
