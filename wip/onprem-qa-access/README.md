# On-prem QA cluster access — group-based model (Idris → Platform Admin)

**Cluster:** `op-usxpress-qa` — Talos, `https://10.10.82.51:6443` (vLAN 82; dev `.50` / qa `.51` / prod `.52`)
**Ask:** give Idris Platform Admin on QA, mirroring how Timothy Preble got AWS prod EKS access on 2026-07-27.
**Status:** drafted 2026-07-28 — nothing applied. All execution is on WSL (corp VPN required).

---

## 1. What "same as Tim" can and cannot mean here

Tim's grant was: **assign the `v-prod` AWS SSO permission set → done.** No cluster change at all, because
`kube-system/aws-auth` already maps that permission-set role → the K8s group `view`, and the group is already
bound to ClusterRoles. Identity lives in Entra→Identity Center; the cluster only knows about *groups*.

On-prem cannot do that today. **op-usxpress-qa has no OIDC on kube-apiserver** — the runbook's Azure AD flow is
documented target state, unimplemented. So there is no "add him to a group in the IdP and walk away" path yet.

What we *can* mirror is the half that actually matters, and the half the current runbook gets wrong:

| | Tim / AWS EKS | On-prem QA today (this pack) | On-prem QA after OIDC |
|---|---|---|---|
| Identity | Entra → Identity Center | X.509 cert, user-generated key | Entra JWT |
| **Group carried by the credential** | permission-set role | **cert subject `O=onprem-platform-admins`** | `groups` claim |
| **Binding** | **pre-existing, group-keyed** | **pre-existing, group-keyed (this pack)** | same bindings, `oidc:` subject added |
| Ops per new user | 0 cluster changes | sign a CSR (no cluster changes) | 0 cluster changes |

The change vs. the existing runbook: the runbook creates **one ClusterRoleBinding per person**
(`onprem-platform-reader-<USER_CN>`), which is the exact anti-pattern the runbook itself warns about for
aws-auth `mapUsers`. Binding to the **group** in the cert's `O` field means the next platform admin needs a
signed cert and nothing else — and when OIDC lands, the same three bindings get an extra `oidc:` subject and
every cert user cuts over without a re-bind.

**Platform Admin = `cluster-admin`**, per the runbook's own tier table (§ Restricting access → Pattern 1).
That is full access to QA including secrets. Non-prod, and Idris co-owns the on-prem platform, so it's the
right tier — but it is worth saying out loud rather than implying, since QA SM-sourced secrets are readable.

---

## 2. What gets applied

Three tiers, declarative, group-keyed. Committed to Flux so QA rebuilds keep them (the whole INFRA-1589 point
— a hand-applied `kubectl create clusterrolebinding` dies on the next rebuild-to-validate).

| Cert `O=` / future AD group | ClusterRole | Who |
|---|---|---|
| `onprem-platform-admins` | `cluster-admin` (built-in) | on-prem platform core — Idris, Dare |
| `onprem-platform-operators` | `onprem-platform-operator` | write non-system resources, no secrets/RBAC/CRDs |
| `onprem-platform-users` | `onprem-platform-reader` | read-only cluster-wide, no secrets |

`onprem-platform-users` stays the default `O` in every CSR, so anyone with a cert gets read even if their
admin/operator group is later removed. Certs carry multiple `O` values — Idris's is
`/CN=idris-fagbemi/O=onprem-platform-admins/O=onprem-platform-users`.

Files:

- `rbac/` → commit to `iaac-talos-flux-platform`, branch **`op-qa`**, as `infrastructure/rbac/`
- `cluster-kustomization-entry.yaml` → append to `iaac-talos-flux-cluster` `master`,
  `clusters/op-usxpress-qa/flux-system/infra.yaml`
- `sign-csr-qa.sh` → admin-side, run on WSL once Idris sends his CSR
- `IDRIS-MESSAGE.md` → the two blocks to send Idris (CSR generation, then kubeconfig assembly)

---

## 3. Order of operations

**Getting a QA kubeconfig.** `op-usxpress-qa` has **no context in the default kubeconfig and never has** —
`kubectl config use-context op-usxpress-qa` fails, and with `KUBECONFIG` unset kubectl silently falls back to
`localhost:8080`. Derive it from tfstate; stream the state, never save it (plaintext secrets):

```bash
nc -vz -w 5 10.10.82.51 6443            # corp VPN

# Skip if a file already serves .51 — resolve by endpoint, never by filename
for f in ~/.kube/*.yaml; do printf '%-45s %s\n' "$(basename $f)" \
  "$(kubectl --kubeconfig=$f config view -o jsonpath='{.clusters[*].cluster.server}')"; done

aws sso login --profile usx-qa
aws s3 cp s3://lazy-tf-state-425rbol87rmn6c7m/iaac/talos/op-usxpress-qa.tfstate - --profile usx-qa \
  | jq -r '.outputs.kubeconfig.value' > ~/.kube/op-usxpress-qa.yaml && chmod 600 ~/.kube/op-usxpress-qa.yaml

export KUBECONFIG=~/.kube/op-usxpress-qa.yaml
kubectl cluster-info | head -1          # READ IT: .51, not dev's .50
```

That kubeconfig's identity is in `system:masters` — it is what gives you the right to sign CSRs at all.

**Preflight (read-only):**

