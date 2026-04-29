# On-Prem Cluster Access — Provisioning Runbook

**Cluster:** op-usxpress-dev (Talos, https://10.10.82.50:6443)
**Audience:** Cluster admins onboarding new users (engineers, contractors, vendors)
**Last revised:** 2026-04-28

---

## Two access models — read this first

This document covers two access models for the on-prem cluster:

| Model | When to use | Status |
|---|---|---|
| **Azure AD OIDC** ([§ Target state](#target-state--azure-ad-oidc-the-ideal-process)) | Once configured. This is the documented ideal. | 🎯 Target — implementation pending |
| **Per-user X.509 certs** ([§ Bridge process](#bridge-process--per-user-x509-certs)) | Right now, until OIDC is wired up | 🟡 Active — every new user today goes through this |

**The Azure AD OIDC flow is what we want to standardize on.** It mirrors how cloud-team users access EKS (one SSO login, no manual ops per user, AD groups drive permissions). The cert-based flow is a working bridge solution while we get OIDC stood up.

If you're provisioning a user **today**, jump to [§ Bridge process](#bridge-process--per-user-x509-certs). If you're planning the rollout, start with [§ Target state](#target-state--azure-ad-oidc-the-ideal-process).

---

## The principle (read this first)

**The user generates their own private key. It never leaves their machine.**

Only public material crosses the boundary between admin and user:
- A CSR (Certificate Signing Request) — public.
- The signed cert — public.
- The cluster CA — public.
- The cluster API URL — public.

This means **plain Slack / Teams / email is fine** for delivery. No 1Password, no GPG. The user's private key stays on their laptop the entire time.

The opposite anti-pattern (admin generates the key, ships a kubeconfig with the key embedded) creates a key-in-transit problem with no good solution. Don't do it.

---

## Why this matters

| Anti-pattern | Why it's bad |
|---|---|
| Share a kubeconfig with embedded private key | Key transits Slack/email/Drive/1Password — multiple endpoints can be compromised |
| Use shared admin kubeconfig | No audit trail per user; can't revoke individuals |
| Long-lived service account tokens | Revocation requires SA recreation; not auditable |
| Hand-bound RBAC per user | Doesn't scale; inconsistent permissions |

The split-provisioning flow fixes all four.

---

## Prerequisites

### For the cluster admin (provisioner)

1. Active kubectl context for `op-usxpress-dev` with cluster-admin permissions.
2. The `onprem-platform-reader` ClusterRole exists (see [§ One-time cluster setup](#one-time-cluster-setup)).
3. WSL2/Linux shell with `kubectl`, `openssl`, `base64`.
4. Corp VPN reaching `10.10.82.50:6443`.

### For the requester (new user)

1. WSL2 / Linux shell with `openssl` and `kubectl`.
2. Corp VPN reaching `10.10.82.50:6443`. (Verify with `nc -vz 10.10.82.50 6443`.)
3. Knows their own GitHub username, AD user, and primary email — used for the cert CN.

---

## Bridge process — per-user X.509 certs

The flow below (one-time setup → 5-step provisioning → renewal → revocation) is the **bridge** while we build out OIDC. Use it for every user we onboard today. Once OIDC is in production, this section is retired.

### One-time cluster setup

Run this **once per cluster** (not per user). It creates the read-only ClusterRole that all per-user bindings will reference.

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: onprem-platform-reader
  labels:
    purpose: per-user-cluster-access
rules:
# Core API — explicit resource list, secrets intentionally omitted
- apiGroups: [""]
  resources:
  - bindings
  - configmaps
  - endpoints
  - events
  - limitranges
  - namespaces
  - nodes
  - persistentvolumeclaims
  - persistentvolumes
  - pods
  - pods/log
  - pods/status
  - replicationcontrollers
  - resourcequotas
  - serviceaccounts
  - services
  - componentstatuses
  verbs: ["get", "list", "watch"]
# Other API groups — wildcard within each (no secrets exist in these)
- apiGroups:
  - apps
  - autoscaling
  - batch
  - certificates.k8s.io
  - coordination.k8s.io
  - discovery.k8s.io
  - events.k8s.io
  - networking.k8s.io
  - node.k8s.io
  - policy
  - rbac.authorization.k8s.io
  - scheduling.k8s.io
  - storage.k8s.io
  - apiextensions.k8s.io
  - admissionregistration.k8s.io
  # Common CRDs on this cluster
  - cert-manager.io
  - external-secrets.io
  - source.toolkit.fluxcd.io
  - kustomize.toolkit.fluxcd.io
  - helm.toolkit.fluxcd.io
  - notification.toolkit.fluxcd.io
  - image.toolkit.fluxcd.io
  - security.istio.io
  - networking.istio.io
  - telemetry.istio.io
  - extensions.istio.io
  - install.istio.io
  - monitoring.coreos.com
  - keda.sh
  - cilium.io
  - gateway.networking.k8s.io
  resources: ["*"]
  verbs: ["get", "list", "watch"]
EOF
```

**Why explicit enumeration instead of `apiGroups: ["*"], resources: ["*"]`?** RBAC is allow-only — there is no deny rule. To exclude secrets, we must list resources explicitly within the core (`""`) API group, omitting secrets. Wildcard works only for non-core groups (which don't contain secrets).

Adding new resources later: append to the appropriate rule. Re-applying the manifest is idempotent.

---

## Provisioning a new user — 5 steps

Replace `<USER_CN>` with the user's identifier (recommend `firstname-lastname` lowercase, e.g., `idris-fagbemi`, `jane-smith`). This becomes the K8s username and shows in audit logs.

### Step 1 — User generates a key + CSR locally

Send the user this block. They run it on their own WSL2/Linux machine:

```bash
mkdir -p ~/.kube/keys
chmod 700 ~/.kube/keys

# Generate private key — NEVER leaves your machine
openssl genrsa -out ~/.kube/keys/<USER_CN>.key 4096
chmod 600 ~/.kube/keys/<USER_CN>.key

# Generate CSR
openssl req -new -key ~/.kube/keys/<USER_CN>.key \
  -subj "/CN=<USER_CN>/O=onprem-platform-users" \
  -out /tmp/<USER_CN>.csr

# Print the CSR — this is safe to share publicly
cat /tmp/<USER_CN>.csr
```

The user pastes the entire `-----BEGIN CERTIFICATE REQUEST-----...-----END CERTIFICATE REQUEST-----` block back to the admin (Slack, Teams, email — doesn't matter, it's public).

### Step 2 — Admin signs the CSR

On the admin's machine with on-prem cluster access:

```bash
# Working dir
mkdir -p ~/onprem-access/<USER_CN> && cd ~/onprem-access/<USER_CN>

# Save the user's CSR — open editor, paste the CSR they sent
nano <USER_CN>.csr        # or vim, or VS Code

# Verify the CSR has the expected subject
openssl req -in <USER_CN>.csr -noout -subject
# Expected: subject=O = onprem-platform-users, CN = <USER_CN>

# Submit to the K8s CSR API (1-year cert, max allowed by default kube-controller-manager)
kubectl delete csr <USER_CN> --ignore-not-found

cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: <USER_CN>
spec:
  request: $(base64 -w 0 < <USER_CN>.csr)
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000      # 1 year
  usages:
  - client auth
EOF

kubectl certificate approve <USER_CN>
sleep 2

# Extract the signed cert (PUBLIC — safe to share)
kubectl get csr <USER_CN> -o jsonpath='{.status.certificate}' | base64 -d > <USER_CN>.crt

# Sanity-check
openssl x509 -in <USER_CN>.crt -noout -subject -dates
# Expected: notAfter ~1 year out
```

### Step 3 — Admin creates the ClusterRoleBinding

If this is a new user (not a renewal), bind them to the read-only role:

```bash
kubectl create clusterrolebinding "onprem-platform-reader-<USER_CN>" \
  --clusterrole=onprem-platform-reader \
  --user=<USER_CN> \
  --dry-run=client -o yaml | kubectl apply -f -
```

For renewals, the binding already exists — skip this step. The binding is keyed on username, not on the cert, so it works for any cert with the matching CN.

### Step 4 — Admin sends user three things (all non-sensitive)

Run this and copy the output into Slack/Teams to the user:

```bash
# Extract the cluster CA
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > cluster-ca.crt

echo ""
echo "=========================================="
echo "Send these three things to the user:"
echo "=========================================="
echo ""
echo "Server URL:"
echo "  https://10.10.82.50:6443"
echo ""
echo "----- SIGNED CERT (save as ~/.kube/keys/<USER_CN>.crt) -----"
cat <USER_CN>.crt
echo ""
echo "----- CLUSTER CA (save as ~/.kube/keys/op-usxpress-dev-ca.crt) -----"
cat cluster-ca.crt
```

### Step 5 — User assembles their kubeconfig and verifies

Send the user this block. They run it on their machine:

```bash
mkdir -p ~/.kube/configs

# Save the cert + CA from the admin's message
nano ~/.kube/keys/<USER_CN>.crt              # paste the signed cert block
nano ~/.kube/keys/op-usxpress-dev-ca.crt     # paste the cluster CA block

chmod 600 ~/.kube/keys/<USER_CN>.crt ~/.kube/keys/op-usxpress-dev-ca.crt

# Assemble kubeconfig — combines the user's existing key with the admin-supplied cert + CA
CA_DATA=$(base64 -w 0 < ~/.kube/keys/op-usxpress-dev-ca.crt)
CERT_DATA=$(base64 -w 0 < ~/.kube/keys/<USER_CN>.crt)
KEY_DATA=$(base64 -w 0 < ~/.kube/keys/<USER_CN>.key)

cat > ~/.kube/configs/op-usxpress-dev <<EOF
apiVersion: v1
kind: Config
clusters:
- name: op-usxpress-dev
  cluster:
    server: https://10.10.82.50:6443
    certificate-authority-data: ${CA_DATA}
contexts:
- name: op-usxpress-dev
  context:
    cluster: op-usxpress-dev
    user: <USER_CN>
current-context: op-usxpress-dev
users:
- name: <USER_CN>
  user:
    client-certificate-data: ${CERT_DATA}
    client-key-data: ${KEY_DATA}
EOF

chmod 600 ~/.kube/configs/op-usxpress-dev

# Activate
export KUBECONFIG=~/.kube/configs/op-usxpress-dev
echo 'export KUBECONFIG=~/.kube/configs/op-usxpress-dev' >> ~/.bashrc

# Smoke tests
nc -vz 10.10.82.50 6443                  # VPN reachability
kubectl auth whoami                       # → Username: <USER_CN>
kubectl get nodes                         # → 8 nodes Ready
kubectl get pods -A | head -10            # cluster-wide pod list
kubectl auth can-i list secrets -A        # → no
kubectl auth can-i delete pod             # → no
```

If all five smoke checks pass, provisioning is complete.

---

## Admin cleanup after handoff

```bash
cd ~/onprem-access/<USER_CN>

# Cert + CA are public — fine to keep for renewal reference, or delete
rm -f <USER_CN>.csr <USER_CN>.crt cluster-ca.crt

# Confirm no private key was ever generated on admin side
ls -la       # should NOT contain a .key file
```

If the admin ever generated a `.key` file (the legacy/incorrect flow), shred it:

```bash
shred -u <USER_CN>.key
```

And clear terminal scrollback (the kubeconfig text was visible):

```bash
printf '\033c'
history -c && history -w
```

---

## Upgrading an existing user (reader → operator → admin)

Permissions are layered via additive bindings. To upgrade a user, add a new ClusterRoleBinding; remove old ones if cleanup matters (RBAC is additive, so leaving them is harmless).

### Reader → Operator

The operator role is read+write cluster-wide except secrets, RBAC, CRDs. See `onprem-platform-operator` ClusterRole earlier in this runbook.

```bash
# Optionally remove the reader binding for cleanliness
kubectl delete clusterrolebinding onprem-platform-reader-<USER_CN>

# Add the operator binding
kubectl create clusterrolebinding onprem-platform-operator-<USER_CN> \
  --clusterrole=onprem-platform-operator \
  --user=<USER_CN> \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Operator → Admin (cluster-admin)

When the user needs to install operators (CRDs), modify cluster-wide RBAC, or operate as a platform engineer. Reserved for the on-prem platform team.

```bash
kubectl create clusterrolebinding cluster-admin-<USER_CN> \
  --clusterrole=cluster-admin \
  --user=<USER_CN> \
  --dry-run=client -o yaml | kubectl apply -f -

# Verify
kubectl auth can-i create customresourcedefinitions --as=<USER_CN>   # → yes
kubectl auth can-i '*' '*' --as=<USER_CN>                            # → yes
```

cluster-admin **supersedes** the operator and reader roles, so you don't need to delete those bindings — they become redundant. Cleanup is optional.

### Adding namespace-scoped edit (for app teams)

When a user needs full edit on a single namespace (incl. secrets there), without cluster-wide write:

```bash
# Create the namespace if not exists
kubectl create namespace <APP_NAMESPACE> --dry-run=client -o yaml | kubectl apply -f -

# Bind built-in `edit` role at namespace scope
kubectl create rolebinding <USER_CN>-edit-<APP_NAMESPACE> \
  --clusterrole=edit \
  --user=<USER_CN> \
  --namespace=<APP_NAMESPACE> \
  --dry-run=client -o yaml | kubectl apply -f -
```

Use this layered with `onprem-platform-operator` (cluster-wide read) when the user owns one namespace and just needs visibility elsewhere.

---

## Renewal (annual)

Set a calendar reminder ~30 days before cert expiry. The user reuses their existing key — only the cert is reissued.

### User does

```bash
# Reuse the existing key, generate a new CSR
openssl req -new -key ~/.kube/keys/<USER_CN>.key \
  -subj "/CN=<USER_CN>/O=onprem-platform-users" \
  -out /tmp/<USER_CN>.csr

cat /tmp/<USER_CN>.csr      # send to admin
```

### Admin does

Same as Step 2 above. The CSR is replaced (`kubectl delete csr <USER_CN> --ignore-not-found` is idempotent), a new cert is issued. Send the user only the new cert — the CA and URL haven't changed.

### User does

Update only the `client-certificate-data` field in their kubeconfig (or rerun Step 5 with the new cert). The key and CA stay the same.

---

## Revocation

When a user leaves, changes role, or the cert is suspected compromised:

```bash
# Cut access immediately (1 second)
kubectl delete clusterrolebinding onprem-platform-reader-<USER_CN>

# Clean up the CSR record
kubectl delete csr <USER_CN> --ignore-not-found
```

The cert is still cryptographically valid until its expiry, but RBAC denies all actions to the username `<USER_CN>` since the binding is gone. This is the standard prod-grade revocation pattern — strong enough for normal personnel changes.

For a hard cryptographic revocation (suspected serious compromise), the only option is to roll the cluster CA, which is too disruptive for routine cases. Contact the platform team if this is needed.

---

## Common pitfalls (lessons learned from real provisioning sessions)

| Pitfall | What happens | Fix |
|---|---|---|
| Heredoc paste mangles multi-line script | EOF marker collapses with adjacent lines, file is half-saved or doesn't save at all | Don't `cat <<EOF` for anything > 30 lines. Use `nano`/`vim`/VS Code instead |
| `KUBECONFIG` set to placeholder text | kubectl tries to read literal `/path/to/whatever` and fails | Always paste the actual file path; use `unset KUBECONFIG` to clear |
| Wrong kubectl context active | Commands hit cloud EKS instead of on-prem (or vice versa) | `kubectl config current-context` before any operation; make a habit |
| `AWS_PROFILE` not exported | `terraform output` fails with "no credential sources" even though `aws sso login` worked | `export AWS_PROFILE=usx-dev` before any terraform command |
| Stale kubeconfig after cluster rebuild | Cert was signed by old CA; auth fails after rebuild | Refresh from `terraform output -raw kubeconfig` |
| Stale talosconfig after cluster rebuild | `talosctl` fails TLS verify | Refresh from terraform; or update endpoint via `talosctl config endpoint` (only fixes IP, not CA) |
| `verbs: []` in ClusterRole | API rejects with "verbs must contain at least one value" | RBAC is allow-only; enumerate allowed resources, omit the ones you want denied |
| Generating user key on admin side | Key in transit, multiple copies, hard to clean up | Always have the user generate their own key. Admin only sees CSR + cert (both public) |
| Sharing kubeconfig file directly | Embedded key transits multiple systems | Use the split flow — admin sends cert/CA/URL, user assembles locally |
| Forgetting calendar reminder | Cert expires unexpectedly, user loses access mid-work | Set reminder for 30 days before `notAfter` immediately after issuance |

---

## Target state — Azure AD OIDC (the ideal process)

This is the documented **target** for cluster access on op-usxpress-dev (and all future on-prem clusters). Once configured, every step in the bridge process above goes away — no more CSRs, no more per-user kubeconfigs, no more manual cert renewals.

### Why this is the right destination

| Property | Per-user certs (bridge) | Azure AD OIDC (target) |
|---|---|---|
| Onboarding ops per user | Manual CSR sign + kubeconfig assembly | Add to AD group. Done. |
| Offboarding ops per user | Delete ClusterRoleBinding + CSR | Remove from AD group. Done. |
| Audit trail in cluster logs | Username (CN of cert) | Username + groups (from JWT) |
| Cred rotation | Annual cert reissue | Token refresh per session, automatic |
| MFA enforcement | Trust the user has it on their laptop | Enforced at Azure AD login (centralized policy) |
| Conditional access (geo, device compliance) | Not possible | Native via Azure AD policies |
| Time-bounded elevated access (JIT) | Not possible | Native via Azure AD PIM |
| Identity source | One-off cert, no link to corporate identity | Same identity used for AWS SSO, M365, Octopus — single source of truth |
| Scales to 50+ users | Painful | Trivial |

### How it works end-to-end

```
1. User runs:   kubectl get nodes
                     │
2. kubectl checks kubeconfig and sees an `exec` block calling kubelogin/oidc-login
                     │
3. kubelogin opens browser → user logs into Azure AD (with MFA) → returns JWT
                     │
4. kubectl includes the JWT as a bearer token in the API request
                     │
5. Talos kube-apiserver validates the JWT against the Azure AD OIDC issuer
   (signature, issuer, audience, expiry — all checked)
                     │
6. The JWT contains:
   - `preferred_username` claim → mapped to K8s user name
   - `groups` claim → mapped to K8s groups
                     │
7. RBAC bindings against those groups grant the user permissions
                     │
8. Request executes (or denied with `forbidden`)
```

The user logs in **once per ~8 hours**. kubelogin caches the token; subsequent kubectl calls reuse it until expiry.

### Implementation outline (4 phases)

**Phase 1 — Azure AD app registration**

Done by an Azure AD admin (Vibin or USXpress IT):

1. Register a new app in Azure AD: name `op-usxpress-dev-kubernetes` (or per cluster).
2. Set redirect URIs: `http://localhost:8000` (for kubelogin browser flow). Multiple ports for fallback: 8000, 18000, 28000.
3. Configure **Token Configuration** → add the **groups** claim (Security groups) — Azure AD doesn't emit groups by default.
4. Optional: configure **Optional Claims** → emit `preferred_username` (or `upn` or `email`).
5. Create AD security groups:
   - `onprem-platform-admins` — cluster-admin
   - `onprem-platform-operators` — namespace-scoped write
   - `onprem-platform-readers` — read-only
   - Optionally per-app: `onprem-app-<appname>-readers`, `onprem-app-<appname>-operators`
6. Capture: tenant ID, app client ID, group ObjectIDs.

**Phase 2 — Talos kube-apiserver config**

Update the Talos machineconfig (`iaac-talos/deploy/terraform/modules/talos/`) to add OIDC flags to kube-apiserver:

```yaml
# In Talos cluster machine config, under cluster.apiServer.extraArgs:
extraArgs:
  oidc-issuer-url: https://login.microsoftonline.com/<TENANT_ID>/v2.0
  oidc-client-id: <APP_CLIENT_ID>
  oidc-username-claim: preferred_username
  oidc-username-prefix: "oidc:"          # avoids collision with cert users
  oidc-groups-claim: groups
  oidc-groups-prefix: "oidc:"
```

Apply via terraform → triggers a control-plane node config rolling apply. **Test on a non-prod cluster first** — wrong OIDC config can lock out the apiserver. Have the cert-based admin kubeconfig ready as break-glass.

**Phase 3 — RBAC bindings against AD groups**

Once OIDC is wired in, bind the K8s ClusterRoles/Roles to the AD group ObjectIDs (the `oidc:` prefix above prevents typo collisions with cert-based usernames):

```yaml
---
# Cluster-wide read for the readers group
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: onprem-platform-reader-azure
subjects:
- kind: Group
  name: oidc:<READERS_GROUP_OBJECT_ID>      # e.g., oidc:abc123-...
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: onprem-platform-reader               # the same role we use for cert users
  apiGroup: rbac.authorization.k8s.io
---
# Cluster-admin for platform team
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: onprem-platform-admin-azure
subjects:
- kind: Group
  name: oidc:<ADMINS_GROUP_OBJECT_ID>
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin                         # built-in
  apiGroup: rbac.authorization.k8s.io
```

Commit these to `iaac-talos-flux-platform/infrastructure/rbac/` so they're declaratively managed.

**Phase 4 — User onboarding**

The user runs once:

```bash
# Install kubelogin (Azure AD-aware OIDC plugin)
kubectl krew install oidc-login
# or: brew install int128/kubelogin/kubelogin

# Generate kubeconfig — no admin involvement needed
kubectl oidc-login setup \
  --oidc-issuer-url=https://login.microsoftonline.com/<TENANT_ID>/v2.0 \
  --oidc-client-id=<APP_CLIENT_ID>

# Add the cluster
cat >> ~/.kube/config <<EOF
- cluster:
    server: https://10.10.82.50:6443
    certificate-authority-data: <CLUSTER_CA_BASE64>
  name: op-usxpress-dev
- context:
    cluster: op-usxpress-dev
    user: oidc-user
  name: op-usxpress-dev
- user:
    name: oidc-user
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubectl
      args:
      - oidc-login
      - get-token
      - --oidc-issuer-url=https://login.microsoftonline.com/<TENANT_ID>/v2.0
      - --oidc-client-id=<APP_CLIENT_ID>
EOF

# First use — opens browser for Azure AD login
kubectl --context=op-usxpress-dev get nodes
```

**No admin involvement.** Provisioning becomes self-service for anyone in the right AD group.

The cluster CA (still public) and a one-line kubeconfig template can be checked into a public-readable repo or wiki — users just clone + edit `<TENANT_ID>` and `<APP_CLIENT_ID>`.

---

## Restricting access (the access-control patterns)

OIDC is only the auth layer. The actual access restrictions still live in K8s RBAC + Azure AD groups. Here's how to compose them.

### Pattern 1 — Tiered cluster-wide access (the basic three roles)

Define three AD groups, three ClusterRoleBindings:

| AD Group | K8s ClusterRole | Permissions |
|---|---|---|
| `onprem-platform-admins` | `cluster-admin` (built-in) | Everything. Reserved for on-prem platform team only. |
| `onprem-platform-operators` | Custom — see below | Cluster-wide read + write to non-system namespaces |
| `onprem-platform-readers` | `onprem-platform-reader` (already defined in this runbook) | Read-only cluster-wide, no secrets |

Custom `onprem-platform-operator` ClusterRole (write but not cluster-destructive):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: onprem-platform-operator
rules:
# Inherit reader rules + add write
- apiGroups: [""]
  resources: ["configmaps", "services", "pods", "pods/exec", "pods/portforward", "events", "namespaces"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["*"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["*"]
# Explicitly NO: secrets, RBAC, CRDs, nodes — those need admin
```

### Pattern 2 — Namespace-scoped access (most common for app teams)

App teams should **only** see their own app's namespace. Use Role + RoleBinding (namespace-scoped), not ClusterRole + ClusterRoleBinding.

AD groups per app:
- `onprem-app-brands-api-readers`
- `onprem-app-brands-api-operators`

K8s manifest pattern (one per app namespace):

```yaml
---
# Namespace-scoped reader role (could also use built-in `view`)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-reader
  namespace: enterprise         # brands-api lives in enterprise
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "services", "configmaps", "events", "endpoints"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "replicasets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: brands-api-readers-azure
  namespace: enterprise
subjects:
- kind: Group
  name: oidc:<BRANDS_API_READERS_GROUP_OBJECT_ID>
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: app-reader
  apiGroup: rbac.authorization.k8s.io
```

User in `onprem-app-brands-api-readers` group can `kubectl -n enterprise get pods` but **cannot** see other namespaces. Their `kubectl get pods -A` returns only what they can read.

Generate these manifests programmatically via Kustomize/Helm so onboarding a new app namespace is consistent.

### Pattern 3 — Time-bounded elevated access (JIT via Azure AD PIM)

For "needs to be cluster-admin for an hour to debug a prod issue" — don't put people permanently in `onprem-platform-admins`. Use Azure AD **Privileged Identity Management (PIM)**:

1. Configure `onprem-platform-admins` as an "eligible" group in PIM.
2. User in PIM has eligibility but no active membership.
3. To get admin: user requests activation in Azure AD portal → reason + duration (1h, 4h, 8h) → optional approval workflow.
4. PIM activates membership for the requested window, then automatically removes them.
5. Cluster access reflects this in real time (next token refresh, ~5 min lag).

PIM logs every activation in Azure AD audit logs — full breadcrumb trail of who got admin when and why.

Requires Azure AD Premium P2 license. Worth it for cluster admins.

### Pattern 4 — Conditional access (geo / device / MFA enforcement)

Azure AD Conditional Access policies apply at login time, before the JWT is issued. Cluster doesn't see denied users at all.

Examples to consider:

- **Block sign-in from countries we don't operate in.** Trims a huge attack surface.
- **Require compliant device** (Intune-managed laptop). Personal laptops can't get a JWT.
- **Require MFA for `onprem-platform-admins` group.** Even if password is compromised, MFA blocks the login.
- **Require sign-in from corp network OR via VPN.** Combines with the existing 10.10.82.x network restriction for defense in depth.

These are configured by IT/Azure AD admin, not by us — but we can request specific policies for the cluster app.

### Pattern 5 — Read-only by default, write requires explicit elevation

For prod, default everyone to read-only. Treat write access as an exception that requires:

1. A justification (Slack thread, ticket).
2. Explicit AD group addition (or PIM activation).
3. Audit trail of when and why.

Concretely: only ~3-5 people in `onprem-platform-operators`. The rest are in `onprem-platform-readers`. App teams in their namespace-scoped reader groups.

### Pattern 6 — Audit and quarterly review

Same as the bridge process, but the source of truth is now Azure AD group membership:

```bash
# List who has cluster-wide read (via OIDC)
# This shows the GROUP NAME from the binding — actual members live in Azure AD
kubectl get clusterrolebinding onprem-platform-reader-azure -o jsonpath='{.subjects}'

# Cross-reference: in Azure AD portal or via Microsoft Graph CLI
az ad group member list --group "onprem-platform-readers" --output table
```

Quarterly: walk the Azure AD group memberships against the team roster. Remove orphans. Document the review.

### Quick-reference: AD group → K8s permission matrix

Document this as a table in your platform wiki so people know what to ask for:

| Need | Ask for | What it grants |
|---|---|---|
| "I want to look at platform components for debugging" | `onprem-platform-readers` | Read-only cluster-wide, no secrets |
| "I'm on the on-prem team and operate the platform" | `onprem-platform-operators` | Read everything + write non-system resources |
| "I'm on the on-prem core team" (rare) | `onprem-platform-admins` (PIM eligible) | cluster-admin, time-bounded |
| "I'm an app developer for X" | `onprem-app-X-readers` | Read-only in app's namespace |
| "I'm an app on-call for X" | `onprem-app-X-operators` | Read + restart pods + edit configmaps in app's namespace |

---

## Migration plan (cert-based → OIDC)

Once OIDC is configured and tested, retire cert-based access in two phases:

**Phase A — Both auth methods active (transition period, ~2 weeks)**
- OIDC works for users in the right AD groups.
- Existing cert users still work.
- All new onboarding goes through OIDC.
- Document outage rollback plan: if OIDC breaks, cert-based admin kubeconfigs are the break-glass.

**Phase B — Cert-based deprecated**
- Notify all cert users 30 days in advance.
- They re-onboard via the OIDC flow (5-min self-serve).
- Once everyone's confirmed working on OIDC, delete the cert-based ClusterRoleBindings.
- Remove the OIDC-irrelevant `oidc:` prefix isn't strictly needed but kept for clarity.
- The cert-based flow stays in this runbook as **break-glass-only** (e.g., when Azure AD itself is down — use cert from offline backup to recover).

### Break-glass plan

Always keep ONE cert-based admin kubeconfig stored offline (in a sealed envelope, in a safe, with quarterly rotation reminder). If Azure AD is unreachable and the cluster needs urgent operation, this is the recovery path. Don't keep it on a laptop or in cloud storage.

---

## When to file the OIDC project ticket

This runbook is the source of truth for both the bridge and the target. The actual implementation is a 1–2 week platform project (per phase 1–4 above). File an INFRA ticket scoped to:

- Azure AD app registration
- Talos machineconfig OIDC flags
- RBAC group bindings
- kubelogin setup docs for users
- Migration of existing cert users

Best done **after** the on-prem POC apps stabilize (so we're not changing auth + rolling out new apps simultaneously).

---

## Quick reference

| Action | Command |
|---|---|
| One-time ClusterRole apply | `kubectl apply -f -` with the YAML in [§ One-time cluster setup](#one-time-cluster-setup) |
| Sign a CSR | `kubectl apply` CSR with `expirationSeconds: 31536000` + `kubectl certificate approve <name>` |
| Bind a user | `kubectl create clusterrolebinding onprem-platform-reader-<USER_CN> --clusterrole=onprem-platform-reader --user=<USER_CN>` |
| Revoke a user | `kubectl delete clusterrolebinding onprem-platform-reader-<USER_CN>` |
| List bindings | `kubectl get clusterrolebindings -l purpose=per-user-cluster-access` (if you label them) |
| Check cert dates | `openssl x509 -in <USER_CN>.crt -noout -dates` |

---

## Audit and verification

After every provisioning, verify on the cluster:

```bash
# The CSR was approved and issued
kubectl get csr <USER_CN>
# CONDITION should be: Approved,Issued

# The binding exists
kubectl get clusterrolebinding onprem-platform-reader-<USER_CN>

# The user is in the binding
kubectl describe clusterrolebinding onprem-platform-reader-<USER_CN> | grep "Name:"

# Optional — check audit logs for first activity
# (depends on your audit log destination — CloudWatch, S3, file)
# Look for: user.username: <USER_CN>
```

Periodically (quarterly) audit the list of users:

```bash
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.metadata.name | startswith("onprem-platform-reader-")) | "\(.metadata.name)\t\(.subjects[0].name)"'
```

Cross-reference against current team roster. Revoke any orphans.

---

## Maintenance

This runbook is the source of truth. When a step changes (e.g., new ClusterRole resource added, OIDC migration starts), update this file and commit. Don't let runbooks rot in tribal knowledge.
