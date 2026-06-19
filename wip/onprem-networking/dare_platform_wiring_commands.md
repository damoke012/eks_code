# Dare-Cluster Platform Wiring — Complete Command Reference

**Purpose:** All commands needed to wire the dare-cluster to platform components via Flux.
**Run from:** WSL (Ubuntu 24.04)
**Prerequisites:** VPN connected, GitHub token with write access + SSO authorized

---

## BEFORE YOU START — Pre-Flight Checks

```bash
# 1. Verify VPN is connected (can reach vSphere / cluster)
ping -c 1 10.10.82.20

# 2. Verify kubectl works against dare-cluster
export KUBECONFIG=~/.kube/dare-cluster.yaml
kubectl get nodes

# 3. Verify Flux is running
kubectl get pods -n flux-system

# 4. Verify your GitHub auth works
gh auth status

# If not authenticated:
gh auth login
# Choose: GitHub.com → HTTPS → Paste your token

# 5. Verify you have write access to both repos
gh repo view variant-inc/iaac-talos-flux-cluster --json nameWithOwner
gh repo view variant-inc/iaac-talos-flux-platform --json nameWithOwner

# 6. Verify git config (so commits have your name)
git config --global user.name
git config --global user.email

# If not set:
git config --global user.name "Doke Oxley"
git config --global user.email "doke.oxley@usxpress.com"
```

---

## STEP 1: Create `dare` Branch in `iaac-talos-flux-platform`

```bash
# Navigate to or clone the platform repo
cd ~

# If not yet cloned:
gh repo clone variant-inc/iaac-talos-flux-platform
# OR with git:
git clone https://github.com/variant-inc/iaac-talos-flux-platform.git

cd ~/iaac-talos-flux-platform
```

### 1a. Create the dare branch based on dpl

```bash
# Fetch all remote branches
git fetch origin

# Check out the dpl branch (this is our source/template)
git checkout dpl

# Pull latest to make sure you're current
git pull origin dpl

# Create the dare branch from dpl
git checkout -b dare

# Verify you're on the dare branch
git branch
```

**Edge case — branch already exists remotely:**
```bash
# Check if dare branch already exists on remote
git branch -r | grep dare

# If it does, check it out instead of creating:
git checkout -b dare origin/dare

# If it exists locally but you want to reset to dpl:
git branch -D dare
git checkout -b dare origin/dpl
```

**Edge case — detached HEAD or wrong branch:**
```bash
# Verify current branch
git status

# If detached HEAD:
git checkout -b dare
```

### 1b. Update environment-specific values

There are **4 files** that contain DPL-specific values that need updating:

#### File 1: `infrastructure/istio/istiod/values.yaml`

```bash
vi infrastructure/istio/istiod/values.yaml
```

**Changes to make (3 replacements):**

| Line | DPL Value | Dare Value |
|---|---|---|
| 10 | `meshID: dpl.mesh.usxpress` | `meshID: dare.mesh.usxpress` |
| 11 | `cluster: dpl.talos.mesh.usxpress` | `cluster: dare.talos.mesh.usxpress` |
| 23 | `trustDomain: dpl.mesh.usxpress` | `trustDomain: dare.mesh.usxpress` |

**In vi:**
```
:%s/dpl\.mesh\.usxpress/dare.mesh.usxpress/g
:%s/dpl\.talos\.mesh\.usxpress/dare.talos.mesh.usxpress/g
:wq
```

**Verify:**
```bash
grep -n "dpl" infrastructure/istio/istiod/values.yaml
# Should return NOTHING — all dpl references should be gone
grep -n "dare" infrastructure/istio/istiod/values.yaml
# Should show 3 lines with dare
```

#### File 2: `infrastructure/istio-csr/values.yaml`

```bash
vi infrastructure/istio-csr/values.yaml
```

**Change (1 replacement):**

| Line | DPL Value | Dare Value |
|---|---|---|
| 11 | `trustDomain: dpl.mesh.usxpress` | `trustDomain: dare.mesh.usxpress` |

**In vi:**
```
:%s/dpl\.mesh\.usxpress/dare.mesh.usxpress/g
:wq
```

