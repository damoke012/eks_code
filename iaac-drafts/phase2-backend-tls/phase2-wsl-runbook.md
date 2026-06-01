# Phase 2 — Backend TLS WSL runbook (INFRA-1495)

**Prereqs (verify before starting)**:
- Phase 1 cleanups PR merged (`flux-followup-cleanup/`) — Gateway + VS now Flux-managed
- `kubectl get cert -n istio-ingress` shows wildcard cert Ready=True (Phase 0)
- `kubectl get clusterissuer letsencrypt-prod` Ready=True
- RW-2 `Running=True` (`kubectl get rw -n risingwave-2`)

## Step 0 — Decision: Option A or B

```bash
# Operator version
kubectl get risingwave -n risingwave-2 -o jsonpath='{.items[0].spec.image}{"\n"}'

# Check operator changelog / sslConfig support. Tentative cutoff: v0.1.36.
# Pick A if version supports sslConfig; B otherwise.
```

Record the decision before continuing.

## Step 1 — Issue the cert (both options)

```bash
cd ~/repos/iaac-risingwave-2  # or wherever
git fetch origin
git checkout main
git pull --ff-only
git checkout -b feat/phase2-rw2-frontend-tls

# Copy the Certificate manifest
cp ~/eks_code/iaac-drafts/phase2-backend-tls/certificate.yaml \
   manifests/op-usxpress-dev/certificate.yaml

# If a kustomization.yaml exists, add the new file to resources:
ls manifests/op-usxpress-dev/
```

Commit + open the Cert-only PR first (split from the TLS-enable change):

```bash
git add manifests/op-usxpress-dev/certificate.yaml \
        manifests/op-usxpress-dev/kustomization.yaml  # only if edited

git commit -m "Phase 2 (INFRA-1495): cert-manager Certificate for rw2-sql

Issues LE-prod cert via DNS01 (cert-manager IRSA chain from Phase 0).
Standalone — cert can exist before TLS terminator is wired up."

git push -u origin feat/phase2-rw2-frontend-tls
gh pr create --base main --title "Phase 2 (INFRA-1495): cert-manager Certificate for rw2-sql" --body "Issues cert-manager Certificate for rw2-sql.op-dev.usxpress.io via letsencrypt-prod. Standalone — TLS enable lands in a follow-up PR."
```

After merge + Flux reconcile:

```bash
flux reconcile source git iaac-risingwave-2 --timeout 2m
flux reconcile kustomization risingwave-2 --timeout 5m
kubectl -n risingwave-2 get cert rw2-sql-tls -w
# Wait for Ready=True. Typical DNS01 challenge takes 30-90s.

kubectl -n risingwave-2 get secret rw2-sql-tls
# Confirm tls.crt + tls.key present.
```

## Step 2A — Enable native TLS (if Option A)

```bash
# Open second PR with the CR patch
git checkout main && git pull
git checkout -b feat/phase2-rw2-enable-tls

# Edit the RW CR file in iaac-risingwave-2 — add the sslConfig block:
#   spec.frontend.sslConfig: { enabled: true, secretName: rw2-sql-tls }
# Reference: rw-cr-tls-patch-native.yaml

git diff manifests/op-usxpress-dev/risingwave.yaml  # or wherever the CR lives
git add manifests/op-usxpress-dev/risingwave.yaml
git commit -m "Phase 2 (INFRA-1495): enable frontend TLS on risingwave-2

References rw2-sql-tls Secret created by cert-manager Certificate.
After merge: operator restarts frontend with TLS-terminating listener on 4567."
git push -u origin feat/phase2-rw2-enable-tls
gh pr create --base main --title "Phase 2 (INFRA-1495): enable frontend TLS on risingwave-2"
```

## Step 2B — Deploy ghostunnel sidecar (if Option B)

```bash
git checkout main && git pull
git checkout -b feat/phase2-rw2-ghostunnel

cp ~/eks_code/iaac-drafts/phase2-backend-tls/ghostunnel-sidecar.yaml \
   manifests/op-usxpress-dev/ghostunnel-frontend.yaml

# Update the Gateway VS to route to the new Service:
#   VS destination: ghostunnel-rw2-sql.risingwave-2.svc instead of risingwave-frontend.risingwave-2.svc
# Edit the cleanup-PR-merged virtualservice-rw2-sql.yaml in iaac-talos-flux-platform.

git add manifests/op-usxpress-dev/ghostunnel-frontend.yaml manifests/op-usxpress-dev/kustomization.yaml
git commit -m "Phase 2 (INFRA-1495): ghostunnel TLS sidecar for rw2-sql"
git push -u origin feat/phase2-rw2-ghostunnel
gh pr create --base main --title "Phase 2 (INFRA-1495): ghostunnel TLS sidecar for rw2-sql"
```

Plus a tiny PR on `iaac-talos-flux-platform` swapping the VS destination host.

## Step 3 — Smoke test (after merge + reconcile)

```bash
# Wait for rollout
kubectl -n risingwave-2 rollout status deployment ghostunnel-rw2-sql --timeout=5m   # Option B
# OR
kubectl -n risingwave-2 rollout status statefulset risingwave-frontend --timeout=5m # Option A

# TLS handshake should now COMPLETE — no errno=104
openssl s_client -servername rw2-sql.op-dev.usxpress.io \
  -connect rw2-sql.op-dev.usxpress.io:4567 \
  -showcerts </dev/null 2>&1 | sed -n '/Certificate chain/,/Server certificate/p'
# Expect: cert chain with CN=rw2-sql.op-dev.usxpress.io, issuer = Let's Encrypt R10/R11

# psql end-to-end (need RW super-user creds from AWS SM / cluster secret)
psql 'host=rw2-sql.op-dev.usxpress.io port=4567 sslmode=require dbname=dev' -c "SELECT version();"
```

## Step 4 — Close INFRA-1495

```bash
# Closing comment + transition. add-jira-comment helper or via UI.
python3 ~/eks_code/scripts/add-watcher.py --account-id ... INFRA-1495  # already a watcher; skip
# Use the jira-comment helper (similar to add-watcher) to post closure:
```

Closure comment template (paste into INFRA-1495):

```
Phase 2 complete 2026-MM-DD.

* cert-manager Certificate rw2-sql-tls issued by letsencrypt-prod (DNS01 via cert-manager IRSA chain). Ready=True.
* Backend TLS enabled via {Option A native RW sslConfig | Option B ghostunnel sidecar}.
* openssl s_client -servername rw2-sql.op-dev.usxpress.io -connect ...:4567 completes full TLS handshake.
* psql sslmode=require connects + queries.
* RW-2 Running=True throughout; Tim's risingwave ns untouched.

Phase 3 (INFRA-1496 — CIDR allow-list) next; still gated on Steve Duck CIDR list.
```

## Rollback per option

| Failure | Option A rollback | Option B rollback |
|---|---|---|
| TLS handshake fails | Revert PR enabling sslConfig | Delete ghostunnel Deployment + Service; revert VS destination host |
| RW-2 frontend crashloop | Revert PR | N/A — RW frontend untouched in Option B |
| Cert renewal failure | cert-manager renews independently; check ClusterIssuer + DNS01 challenge logs | same |
