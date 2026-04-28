# On-Prem Cluster Access — Provisioning Runbook

**Cluster:** op-usxpress-dev (Talos, https://10.10.82.50:6443)
**Audience:** Cluster admins onboarding new users (engineers, contractors, vendors)
**Last revised:** 2026-04-28

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

## One-time cluster setup

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

## Future state — Azure AD OIDC

The current flow requires manual ops per user. The destination is **OIDC against the USXpress Azure AD tenant**:

1. Configure Talos kube-apiserver with OIDC pointing at Azure AD.
2. User installs `kubectl oidc-login` plugin.
3. They run `kubectl get nodes` → browser opens → they auth with USXpress AD → kubectl gets a JWT → cluster trusts the JWT.
4. RBAC binds against AD groups (e.g., `onprem-platform-readers` AD group → `onprem-platform-reader` ClusterRole).

Add/remove people from the AD group → cluster access changes automatically. No CSR ops, no per-user kubeconfigs.

This is on the platform backlog. Until it lands, this runbook is the operational standard.

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