**Verify:**
```bash
grep -n "dpl" infrastructure/istio-csr/values.yaml
# Should return NOTHING
```

#### File 3: `infrastructure/cert-manager-issuers/issuer.yaml`

```bash
vi infrastructure/cert-manager-issuers/issuer.yaml
```

**Change (1 replacement):**

| Line | DPL Value | Dare Value |
|---|---|---|
| 29 | `- dpl.mesh.usxpress` | `- dare.mesh.usxpress` |

**In vi:**
```
:%s/dpl\.mesh\.usxpress/dare.mesh.usxpress/g
:wq
```

**Verify:**
```bash
grep -n "dpl" infrastructure/cert-manager-issuers/issuer.yaml
# Should return NOTHING
```

#### File 4: `infrastructure/cilium-lb/resources.yaml`

```bash
vi infrastructure/cilium-lb/resources.yaml
```

**Change (1 replacement — pool name):**

| Line | DPL Value | Dare Value |
|---|---|---|
| 26 | `name: dpl-lb-pool` | `name: dare-lb-pool` |

**In vi:**
```
:%s/dpl-lb-pool/dare-lb-pool/g
:wq
```

**ASK OMAR: IP range for dare-cluster LB pool.** Currently set to:
```yaml
  blocks:
  - start: "10.10.82.20"
    stop: "10.10.82.254"
```
- If dare shares the same VLAN (10.10.82.x), this range MAY conflict with DPL
- Omar or Jeremy Keys may want a different range or the same range
- If a different range is needed:
```
# In vi, change lines 29-30:
  blocks:
  - start: "NEW_START_IP"
    stop: "NEW_END_IP"
```

**Verify all changes:**
```bash
# Search all files for any remaining "dpl" references
grep -r "dpl" infrastructure/
# The ONLY match should be NOTHING, OR any that are intentionally shared
# (network name "10.10.82 (vLAN 82) Prod" is fine — that's the actual network name)
```

### 1c. Commit and push the dare branch

```bash
# Review all changes
git diff

# Stage all changes
git add -A

# Commit
git commit -m "Create dare branch with dare-specific mesh and LB config"

# Push the new branch to remote
git push -u origin dare
```

**Edge case — push rejected (no write access):**
```bash
# Error: remote: Write access to repository not granted
# Fix: Ask Omar to add you with Write role on iaac-talos-flux-platform

# Verify your current access:
gh api repos/variant-inc/iaac-talos-flux-platform --jq '.permissions'
```

**Edge case — push rejected (SAML SSO):**
```bash
# Error: The 'variant-inc' organization has enabled or enforced SAML SSO
# Fix: Go to https://github.com/settings/tokens → Configure SSO → Authorize for variant-inc
```

**Edge case — push rejected (branch protection):**
```bash
# If the repo has branch protection requiring PRs:
# Option A: Push to a feature branch and PR into dare
git push -u origin dare:dare-initial-setup
gh pr create --base dare --head dare-initial-setup --title "Initialize dare branch" --body "Branch from dpl with dare-specific mesh config"

# Option B: Ask Omar if dare branch needs protection rules updated
```

**Edge case — authentication prompt:**
```bash
# If git asks for username/password:
# Use your GitHub token as the password
# Username: your-github-username (dare-x)
# Password: ghp_YOUR_TOKEN

# Or configure credential helper:
gh auth setup-git
```

---

## STEP 2: Add Wiring Files to `clusters/dare/` in Flux-Cluster Repo

```bash
cd ~

# If not yet cloned:
gh repo clone variant-inc/iaac-talos-flux-cluster
# OR:
git clone https://github.com/variant-inc/iaac-talos-flux-cluster.git

cd ~/iaac-talos-flux-cluster
```

### 2a. Pull latest and check for existing dare directory

```bash
git fetch origin
git checkout master
git pull origin master

# Check if Flux already created clusters/dare/
ls clusters/
# Expected: you should see "dpl" and possibly "dare"

# If dare exists, check what's in it:
ls -la clusters/dare/flux-system/
```