```bash
kubectl get clusterrole onprem-platform-reader onprem-platform-operator 2>&1
kubectl get clusterrolebindings -o json | jq -r \
  '.items[] | select(.roleRef.name=="cluster-admin") | "\(.metadata.name)\t\(.subjects[]?.kind):\(.subjects[]?.name)"'
kubectl get csr | grep -i idris
```

**Run 2026-07-28 — clean start, no surprises:**

- Neither ClusterRole exists on QA. Nothing hand-applied to adopt; Flux creates all five objects fresh.
  (Had `onprem-platform-reader` existed, Flux would have adopted it — same name, no immutable fields.)
- cluster-admin on QA is held only by ServiceAccounts (`cilium-install`, both flux controllers,
  `magerunner-deploy`, `velero`) plus `Group:system:masters`. **No human binding exists.** So
  `onprem-platform-admins` is the first human cluster-admin path into QA — a new door, not a second key.
- No outstanding Idris CSR.

1. **Preflight** above.
2. **Send Idris block 1** from `IDRIS-MESSAGE.md`. He generates key + CSR locally; key never leaves his laptop.
   Nothing here is secret — Teams/Slack is fine.
3. **Commit `rbac/`** to flux-platform `op-qa` + the Kustomization entry to the cluster repo `master`.
   Reconcile, confirm `kubectl get kustomization -n flux-system rbac` is Ready.
   Do this *before* signing — the binding must exist when his cert starts working.
4. **Sign his CSR**: `./sign-csr-qa.sh idris-fagbemi ~/onprem-access/idris-fagbemi.csr`.
   The script refuses to run if the context isn't QA or the CSR subject is wrong.
5. **Send Idris block 2** (signed cert + QA CA + server URL) and he assembles the kubeconfig.
6. **Verify** — see § 5.

Steps 3 and 4 are independent of each other but both must precede 5.

---

## 4. Why the cert must be re-issued for QA

If Idris already has a dev cert, it will not work on QA: each Talos cluster has its own CA, and the QA
apiserver will not validate a cert signed by dev's. He **reuses the same private key** and generates a new
CSR — the QA CSR just adds `O=onprem-platform-admins`. Two kubeconfigs, one key.

---

## 5. Verification (admin side, after step 5)

```bash
# Bindings landed with GROUP subjects, not user subjects
kubectl get clusterrolebinding onprem-platform-admins -o jsonpath='{.subjects}' | jq
# expect: [{"kind":"Group","name":"onprem-platform-admins",...}]

# The CSR was issued, and the cert carries both O values
kubectl get csr idris-fagbemi                       # Approved,Issued
openssl x509 -in ~/onprem-access/idris-fagbemi/idris-fagbemi.crt -noout -subject -dates

# Impersonate to prove the grant without waiting on him
kubectl auth can-i '*' '*' --as=idris-fagbemi --as-group=onprem-platform-admins          # yes
kubectl auth can-i create customresourcedefinitions --as=idris-fagbemi --as-group=onprem-platform-admins  # yes
# and prove the group is what grants it, not the username
kubectl auth can-i '*' '*' --as=idris-fagbemi                                            # no
```

Idris side: `kubectl auth whoami` → `idris-fagbemi` with groups including `onprem-platform-admins`;
`kubectl get nodes` → 13 Ready (3 CP + 5 app + 3 platform + 2 system).

---

## 6. Revocation

Group-keyed bindings change the revocation story — deleting the binding would cut off *every* admin. To
remove one person:

```bash
# Re-issue their cert without the admin O (drops them to reader), or hard-cut:
kubectl delete csr <USER_CN> --ignore-not-found
```

Their existing cert stays cryptographically valid until expiry (1 year) and still carries
`O=onprem-platform-admins` — **RBAC will still honour it**, because the binding is on the group. This is the
one real trade-off vs. per-user bindings, and it is the same trade-off AWS SSO has (revoke at the IdP, not
the cluster). Mitigations, in order of preference:

1. **Land OIDC** (INFRA ticket per runbook § When to file) — then revocation is an Entra group removal and
   takes effect on next token refresh (~5 min). This is the actual fix.
2. Until then: shorten admin-tier certs to **90 days** (`expirationSeconds: 7776000`, already the default in
   `sign-csr-qa.sh` for the admin tier) so a stale admin cert expires in a quarter, not a year.
3. Emergency: roll the cluster CA (disruptive — break-glass only).

Track issued admin certs in this file's table below so quarterly review has something to walk.

| CN | Tier | Issued | Expires | Notes |
|---|---|---|---|---|
| idris-fagbemi | admin | _pending_ | _pending_ | INFRA-????, this pack |

---

## 7. Open items

- **Runbook is dev-only.** `docs/runbooks/onprem_cluster_access_runbook.md` hardcodes `10.10.82.50` throughout
  and documents per-user bindings. It needs a cluster matrix + the group model folded in, or QA/prod will be
  provisioned by copy-paste against the wrong VIP.
- **OIDC is still unbuilt** and is now the blocker for clean revocation, not just for onboarding convenience.
  Worth filing off the back of this.
- **Prod (`10.10.82.52`)**: same three manifests, `op-prd` branch. Do not reuse the QA-signed cert — different CA.
  Prod should almost certainly *not* have a standing `onprem-platform-admins` binding; PIM-style JIT or
  operator-tier-by-default is the right call there.
