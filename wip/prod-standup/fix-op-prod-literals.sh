#!/usr/bin/env bash
# fix-op-prod-literals.sh — clear inherited QA literals from the op-prod branch.
#
# RUN ON WSL. The platform repo is corp GHE; the codespace token must never
# reach it.
#
# op-prod was cut from op-qa as an exact copy, so every op-qa literal came with
# it. Only cert-manager/release.yaml (the one phase-1 file) has been fixed. The
# remaining ~12 are all phase-2 scope — they do not block the phase-1 deploy,
# but each one is a "deploys clean, points at QA" trap the moment phase 2 lands.
#
#   ./fix-op-prod-literals.sh              # dry-run: classify every hit
#   ./fix-op-prod-literals.sh --apply      # rewrite the AUTO class only
#
# AUTO   = the literal is unambiguously this cluster's identity (IRSA role ARNs,
#          SM paths, txtOwnerId, bucket names). Mechanical, safe to sed.
# REVIEW = the literal may point at a SHARED or central resource, where
#          rewriting it to the prod account would break a working reference.
#          Never auto-rewritten. You decide, per hit.
#
# Leaves changes staged-but-uncommitted. Read the diff, then PR to op-prod.

set -euo pipefail

REPO="${REPO:-$HOME/work/iaac-talos-flux-platform}"
BRANCH="op-prod"
APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

QA_CLUSTER="op-usxpress-qa"
DEV_CLUSTER="op-usxpress-dev"
PROD_CLUSTER="op-usxpress-prod"
QA_ACCT="527101283767"
DEV_ACCT="700736442855"
PROD_ACCT="937464026810"
QA_VIP="10.10.82.51"
DEV_VIP="10.10.82.50"
PROD_VIP="10.10.82.52"

# Paths where a QA/dev literal may legitimately point at a shared resource.
# ECR in particular is commonly centralised — rewriting the registry account
# would break image pulls in a way that looks like a broken cluster, not a
# broken edit. arc-runner-rw-pipeline is RisingWave tooling, and RW is
# deliberately OMITTED from prod, so those files may not belong here at all.
REVIEW_PATHS='ecr-credentials|registry|arc-runner-rw-pipeline'

cd "$REPO"
git fetch origin --quiet
git checkout "$BRANCH" --quiet
git pull --ff-only origin "$BRANCH" --quiet

echo "repo   : $REPO"
echo "branch : $BRANCH @ $(git rev-parse --short HEAD)"
echo "mode   : $([[ $APPLY == true ]] && echo APPLY || echo DRY-RUN)"
echo

PATTERN="$QA_CLUSTER|$DEV_CLUSTER|$QA_ACCT|$DEV_ACCT|$QA_VIP|$DEV_VIP"

mapfile -t HITS < <(git grep -nE "$PATTERN" -- . || true)
if [[ ${#HITS[@]} -eq 0 ]]; then
  echo "✓ no foreign-env literals on $BRANCH — gate B5 already passes."
  exit 0
fi

echo "=== ${#HITS[@]} hit(s) ==="
auto_files=()
review_count=0
for hit in "${HITS[@]}"; do
  file="${hit%%:*}"
  if [[ "$file" =~ $REVIEW_PATHS ]]; then
    echo "  REVIEW  $hit"
    review_count=$((review_count + 1))
  else
    echo "  AUTO    $hit"
    auto_files+=("$file")
  fi
done

# dedupe
mapfile -t auto_files < <(printf '%s\n' "${auto_files[@]}" | sort -u)

echo
echo "AUTO   : ${#auto_files[@]} file(s) will be rewritten"
echo "REVIEW : $review_count hit(s) left alone — decide each by hand"

cat <<'NOTE'

--- dependencies these edits CREATE (the rewrite is not the whole job) ---
  * etcd-backup     -> bucket etcd-snapshots-op-usxpress-prod must EXIST in
                       937464026810, or backups fail silently. Gate B4 checks it.
  * external-secrets -> every remoteRef path rewritten to op-usxpress-prod/*
                       must have a real SM secret behind it, or the
                       ExternalSecret syncs green with nothing in it.
                       (SecretSynced proves the sync ran, NOT that the value works.)
  * velero / rook   -> same shape: bucket + IRSA role must exist prod-side.
  All of the above need the cloud IRSA bootstrap first. These edits are phase-2
  PREP — correct to land now, but they do nothing until IRSA lands.
NOTE

if [[ $APPLY != true ]]; then
  echo
  echo "[DRY-RUN] nothing changed. Re-run with --apply to rewrite the AUTO class."
  exit 0
fi

echo
for f in "${auto_files[@]}"; do
  sed -i \
    -e "s/$QA_CLUSTER/$PROD_CLUSTER/g" \
    -e "s/$DEV_CLUSTER/$PROD_CLUSTER/g" \
    -e "s/$QA_ACCT/$PROD_ACCT/g" \
    -e "s/$DEV_ACCT/$PROD_ACCT/g" \
    -e "s/$QA_VIP/$PROD_VIP/g" \
    -e "s/$DEV_VIP/$PROD_VIP/g" \
    "$f"
  echo "  rewrote $f"
done

echo
git --no-pager diff --stat
echo
echo "=== remaining hits (expect REVIEW class only) ==="
git grep -nE "$PATTERN" -- . || echo "  (none)"

cat <<'NEXT'

NEXT:
  1. Read the full diff — git diff
  2. Decide each REVIEW hit by hand (ECR registry account is the likely keeper)
  3. Commit + PR to op-prod. Do NOT merge into phase-1's path — these files are
     phase-2 scope and their Kustomizations are still commented out in
     clusters/op-usxpress-prod/infra.yaml.
  4. Gate B5 passes when the only hits left are deliberate REVIEW keeps.
NEXT
