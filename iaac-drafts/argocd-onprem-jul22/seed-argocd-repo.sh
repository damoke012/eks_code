#!/usr/bin/env bash
# seed-argocd-repo.sh — seed variant-inc/iaac-argocd-onprem with the IaC.
#
#   git clone git@github.com:variant-inc/iaac-argocd-onprem.git ~/work/iaac-argocd-onprem
#   cd ~/work/iaac-argocd-onprem
#   bash ~/work/eks_code/iaac-drafts/argocd-onprem-jul22/seed-argocd-repo.sh
#
# Creates a branch and commits. Does NOT push - review first.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(pwd)"

[[ -d "${REPO}/.git" ]] || { echo "ERROR: not a git repo" >&2; exit 1; }
case "$(git remote get-url origin)" in
  *iaac-argocd-onprem*) ;;
  *) echo "ERROR: origin is not iaac-argocd-onprem: $(git remote get-url origin)" >&2; exit 1 ;;
esac

git checkout -B feat/argocd-iac
mkdir -p manifests
cp -r "${SRC}/manifests/base"            manifests/
cp -r "${SRC}/manifests/op-usxpress-dev" manifests/
cp -r "${SRC}/manifests/op-usxpress-qa"  manifests/
cp "${SRC}/README.md" README.md
mkdir -p docs && cp "${SRC}/cluster-wiring/argocd.yaml" docs/cluster-wiring-argocd.yaml

printf '\n# Terraform / local\n.terraform/\n*.tfstate\n*.tfstate.backup\n' >> .gitignore 2>/dev/null || \
  printf '.terraform/\n*.tfstate\n*.tfstate.backup\n' > .gitignore

echo ""
echo "==> verify both overlays render"
for o in op-usxpress-dev op-usxpress-qa; do
  kubectl kustomize "manifests/${o}" > "/tmp/argocd-${o}.yaml"
  echo "  ${o}: $(wc -l < "/tmp/argocd-${o}.yaml") lines"
  # G5 - no NodePort
  if grep -q 'NodePort' "/tmp/argocd-${o}.yaml"; then echo "  FAIL: NodePort present"; exit 1; fi
  # placeholder must be patched out
  if grep -q 'PLACEHOLDER_SM_PATH' "/tmp/argocd-${o}.yaml"; then echo "  FAIL: SM placeholder leaked"; exit 1; fi
  # G2 - default project must be neutered
  python3 - "/tmp/argocd-${o}.yaml" <<'PY'
import sys, re
doc = open(sys.argv[1]).read()
blocks = [b for b in doc.split('---') if 'kind: AppProject' in b and 'name: default' in b]
assert blocks, "FAIL: default AppProject not declared - chart default ('*') would apply"
b = blocks[0]
assert 'destinations: []' in b, "FAIL: default AppProject destinations not empty"
print("  default AppProject neutered: OK")
PY
done

echo ""
echo "==> G4 - no committed private keys"
if git grep -nEi "sshPrivateKey:[[:space:]]*[^\"'{]" -- manifests/ 2>/dev/null | grep -v '{{'; then
  echo "  FAIL: literal key material in manifests"; exit 1
else
  echo "  OK"
fi

git add -A
echo ""
git status --short
cat <<'EOF'

==> Review, then:
     git commit -m "feat: Argo CD IaC - Flux-installed, app-layer scoped (INFRA-1622)"
     git push -u origin feat/argocd-iac
     gh pr create --base main --fill

==> BEFORE the dev rollout, three prerequisites:
  1. Verify the chart version in manifests/base/helmrelease.yaml (pinned 7.7.11):
       helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
       helm search repo argo/argo-cd --versions | head -5
  2. Create a NEW GitHub deploy key and put it in SM:
       ssh-keygen -t ed25519 -C "argocd-op-usxpress-dev" -f /tmp/argocd-dev-key -N ""
       aws secretsmanager create-secret --profile usx-dev \
         --name op-usxpress-dev/argocd/deploy-key \
         --secret-string "$(python3 -c 'import json,sys;print(json.dumps({"sshPrivateKey":open("/tmp/argocd-dev-key").read()}))')"
       # add /tmp/argocd-dev-key.pub as a deploy key on the target repo, then:
       shred -u /tmp/argocd-dev-key /tmp/argocd-dev-key.pub
     ⚠️ Do NOT reuse the sshPrivateKey committed in iaac-talos-flux-platform PR #73.
        That key is compromised and must be rotated independently of this work.
  3. Doke lands docs/cluster-wiring-argocd.yaml into iaac-talos-flux-cluster as
     clusters/bm-dev/flux-system/argocd.yaml (path ./manifests/op-usxpress-dev).

==> AFTER dev reconciles - the guardrail test is the whole point. Run it.
     kubectl -n argocd get appproject default -o jsonpath='{.spec.destinations}'   # []
     argocd app create probe --repo <repo> --path . \
       --dest-namespace risingwave --dest-server https://kubernetes.default.svc
     # MUST fail: "application destination ... is not permitted in project"
     # If it is ACCEPTED, stop the rollout - that is PR #73's failure mode.
EOF