**Edge case — dare directory doesn't exist yet:**
```bash
# Flux bootstrap should have created it. If it didn't:
mkdir -p clusters/dare/flux-system
```

**Edge case — repo uses a different default branch:**
```bash
# Check which branch:
git remote show origin | grep "HEAD branch"

# If it's not master:
git checkout main  # or whatever the default is
```

### 2b. Create `infra-source.yaml`

```bash
cat > clusters/dare/flux-system/infra-source.yaml << 'EOF'
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: infra
  namespace: flux-system
spec:
  interval: 5m0s
  url: https://github.com/variant-inc/iaac-talos-flux-platform
  ref:
    branch: dare
  secretRef:
    name: flux-system
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: gateway-api-upstream
  namespace: flux-system
spec:
  interval: 24h
  url: https://github.com/kubernetes-sigs/gateway-api
  ref:
    tag: v1.4.0
  ignore: |
    /*
    !/config/crd
EOF
```

**Verify:**
```bash
cat clusters/dare/flux-system/infra-source.yaml
# Confirm branch says "dare" (not "dpl")
grep "branch:" clusters/dare/flux-system/infra-source.yaml
```

### 2c. Create `infra.yaml`

```bash
cat > clusters/dare/flux-system/infra.yaml << 'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cert-manager
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/cert-manager
  prune: true
  wait: true
  timeout: 5m
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: gateway-api
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: gateway-api-upstream
  path: ./config/crd/standard
  prune: false
  wait: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: istio-namespace
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/istio
  prune: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cert-manager-issuers
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/cert-manager-issuers
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
  - name: cert-manager
  - name: istio-namespace
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: istio-csr
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/istio-csr
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
  - name: cert-manager-issuers
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: istio-base
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/istio/base
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
  - name: istio-csr
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: istio-istiod
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/istio/istiod
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
  - name: istio-base
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: istio-cni
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/istio/cni
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
  - name: istio-istiod
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: istio-ztunnel
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/istio/ztunnel
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
  - name: istio-cni
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cilium-lb
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/cilium-lb
  prune: true
  wait: true
EOF
```

**Verify:**
```bash
cat clusters/dare/flux-system/infra.yaml
# Count the Kustomization resources (should be 10)
grep "kind: Kustomization" clusters/dare/flux-system/infra.yaml | wc -l
```

### 2d. Update `kustomization.yaml` to include the new files

```bash
# First check current contents
cat clusters/dare/flux-system/kustomization.yaml
```

**If the file exists (Flux bootstrap created it):**
```bash
vi clusters/dare/flux-system/kustomization.yaml
```

**It should look like this when done:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- gotk-components.yaml
- gotk-sync.yaml
- infra-source.yaml
- infra.yaml
```

**In vi — add the two new lines under `resources:`:**
```
# Position cursor on the line with "- gotk-sync.yaml"
# Press o to open a new line below
# Type:
- infra-source.yaml
- infra.yaml
# Press Esc, then :wq
```

**If the file doesn't exist (edge case):**
```bash
cat > clusters/dare/flux-system/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- gotk-components.yaml
- gotk-sync.yaml
- infra-source.yaml
- infra.yaml
EOF
```

**Verify:**
```bash
cat clusters/dare/flux-system/kustomization.yaml
# Must have all 4 resources listed
```

### 2e. Verify the gotk-sync.yaml points to clusters/dare

```bash
cat clusters/dare/flux-system/gotk-sync.yaml
# Look for:  path: ./clusters/dare
# If it says ./clusters/dpl — that's WRONG, it should say dare
```

**Edge case — gotk-sync.yaml has wrong path:**
```bash
vi clusters/dare/flux-system/gotk-sync.yaml
# Find the line with "path:" and change dpl to dare
# ONLY change the path, nothing else (this file is auto-generated by Flux)
```

### 2f. Commit and push

```bash
# Review all changes
git status
git diff

# Stage the new/modified files
git add clusters/dare/flux-system/infra-source.yaml
git add clusters/dare/flux-system/infra.yaml
git add clusters/dare/flux-system/kustomization.yaml

# Commit
git commit -m "Add platform component wiring for dare-cluster"

