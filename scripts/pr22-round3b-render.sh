#!/usr/bin/env bash
# Round 3b: render the QA overlay from the #22 branch and see what QA would ACTUALLY get.
# Read-only. The base dropped the entity entries; the overlay still names entity-postgres,
# so the rendered output is the only thing that settles what lands.
set -uo pipefail
REPO="variant-inc/risingwave-pipeline"
BRANCH="cutover/qa-brand-pipeline"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

gh repo clone "$REPO" "$T/rp" -- --quiet 2>/dev/null || { echo "clone failed"; exit 3; }
git -C "$T/rp" fetch --quiet origin "$BRANCH:pr22" || { echo "fetch failed"; exit 3; }
git -C "$T/rp" checkout --quiet pr22
cd "$T/rp"
echo "branch head: $(git rev-parse --short HEAD)"
echo

echo "########## 1. the QA overlay's kustomization.yaml (in full) ##########"
cat deploy/overlays/qa/kustomization.yaml
echo
echo "########## 2. the QA overlay's endpoints.yaml (in full) ##########"
cat deploy/overlays/qa/endpoints.yaml
echo
echo "########## 3. the base ExternalSecret after his edit ##########"
cat deploy/base/externalsecret.yaml
echo
echo "########## 4. RENDERED -- what Argo would apply to QA ##########"
if kubectl kustomize deploy/overlays/qa > "$T/rendered.yaml" 2>"$T/err"; then
  echo "kustomize build: OK"
  echo
  echo "-- rendered ExternalSecret remoteRefs:"
  grep -nE 'secretKey:|key:|property:' "$T/rendered.yaml" | sed 's/^/   /'
  echo
  echo "-- rendered Job env drawn from the Secret:"
  grep -nE 'name: (RW_|PG_|POSTGRES_|KAFKA_)|secretKeyRef|optional' "$T/rendered.yaml" | sed 's/^/   /'
  echo
  echo "-- does 'entity-postgres' survive into what QA gets?"
  if grep -q 'entity-postgres\|POSTGRES_ENTITY' "$T/rendered.yaml"; then
    echo "   YES -- STILL THERE. The wedge is not fixed:"
    grep -n 'entity-postgres\|POSTGRES_ENTITY' "$T/rendered.yaml" | sed 's/^/      /'
  else
    echo "   no -- clean. The wedge is fixed."
  fi
else
  echo "kustomize build: FAILED -- Argo would report a sync error, not apply anything:"
  sed 's/^/   /' "$T/err"
fi
echo
echo "########## 5. do the Brand files the overlay selects exist? ##########"
echo "-- everything under pipelines/Brand/:"
ls -1 pipelines/Brand/ | sed 's/^/   /'
echo
echo "-- every %TOKEN% in the Brand files (case-exact paths above):"
for f in pipelines/Brand/*.rw pipelines/Brand/*.sql; do
  [ -e "$f" ] || continue
  printf '   %s\n' "$f"
  grep -ohE '%[A-Z][A-Z0-9_]*%' "$f" 2>/dev/null | sort -u | sed 's/^/      /'
done
