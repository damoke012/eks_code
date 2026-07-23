#!/usr/bin/env bash
# apply-doke-queue.sh — land the Doke-side platform changes on op-qa.
#
#   1. Velero Schedule for the RisingWave metastore (INFRA-1624)
#   2. etcd-backup staleness PrometheusRule           (INFRA-1623 durable fix)
#   3. Report every remaining op-usxpress-dev string  (INFRA-1589 / prod prep)
#
# Run from the root of ~/work/iaac-talos-flux-platform.
#   cd ~/work/iaac-talos-flux-platform
#   bash ~/work/eks_code/wip/qa-cluster-standup/apply-doke-queue.sh
#
# Creates a branch and commits. Does NOT push - review first.
# Delivered as a script because large pasted heredocs have been silently
# truncated mid-file twice on this box.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(pwd)"

[[ -d "${REPO}/infrastructure" ]] || {
  echo "ERROR: run from the root of iaac-talos-flux-platform" >&2; exit 1; }

git fetch origin --quiet
git checkout -B fix/infra-1589-qa-platform-gaps origin/op-qa
echo "==> branch: $(git rev-parse --abbrev-ref HEAD)  (base origin/op-qa)"
echo ""

# ── 1. Velero Schedule ──────────────────────────────────────────────────────
echo "==> [1/3] Velero Schedule -> infrastructure/velero/"
[[ -d infrastructure/velero ]] || { echo "ERROR: infrastructure/velero not found" >&2; exit 1; }
cp "${SRC}/velero/risingwave-metastore-schedule.yaml" \
   infrastructure/velero/risingwave-metastore-schedule.yaml

# Add to the velero kustomization if one exists and does not already list it.
VK="infrastructure/velero/kustomization.yaml"
if [[ -f "$VK" ]]; then
  if grep -q 'risingwave-metastore-schedule.yaml' "$VK"; then
    echo "    already referenced in $VK"
  else
    printf '  - risingwave-metastore-schedule.yaml\n' >> "$VK"
    echo "    appended to $VK  -- CHECK INDENTATION before commit"
  fi
else
  echo "    NOTE: no $VK; confirm how infrastructure/velero/ is assembled"
fi

# ── 2. etcd staleness alert ─────────────────────────────────────────────────
# Find where PrometheusRules already live rather than guessing a path.
echo ""
echo "==> [2/3] etcd-backup staleness PrometheusRule"
RULE_DIR="$(grep -rl 'kind: PrometheusRule' infrastructure/ 2>/dev/null \
            | head -1 | xargs -r dirname || true)"
if [[ -n "${RULE_DIR}" ]]; then
  echo "    existing PrometheusRules live in: ${RULE_DIR}"
else
  RULE_DIR="infrastructure/etcd-backup"
  echo "    no existing PrometheusRule found; defaulting to ${RULE_DIR}"
fi
cp "${SRC}/alerts/etcd-snapshot-age.yaml" "${RULE_DIR}/etcd-snapshot-age.yaml"
echo "    wrote ${RULE_DIR}/etcd-snapshot-age.yaml"
echo "    ⚠️  the rule's 'release: prometheus' label MUST match your Prometheus"
echo "        ruleSelector, or the rules load into nothing. Verify with:"
echo "          kubectl get prometheus -A -o yaml | grep -A6 ruleSelector"

# ── 3. Report remaining dev strings ─────────────────────────────────────────
echo ""
echo "==> [3/3] remaining op-usxpress-dev references on op-qa"
echo "    (each of these is a latent env-correctness bug of the class that"
echo "     caused 13 days of silent etcd backup failure)"
echo ""
git grep -n "op-usxpress-dev" origin/op-qa || echo "    none found"
echo ""
git grep -nE "10\.10\.82\.50" origin/op-qa || echo "    no dev IPs found"

# ── Commit ──────────────────────────────────────────────────────────────────
echo ""
git add -A
git status --short
echo ""
echo "==> Review the diff, then:"
echo "     git commit -m 'feat(qa): velero RW metastore schedule + etcd staleness alerts (INFRA-1623/1624)'"
echo "     git push -u origin fix/infra-1589-qa-platform-gaps"
echo "     gh pr create --base op-qa --fill"
echo ""
echo "==> AFTER MERGE - reconcile and PROVE, do not assume:"
echo "     flux reconcile kustomization velero --with-source"
echo "     kubectl -n velero get schedule risingwave-metastore    # namespace MUST be velero"
echo "     kubectl get prometheusrule -A | grep etcd"
echo "     # and confirm the rules actually loaded into Prometheus:"
echo "     kubectl -n <prom-ns> exec sts/prometheus-<name> -c prometheus -- \\"
echo "       wget -qO- localhost:9090/api/v1/rules | grep -c EtcdSnapshot"
