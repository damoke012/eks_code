# Flux Platform Changes for On-Prem MageRunner

Changes needed in `iaac-talos-flux-platform` (op-dev branch) to support
MageRunner CI/CD deployments. All changes are on the op-dev branch only —
cloud Flux repos are untouched.

## 1. ClusterSecretStore — update API version to v1

**File:** `infrastructure/external-secrets-config/clustersecretstore.yaml`

**Change:** `apiVersion: external-secrets.io/v1beta1` → `apiVersion: external-secrets.io/v1`

ESO 2.x removed v1beta1 as a served version. The CRD still accepts v1beta1
via conversion webhook but kubectl apply fails because the webhook is not
always ready during bootstrap.

```yaml
# Before
apiVersion: external-secrets.io/v1beta1

# After
apiVersion: external-secrets.io/v1
```

## 2. Namespace PodSecurity — set to privileged

**Files:** All namespace manifests in `infrastructure/app-namespaces/`

**Change:** Add `pod-security.kubernetes.io/enforce: privileged` label.

MageRunner Helm charts include Istio sidecar injection (istio-init container
needs NET_ADMIN + NET_RAW capabilities). The default PodSecurity `baseline`
blocks these capabilities.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: enterprise
  labels:
    pod-security.kubernetes.io/enforce: privileged
    istio.io/dataplane-mode: ambient
```

Apply to ALL app namespaces, not just enterprise.

## 3. Namespace Istio labels — remove sidecar injection

**Files:** All namespace manifests in `infrastructure/app-namespaces/`

**Change:** Do NOT add `istio-injection: enabled` label. Keep only
`istio.io/dataplane-mode: ambient`.

The on-prem cluster uses Istio ambient mode (ztunnel), not sidecar mode.
MageRunner re-adds `istio-injection=enabled` on each deploy — this is a
known issue that needs a MageRunner fork fix (add a flag to skip sidecar
label when running in ambient mode).

**Interim workaround:** The namespace manifest in Flux should NOT have
`istio-injection: enabled`. MageRunner will add it, but Flux will
reconcile and remove it on next sync cycle.

## 4. ESO version — already done

**File:** `infrastructure/external-secrets/helmrelease.yaml`

**Change:** `version: "0.12.x"` → `version: "2.2.x"` — committed as 053ebd4.

## Summary of git changes needed

```bash
cd ~/iaac-talos-flux-platform
git checkout op-dev

# 1. ClusterSecretStore v1
sed -i 's/external-secrets.io\/v1beta1/external-secrets.io\/v1/' \
  infrastructure/external-secrets-config/clustersecretstore.yaml

# 2. Namespace PodSecurity (for each namespace file)
# Add label: pod-security.kubernetes.io/enforce: privileged
# This needs per-file editing — see namespace manifests

git add -A
git commit -m "fix: update ESO to v1 API, add PodSecurity privileged labels for MageRunner"
git push
```
