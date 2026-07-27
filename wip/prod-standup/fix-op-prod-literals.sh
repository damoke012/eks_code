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

# Docs are HISTORICAL RECORDS, not config. design_doc_* and the ADRs describe
# decisions made for op-usxpress-dev; rewriting the cluster name inside them
# falsifies the record rather than fixing anything. They also never reconcile —
# Flux doesn't read them. Skipped outright.
SKIP_PATHS='\.md$|^op-dev/'

# RisingWave is deliberately OMITTED from prod (its manifest path doesn't exist
# → the 17-day "path not found" failure). These files should be DELETED from
# op-prod, not rewritten to point at prod resources that will never exist.
DELETE_PATHS='arc-runner-rw-pipeline|risingwave'

# ECR may pull from a CENTRAL registry account. The IRSA role name is this
# cluster's identity and should be rewritten, but the registry account it reads
# from may legitimately stay — and getting that backwards breaks image pulls in
# a way that looks like a broken cluster, not a broken edit.
REVIEW_PATHS='ecr-credentials|registry'

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
declare -A auto_lines=()
skip_n=0 del_n=0 rev_n=0 com_n=0 auto_n=0

for hit in "${HITS[@]}"; do
  file="${hit%%:*}"
  rest="${hit#*:}"
  lineno="${rest%%:*}"
  text="${rest#*:}"

  if [[ "$file" =~ $SKIP_PATHS ]]; then
    skip_n=$((skip_n + 1)); continue
  elif [[ "$file" =~ $DELETE_PATHS ]]; then
    echo "  DELETE? $hit"; del_n=$((del_n + 1))
  elif [[ "$file" =~ $REVIEW_PATHS ]]; then
    echo "  REVIEW  $hit"; rev_n=$((rev_n + 1))
  elif [[ "$text" =~ ^[[:space:]]*# ]]; then
    # A comment may describe THIS cluster (rewrite) or state a fact about
    # another one (rewriting makes it a lie). Not decidable mechanically.
    echo "  COMMENT $hit"; com_n=$((com_n + 1))
  else
    echo "  AUTO    $hit"; auto_n=$((auto_n + 1))
    auto_files+=("$file")
    auto_lines["$file"]+="$lineno "
  fi
done

if [[ ${#auto_files[@]} -gt 0 ]]; then
  mapfile -t auto_files < <(printf '%s\n' "${auto_files[@]}" | sort -u)
fi

echo
echo "AUTO    : $auto_n line(s) in ${#auto_files[@]} file(s) — functional config, rewritten"
echo "COMMENT : $com_n line(s) — read them; rewrite only those describing THIS cluster"
echo "REVIEW  : $rev_n line(s) — ECR; role name is ours, registry account may be central"
echo "DELETE? : $del_n line(s) — RisingWave, omitted from prod; remove the files instead"
echo "SKIPPED : $skip_n line(s) in docs/ADRs — historical records, never rewritten"

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
# Line-scoped, not file-scoped: several files hold BOTH a functional literal and
# a comment describing another cluster. A whole-file sed would rewrite the
# comment too and turn it into a false statement.
for f in "${auto_files[@]}"; do
  for ln in ${auto_lines[$f]}; do
    sed -i "${ln}{
      s/$QA_CLUSTER/$PROD_CLUSTER/g
      s/$DEV_CLUSTER/$PROD_CLUSTER/g
      s/$QA_ACCT/$PROD_ACCT/g
      s/$DEV_ACCT/$PROD_ACCT/g
      s/$QA_VIP/$PROD_VIP/g
      s/$DEV_VIP/$PROD_VIP/g
    }" "$f"
  done
  echo "  rewrote $f (lines: ${auto_lines[$f]})"
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
