#!/usr/bin/env bash
# merge-into-repo.sh — reconcile the Argo CD IaC design with what is ALREADY in
# variant-inc/iaac-argocd-onprem.
#
# Replaces seed-argocd-repo.sh, which wrongly assumed an empty repo and
# overwrote two of Idris's kustomization.yaml files.
#
#   cd ~/work/iaac-argocd-onprem
#   bash ~/work/eks_code/iaac-drafts/argocd-onprem-jul22/merge-into-repo.sh
#
# KEEPS Idris's work: argocd-admin-externalsecret.yaml, argocd-git-externalsecret.yaml,
#   namespace.yaml. His ExternalSecrets are correct for this cluster
#   (ClusterSecretStore `default`, apiVersion external-secrets.io/v1) - the
#   drafted base version was wrong on both and has been deleted.
#
# REMOVES three things, each for a specific reason:
#   application-risingwave.yaml  Argo CD Application -> namespace risingwave, from
#                                the same path Flux reconciles, project: default,
#                                prune+selfHeal+ServerSideApply. Two controllers
#                                self-healing identical objects fight forever and
#                                prune can delete resources in Tim's namespace.
#                                This is what PR #73 was rejected for, escalated.
#   service-nodeport.yaml        Platform standard is Istio ingress. It also mapped
#                                :443 to a plain-HTTP targetPort 8080.
#   remote install.yaml          A live raw.githubusercontent.com fetch inside the
#                                reconcile path, and raw manifests accept no values
#                                (no nodeSelector, no resource limits). Replaced by
#                                the pinned Helm chart in base/.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(git remote get-url origin 2>/dev/null || echo none)" in
  *iaac-argocd-onprem*) ;;
  *) echo "ERROR: run from ~/work/iaac-argocd-onprem" >&2; exit 1 ;;
esac

echo "==> branch"
git checkout -B feat/argocd-iac

echo "==> copy base + overlays"
mkdir -p manifests
cp -r "${SRC}/manifests/base" manifests/
cp "${SRC}/manifests/op-usxpress-dev/kustomization.yaml" manifests/op-usxpress-dev/kustomization.yaml
cp "${SRC}/manifests/op-usxpress-qa/kustomization.yaml"  manifests/op-usxpress-qa/kustomization.yaml
cp "${SRC}/README.md" README.md
mkdir -p docs && cp "${SRC}/cluster-wiring/argocd.yaml" docs/cluster-wiring-argocd.yaml

echo "==> remove the three"
for env in op-usxpress-dev op-usxpress-qa; do
  git rm -q --ignore-unmatch \
    "manifests/${env}/application-risingwave.yaml" \
    "manifests/${env}/service-nodeport.yaml" 2>/dev/null || true
  rm -f "manifests/${env}/application-risingwave.yaml" "manifests/${env}/service-nodeport.yaml"
done

# argocd-cm-patch.yaml patched the ConfigMap created by the raw install.yaml.
# Under the Helm chart, argocd-cm is rendered by Helm at runtime, so a kustomize
# patch has no target. Its settings are folded into base/helmrelease.yaml under
# values.configs.cm (resource.exclusions MERGED with the Flux-CRD exclusion, plus
# every ignoreResourceUpdates key), so the file is now redundant.
echo "==> remove argocd-cm-patch.yaml (folded into helmrelease values)"
for env in op-usxpress-dev op-usxpress-qa; do
  git rm -q --ignore-unmatch "manifests/${env}/argocd-cm-patch.yaml" 2>/dev/null || true
  rm -f "manifests/${env}/argocd-cm-patch.yaml"
done

echo ""
echo "==> verify"
FAIL=0
for env in op-usxpress-dev op-usxpress-qa; do
  echo "--- ${env} ---"
  if ! kubectl kustomize "manifests/${env}" > "/tmp/argocd-${env}.yaml" 2>"/tmp/argocd-${env}.err"; then
    echo "  BUILD FAILED:"; sed 's/^/    /' "/tmp/argocd-${env}.err"; FAIL=1; continue
  fi
  echo "  build OK ($(wc -l < "/tmp/argocd-${env}.yaml") lines)"
  for pat in 'kind: Application' 'NodePort' 'raw.githubusercontent.com'; do
    if grep -q "${pat}" "/tmp/argocd-${env}.yaml"; then
      echo "  FAIL: '${pat}' still rendered"; FAIL=1
    fi
  done
  python3 - "/tmp/argocd-${env}.yaml" <<'PY'
import sys
doc = open(sys.argv[1]).read()
blocks = [b for b in doc.split('---') if 'kind: AppProject' in b and 'name: default' in b]
if not blocks:
    print("  FAIL: default AppProject not declared (chart ships it permissive)"); sys.exit(1)
if 'destinations: []' not in blocks[0]:
    print("  FAIL: default AppProject destinations not empty"); sys.exit(1)
print("  default AppProject neutered: OK")
PY
  # The folded argocd-cm settings must be present, or the patch removal
  # silently dropped them.
  for key in 'cilium.io' 'notification.toolkit.fluxcd.io' 'ignoreResourceUpdates.all'; do
    if ! grep -q "${key}" "/tmp/argocd-${env}.yaml"; then
      echo "  FAIL: folded argocd-cm setting missing: ${key}"; FAIL=1
    fi
  done

  # ExternalSecrets must target the store that actually exists.
  if grep -q 'name: aws-secretsmanager' "/tmp/argocd-${env}.yaml"; then
    echo "  FAIL: references ClusterSecretStore aws-secretsmanager (cluster has 'default')"; FAIL=1
  fi
  if grep -q 'external-secrets.io/v1beta1' "/tmp/argocd-${env}.yaml"; then
    echo "  FAIL: v1beta1 ExternalSecret (cluster serves external-secrets.io/v1 only)"; FAIL=1
  fi
done

echo ""
if [[ ${FAIL} -ne 0 ]]; then
  echo "==> VERIFICATION FAILED - do not commit."; exit 1
fi
git add -A
git status --short
cat <<'EOF'

==> All checks passed. Review, then:
     git commit -m "feat: Argo CD as an app-layer controller, Flux-installed (INFRA-1622)"
     git push -u origin feat/argocd-iac
     gh pr create --base main --fill

==> Before dev rollout:
  1. Chart version: base/helmrelease.yaml pins argo-cd 7.7.11. Idris's raw
     manifest was Argo CD v3.4.3 - pick deliberately, they are far apart.
       helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
       helm search repo argo/argo-cd --versions | head
  2. Confirm SM op-usxpress-dev/argocd/git_private_key exists, or drop the git
     ExternalSecret until an actual app repo needs it.
  3. Doke lands docs/cluster-wiring-argocd.yaml into iaac-talos-flux-cluster.

==> After it reconciles - run the guardrail test. This is the whole point.
     kubectl -n argocd get appproject default -o jsonpath='{.spec.destinations}'   # []
     argocd app create probe --repo <any> --path . \
       --dest-namespace risingwave --dest-server https://kubernetes.default.svc
     # MUST be refused. If accepted, stop - that is PR #73's failure mode.
EOF