# Push
git push origin master
```

**Edge case — push rejected (branch protection on master):**
```bash
# Create a feature branch and PR instead:
git checkout -b dare-platform-wiring
git push -u origin dare-platform-wiring

gh pr create \
  --base master \
  --head dare-platform-wiring \
  --title "Add platform wiring for dare-cluster" \
  --body "Adds infra-source.yaml and infra.yaml to clusters/dare/flux-system/ to deploy platform components (cert-manager, Istio ambient, Cilium LB) via Flux."

# Then merge the PR (if you have permission):
gh pr merge --merge
```

**Edge case — merge conflict on master:**
```bash
git pull origin master --rebase
# Resolve any conflicts, then:
git add .
git rebase --continue
git push origin master
```

---

## STEP 3: Verify Flux Reconciliation

After pushing, Flux will detect the changes within ~1 minute (gotk-sync interval). Then it will start deploying components in dependency order.

### 3a. Watch Flux pick up the changes

```bash
export KUBECONFIG=~/.kube/dare-cluster.yaml

# Watch Flux reconcile the cluster repo source (should update within 1 min)
kubectl get gitrepositories -n flux-system
# "flux-system" should show recent "READY: True"

# Force immediate reconciliation (don't wait for interval):
kubectl annotate gitrepository flux-system -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Watch the new "infra" GitRepository get created
kubectl get gitrepositories -n flux-system -w
# Should see "infra" and "gateway-api-upstream" appear
```

### 3b. Watch Kustomizations deploy

```bash
# Watch all kustomizations (they deploy in dependency order)
kubectl get kustomizations -n flux-system -w

# Or check status in a loop:
watch -n 5 'kubectl get kustomizations -n flux-system'

# Expected deployment order:
# 1. cert-manager        (no deps)
# 2. gateway-api         (no deps)
# 3. istio-namespace     (no deps)
# 4. cert-manager-issuers (after cert-manager + istio-namespace)
# 5. istio-csr           (after cert-manager-issuers)
# 6. istio-base          (after istio-csr)
# 7. istio-istiod        (after istio-base)
# 8. istio-cni           (after istio-istiod)
# 9. istio-ztunnel       (after istio-cni)
# 10. cilium-lb          (no deps)
```

### 3c. Watch HelmReleases

```bash
# Watch Helm releases install
kubectl get helmreleases -A -w

# Or in a loop:
watch -n 5 'kubectl get helmreleases -A'

# Expected HelmReleases:
# cert-manager/cert-manager         v1.19.1
# istio-system/istio-base           1.27.3
# istio-system/istiod               1.27.3
# istio-system/istio-cni            1.27.3 (shown as "cni")
# istio-system/istio-ztunnel        1.27.3
# cert-manager/cert-manager-istio-csr  0.14.3 (shown as "istio-csr")
```

### 3d. Watch pods come up

```bash
# Watch all pods across all namespaces
kubectl get pods -A -w

# Or specific namespaces:
kubectl get pods -n cert-manager
kubectl get pods -n istio-system

# Check for any pods stuck in CrashLoopBackOff or Error
kubectl get pods -A | grep -v Running | grep -v Completed
```

### 3e. Full verification checklist

```bash
# 1. All GitRepositories healthy
kubectl get gitrepositories -n flux-system
# flux-system: True, infra: True, gateway-api-upstream: True

# 2. All Kustomizations healthy
kubectl get kustomizations -n flux-system
# All 10 + flux-system should show "True"

# 3. All HelmReleases healthy
kubectl get helmreleases -A
# All should show "True" and correct version

# 4. Cert Manager pods running
kubectl get pods -n cert-manager
# cert-manager, cert-manager-cainjector, cert-manager-webhook, cert-manager-istio-csr

# 5. Istio pods running
kubectl get pods -n istio-system
# istiod, istio-cni (daemonset), ztunnel (daemonset)

# 6. Cilium LB pool created
kubectl get ciliumloadbalancerippool
# dare-lb-pool (or dpl-lb-pool depending on name)

# 7. L2 announcement policy exists
kubectl get ciliuml2announcementpolicy

