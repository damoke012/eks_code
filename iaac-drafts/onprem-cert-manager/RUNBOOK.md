# Phase 0 — cert-manager + IRSA + wildcard cert RUNBOOK

**Ticket:** INFRA-1493 (sub-task of [INFRA-1492](https://usxpress.atlassian.net/browse/INFRA-1492))
**Design doc:** [`docs/designs/tcp-sni-ingress-design.md`](../../docs/designs/tcp-sni-ingress-design.md)

This shows the apply order, smoke tests, and rollback. Each step is reversible.

---

## Pre-flight (WSL — codespace can't reach cluster)

```bash
# 1. Confirm no existing cert-manager
kubectl get crd certificates.cert-manager.io 2>/dev/null
kubectl get clusterissuer -A 2>/dev/null
kubectl get hr -n flux-system cert-manager 2>/dev/null

# If any of the above returns existing resources, STOP and decide
# replace-vs-reuse before proceeding. We do NOT want two cert-managers.

# 2. Confirm IRSA prereqs
kubectl get deploy -n external-secrets pod-identity-webhook
kubectl -n external-secrets get pods -l app=pod-identity-webhook
```

## Step 1 — IAM role (Terraform via Octopus, iaac-talos)

PR the two TF files (`cert-manager-role.tf` + `cert-manager-output.tf`) into
`iaac-talos/deploy/terraform/modules/irsa/`. Confirm release in Octopus.

**TfApply discipline** (per [feedback_no_manual_cicd_shortcuts]):
1. Octopus variable `TfApply = false` → release runs `terraform plan`. Review plan.
2. Plan looks right → set `TfApply = true`, redeploy → applies.
3. **Flip back `TfApply = false`** immediately after success.

Verify post-apply:

```bash
aws iam get-role --role-name cert-manager-op-usxpress-dev \
  --profile usx-dev --region us-east-2 \
  --query 'Role.Arn'
# → arn:aws:iam::700736442855:role/cert-manager-op-usxpress-dev
```

## Step 2 — cert-manager HelmRelease (Flux, iaac-talos-flux-platform op-dev)

Place the three files under `infrastructure/cert-manager/`:

- `namespace.yaml`
- `repository.yaml`
- `release.yaml`

And the ClusterIssuers under `infrastructure/cert-manager-issuers/`:

- `letsencrypt-staging.yaml`
- `letsencrypt-prod.yaml`

PR to op-dev branch. After merge:

```bash
flux reconcile source git infra
flux reconcile kustomization cert-manager

kubectl -n cert-manager get pods
kubectl -n cert-manager logs deploy/cert-manager | grep -i 'irsa\|aws\|sts' | head -20

# Verify IRSA actually wired
kubectl -n cert-manager get sa cert-manager -o jsonpath='{.metadata.annotations}'
# Should show eks.amazonaws.com/role-arn: arn:aws:iam::700736442855:role/cert-manager-op-usxpress-dev
```

## Step 3 — Add Flux Kustomization entries (iaac-talos-flux-cluster master)

Paste the two Kustomization blocks from `cluster-kustomization-snippet.yaml`
into `clusters/bm-dev/flux-system/infra.yaml`. PR + merge. `flux reconcile`.

## Step 4 — STAGING smoke test (CRITICAL — do not skip)

```bash
# 1. Apply staging ClusterIssuer (Flux already did this if Step 3 succeeded; verify)
kubectl get clusterissuer letsencrypt-staging
kubectl describe clusterissuer letsencrypt-staging | tail -20
# Expect: Ready=True, "registered ACME account" event

# 2. Issue a throwaway cert against STAGING
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: smoketest-staging
  namespace: istio-ingress
spec:
  secretName: smoketest-staging-tls
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
  commonName: smoketest.op-dev.usxpress.io
  dnsNames:
  - smoketest.op-dev.usxpress.io
EOF

# 3. Watch issuance
kubectl -n istio-ingress get certificate smoketest-staging -w
# Ready=True within 2-5 min if Route53 trust is correct.

# 4. Inspect the issued cert (note: STAGING cert is not publicly trusted —
#    that's expected. We're only validating the DNS-01 + role chain works.)
kubectl -n istio-ingress get secret smoketest-staging-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | head -20
```

**If issuance fails:**
- `kubectl describe certificate smoketest-staging -n istio-ingress` → check Order events
- `kubectl describe order -A | grep -A20 smoketest` → check Challenge events
- Common failures:
  - `AccessDenied: User: arn:aws:sts::700736442855:assumed-role/cert-manager-... is not authorized to perform: sts:AssumeRole` → source role trust mis-wired
  - `InvalidChangeBatch` from Route53 → wrong zone or wrong hosted-zone-id (omit hostedZoneID and let cert-manager discover)
  - DNS propagation timeout → Cloud DNS caches; retry after 60s

## Step 5 — Wildcard cert (PROD)

ONLY after Step 4 succeeds:

```bash
# 1. Switch wildcard-op-dev.yaml issuerRef.name → letsencrypt-prod
# 2. Apply
kubectl apply -f wildcard-cert/wildcard-op-dev.yaml

# 3. Watch
kubectl -n istio-ingress get certificate wildcard-op-dev -w
# Ready=True; secret `wildcard-op-dev-tls` populated.

# 4. Verify cert chain
kubectl -n istio-ingress get secret wildcard-op-dev-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout \
  | grep -E '(Subject:|Issuer:|DNS:)'
# Expect Issuer to be Let's Encrypt R3 (or current LE intermediate).

# 5. Clean up staging smoketest
kubectl -n istio-ingress delete certificate smoketest-staging
kubectl -n istio-ingress delete secret smoketest-staging-tls
```

## Rollback

| Step that failed | Rollback |
|---|---|
| Step 1 (IAM role) | Revert TF PR; `TfApply=true` to destroy the role + policy |
| Step 2 (cert-manager HR) | Revert PR; Flux removes HR + namespace (prune=true) |
| Step 3 (Kustomization) | Revert PR; Flux drops the Kustomization (drift detection removes managed resources) |
| Step 4 (staging smoke) | Delete the Certificate manifest; no state to clean up |
| Step 5 (wildcard prod) | Delete Certificate; Secret follows. **Note**: deleting + re-issuing burns LE prod rate limit budget. Avoid the loop. |

## Success criteria for INFRA-1493 closure

- [ ] IAM role `cert-manager-op-usxpress-dev` exists, trust verified
- [ ] cert-manager pods Running with IRSA SA annotation
- [ ] `ClusterIssuer letsencrypt-staging` Ready=True
- [ ] `ClusterIssuer letsencrypt-prod` Ready=True
- [ ] Staging smoke cert issued + cleaned up
- [ ] `Certificate istio-ingress/wildcard-op-dev` Ready=True against PROD issuer
- [ ] `kubectl get rw -n risingwave` Running=True before AND after (no degradation)
- [ ] PRs merged on `feature/op-usxpress-dev` (iaac-talos) and `op-dev` (iaac-talos-flux-platform); confirmed [feedback_iaac_talos_branch_base]

## After closure

- INFRA-1494 (Phase 1 — Gateway TCP listeners + SNI routing) unblocked.
- HTTPS plane for HTTP services can also light up with the same wildcard cert (separate ticket).