# 8. Gateway API CRDs installed
kubectl get crds | grep gateway

# 9. Certificates issued
kubectl get certificates -n istio-system
# istio-ca should be Ready

# 10. Issuers created
kubectl get issuers -n istio-system
# selfsigned, istio-ca
```

---

## TROUBLESHOOTING — Common Issues During Wiring

### GitRepository "infra" shows False / NotReady

```bash
# Check the error
kubectl describe gitrepository infra -n flux-system

# Common causes:
# 1. Branch "dare" doesn't exist in platform repo
git ls-remote https://github.com/variant-inc/iaac-talos-flux-platform | grep dare

# 2. Flux secret doesn't have access to platform repo
kubectl get secret flux-system -n flux-system
# If missing, Flux bootstrap may need to be re-done

# 3. Wrong repo URL in infra-source.yaml
kubectl get gitrepository infra -n flux-system -o yaml | grep url
```

### Kustomization stuck in "dependency not ready"

```bash
# Check which dependency is failing
kubectl describe kustomization <name> -n flux-system

# Check the dependency's status
kubectl get kustomization <dependency-name> -n flux-system -o yaml | grep -A5 "status:"

# Force retry
kubectl annotate kustomization <name> -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

### HelmRelease shows "install retries exhausted"

```bash
# Get detailed error
kubectl describe helmrelease <name> -n <namespace>

# Check Helm history
kubectl get helmrelease <name> -n <namespace> -o yaml | grep -A20 "status:"

# Reset the HelmRelease to retry
kubectl patch helmrelease <name> -n <namespace> --type=merge -p '{"spec":{"install":{"remediation":{"retries":-1}}}}'

# Or suspend and resume:
kubectl patch helmrelease <name> -n <namespace> --type=merge -p '{"spec":{"suspend":true}}'
kubectl patch helmrelease <name> -n <namespace> --type=merge -p '{"spec":{"suspend":false}}'
```

### Cert Manager pods not starting (webhook timeout)

```bash
# Check cert-manager pod logs
kubectl logs -n cert-manager -l app=cert-manager --tail=50
kubectl logs -n cert-manager -l app=webhook --tail=50

# Cert Manager needs CRDs first — check if CRDs exist
kubectl get crds | grep cert-manager

# If CRDs are missing, the HelmRelease may need to be reconciled
kubectl annotate helmrelease cert-manager -n cert-manager reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

### Istio CSR fails (waiting for root CA secret)

```bash
# The root-ca-secret.yaml creates a Job that extracts the CA cert
# Check if the job ran
kubectl get jobs -n cert-manager
kubectl logs job/create-istio-root-ca -n cert-manager

# Check if the istio-ca certificate was created
kubectl get certificate istio-ca -n istio-system

# Check if the secret was propagated
kubectl get secret istio-root-ca -n cert-manager
```

### Istiod fails to start

```bash
# Check istiod logs
kubectl logs -n istio-system -l app=istiod --tail=50

# Common issue: CA server address wrong
kubectl get configmap istiod-values -n istio-system -o yaml | grep caAddress

# Check the istio-system namespace has correct PSS labels
kubectl get namespace istio-system --show-labels | grep pod-security
```

### Ztunnel or CNI daemonset not running on all nodes

```bash
# Check daemonset status
kubectl get daemonset -n istio-system

# Check if nodes are tainted
kubectl describe nodes | grep -A3 Taints

# Check CNI plugin logs
kubectl logs -n istio-system -l app=istio-cni --tail=50
kubectl logs -n istio-system -l app=ztunnel --tail=50
```

### Cilium LB pool / L2 policy not working

```bash
# Check if Cilium CRDs exist
kubectl get crds | grep cilium

# Check the resources were applied
kubectl get ciliumloadbalancerippool -o yaml
kubectl get ciliuml2announcementpolicy -o yaml

# Check Cilium agent logs for L2 errors
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-agent --tail=50 | grep -i l2

# Test with a LoadBalancer service
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=LoadBalancer
kubectl get svc nginx -w
# Should get an external IP from the pool
# Clean up after test:
kubectl delete svc nginx
kubectl delete deployment nginx
```

### Nuclear option — remove all platform components and retry

```bash
# Suspend all kustomizations (stops Flux from reconciling)
kubectl get kustomizations -n flux-system --no-headers | awk '{print $1}' | grep -v flux-system | xargs -I{} kubectl patch kustomization {} -n flux-system --type=merge -p '{"spec":{"suspend":true}}'

# Delete all HelmReleases
kubectl delete helmreleases --all -n istio-system
kubectl delete helmreleases --all -n cert-manager

# Delete namespaces (this removes everything in them)
kubectl delete namespace istio-system --timeout=60s
kubectl delete namespace cert-manager --timeout=60s

# Resume kustomizations (Flux will recreate everything)
kubectl get kustomizations -n flux-system --no-headers | awk '{print $1}' | grep -v flux-system | xargs -I{} kubectl patch kustomization {} -n flux-system --type=merge -p '{"spec":{"suspend":false}}'

# Force Flux to re-reconcile everything
kubectl annotate gitrepository flux-system -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

**Edge case — namespace stuck in Terminating:**
```bash
# Find what's blocking deletion
kubectl get namespace istio-system -o json | jq '.status'

# Remove finalizers if stuck
kubectl get namespace istio-system -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/istio-system/finalize" -f -
```

---

## STEP 4: Force Flux Reconciliation (If Changes Aren't Picked Up)

```bash
# Reconcile the cluster repo source
kubectl annotate gitrepository flux-system -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Reconcile the platform repo source
kubectl annotate gitrepository infra -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Reconcile a specific kustomization
kubectl annotate kustomization cert-manager -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Reconcile ALL kustomizations at once
kubectl get kustomizations -n flux-system --no-headers | awk '{print $1}' | xargs -I{} kubectl annotate kustomization {} -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Check Flux logs if nothing is happening
kubectl logs -n flux-system deployment/source-controller --tail=50
kubectl logs -n flux-system deployment/kustomize-controller --tail=50
kubectl logs -n flux-system deployment/helm-controller --tail=50
```

---

## STEP 5: Rollback Commands (If Something Goes Wrong)

### Rollback cluster repo changes (remove wiring)

```bash
cd ~/iaac-talos-flux-cluster

# Remove the wiring files (keeps gotk-* files intact)
git rm clusters/dare/flux-system/infra-source.yaml
git rm clusters/dare/flux-system/infra.yaml

# Revert kustomization.yaml to remove the references
vi clusters/dare/flux-system/kustomization.yaml
# Remove the lines:
# - infra-source.yaml
# - infra.yaml

git add clusters/dare/flux-system/kustomization.yaml
git commit -m "Rollback: remove platform wiring from dare-cluster"
git push origin master
```

### Rollback platform repo dare branch

```bash
cd ~/iaac-talos-flux-platform

# Option A: Delete the remote branch entirely
git push origin --delete dare

# Option B: Reset dare branch to match dpl
git checkout dare
git reset --hard origin/dpl
git push --force origin dare
```

### Undo via git revert (safer than force push)

```bash
# Find the commit to revert
git log --oneline -5

# Revert a specific commit
git revert <commit-hash>
git push origin master
```

---

## QUESTIONS TO ASK OMAR IN THE MEETING

1. **Cilium LB IP range for dare:** Should dare use the same `10.10.82.20-254` range as DPL, or a different range? (They share the same VLAN)
2. **Network name:** Is `"10.10.82 (vLAN 82) Prod"` correct for dare's Istio network setting, or does dare use a different VLAN?
3. **Branch protection:** Are there branch protection rules on `iaac-talos-flux-cluster` master branch that would require PRs?
4. **Branch protection on platform repo:** Can you push a new `dare` branch directly?
5. **clusters/dare/ already created?** Did the Flux bootstrap already create `clusters/dare/flux-system/` on the remote? (We couldn't check from codespace)
6. **Subset deployment:** Should dare get ALL platform components (full DPL parity), or start with a subset?
7. **gotk-sync.yaml branch:** Does dare's `gotk-sync.yaml` point to `master` branch? (Same as DPL — they share the cluster repo on the same branch)
