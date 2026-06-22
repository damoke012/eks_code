# external-dns deploy runbook (op-usxpress-dev) — piece 2 of 3

**Cluster**: op-usxpress-dev (Talos, kubectl context `admin@op-usxpress-dev`)
**Executed from**: WSL2 (codespace can't reach the cluster or AWS Route53)
**Protection rule**: any change MUST NOT degrade running RW
(see `memory/feedback_protect_rw_onprem_workload.md`).

**Prereq**: piece 1 (istio-ingressgateway) ideally live with at least one Gateway
resource. Not strictly required — external-dns runs idle until Gateways appear —
but you can't smoke-test resolution without one.

---

## 0. Sanity context check

```bash
kubectl config current-context
# Expect: admin@op-usxpress-dev
aws sts get-caller-identity --profile usx-dev
# Expect: account 700736442855
```

---

## 1. Pre-flight RW protection check

```bash
kubectl get rw risingwave -n risingwave
kubectl get pods -n risingwave --no-headers | awk '$2 != "1/1" && $2 != "0/1"'
PGPASSWORD='WLThdeIQznAJ9RxSdWV3SaCFMY1yFjO1' \
  psql -h 10.10.82.26 -p 32567 -U root -d dev -c 'SELECT 1;'
kubectl -n risingwave get svc -o wide | grep NodePort
```

Save outputs for post-flight diff.

---

## 2. Apply Terraform (source IAM role in 700736442855)

In WSL:

```bash
cd ~/work/iaac-talos
git checkout feature/irsa   # or whatever active op-usxpress-dev branch
git pull --ff-only

# Append the two snippets from this artifact bundle:
# - iam/extd-usxpress-io-role.tf    -> deploy/terraform/modules/irsa/main.tf
# - iam/extd-usxpress-io-output.tf  -> deploy/terraform/modules/irsa/outputs.tf

cd deploy/terraform
terraform init   # if not already
terraform plan -out plan.bin
# Expect plan to show: + aws_iam_role.extd_usxpress_io
#                     + aws_iam_role_policy.extd_usxpress_io_assume
#                     + output.extd_usxpress_io_role_arn
terraform apply plan.bin

# Capture the role ARN
terraform output extd_usxpress_io_role_arn
# Expect: arn:aws:iam::700736442855:role/op-usxpress-dev-extd-usxpress-io
```

Commit the Terraform changes once apply succeeds:
```bash
git add deploy/terraform/modules/irsa/
git commit -m "feat(irsa): add extd-usxpress-io source role for on-prem external-dns"
git push
```

---

## 3. ~~Send trust-extension ask~~ — SKIPPED (no patch needed)

Verified 2026-05-18: trust policy on `iaac-route53-zone` already accepts any
role matching `extd-usxpress-io-*` from the USXpress AWS Org. Our role is
named `extd-usxpress-io-op-usxpress-dev` — matches the pattern.

**Verify (once the role exists post-step-2)** — run from WSL:

```bash
# Once `extd-usxpress-io-op-usxpress-dev` is created in 700736442855, you can
# AssumeRoleChain to verify the full path works. Use a CLI test:
aws sts assume-role \
  --role-arn arn:aws:iam::700736442855:role/extd-usxpress-io-op-usxpress-dev \
  --role-session-name verify-chain \
  --profile usx-dev 2>&1 | head -5

# Then with those creds, chain into the Route53 role:
# (Or simpler — just run external-dns and watch the pod logs.)
```

If `external-dns` pod logs ever show `AccessDenied`, double-check the source
role's name in IAM matches the deployed Helm chart's `eks.amazonaws.com/role-arn`
annotation, AND that the role's permissions include `sts:AssumeRole` on
`arn:aws:iam::155768531003:role/iaac-route53-zone`.

---

## 4. Commit + push Flux manifests

```bash
# A. Platform repo — external-dns manifests
cd ~/work/iaac-talos-flux-platform
git checkout op-dev && git pull --ff-only origin op-dev
mkdir -p infrastructure/external-dns
# Copy 3 yaml files from onprem_external_dns_iaac/infrastructure/external-dns/
git add infrastructure/external-dns
git commit -m "feat(external-dns): deploy extd-usxpress-io with cross-account Route53"
git push origin op-dev

# B. Cluster repo — Kustomization wiring
cd ~/work/iaac-talos-flux-cluster
git checkout master && git pull --ff-only origin master
# Append the snippet from onprem_external_dns_iaac/cluster-kustomization-snippet.yaml
# into clusters/bm-dev/flux-system/infra.yaml
git diff clusters/bm-dev/flux-system/infra.yaml
git commit -am "feat(bm-dev): wire external-dns kustomization"
git push origin master
```

---

## 5. Watch Flux reconcile

```bash
flux reconcile source git infra
flux reconcile kustomization external-dns

kubectl get ks -n flux-system external-dns -w
# Expect: READY=True within ~5m
kubectl get hr -n flux-system extd-usxpress-io
kubectl get pods -n external-dns -o wide
# Expect: pod Running 1/1

# CRITICAL: check IRSA worked
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=50
# Expect: log lines about loading sources, "All records are already up to date" eventually
# RED FLAG: any AccessDenied / NoCredentialProviders / WebIdentity errors → step 3 incomplete
```

---

## 6. Post-flight RW protection check

Re-run all four commands from §1. All values must match baseline.

If RW degraded → execute §8 Rollback.

---

## 7. Smoke test — DNS resolution

Assuming piece 1 is live AND `enterprise/brands-api` Gateway exists from piece 1
smoke test, external-dns should have created a Route53 A record by now.

```bash
# Allow up to 2x the external-dns interval (~5min) for first record write
sleep 60

# Check DynamoDB registry (proves external-dns is the owner)
aws dynamodb scan --table-name <registry-table-name> --region us-east-2 \
  --filter-expression "OwnerID = :o" \
  --expression-attribute-values '{":o":{"S":"iaac-talos/us-east-2/op-usxpress-dev"}}' \
  --profile usx-dev | head -30
# Expect: at least one Item with k=api.brands.dev.usxpress.io / our owner ID
# (table name visible in extd-usxpress-io pod logs at first registry init)

# Check Route53 directly
aws route53 list-resource-record-sets \
  --hosted-zone-id <usxpress.io-zone-id> \
  --query "ResourceRecordSets[?Name=='api.brands.dev.usxpress.io.']" \
  --profile usx-dev
# Expect: A record pointing at worker IP(s) like 10.10.82.26

# DNS resolution from VPN
dig +short api.brands.dev.usxpress.io
# Expect: one or more worker IPs (10.10.82.26, .27, .28, .178, .180)

# Full end-to-end (was raw IP, now hostname)
curl -v http://api.brands.dev.usxpress.io/
# Expect: same brands-api response as piece 1 smoke test, but via DNS now
```

---

## 8. Rollback

### Rolling back just the DNS records (safest)

```bash
# Suspend the HelmRelease — pod stops writing/deleting records but registry is preserved
flux suspend hr extd-usxpress-io -n flux-system
# Records stay in Route53 until you manually clean OR un-suspend with policy=upsert-only
```

### Full removal

```bash
cd ~/work/iaac-talos-flux-cluster
git revert HEAD
git push origin master
flux reconcile kustomization external-dns
# Kustomization prunes; namespace external-dns deletes.

# Records left in Route53 after pod is gone — clean manually if needed:
# - Find records where TXT/owner matches our txtOwnerId
# - Delete via console or `aws route53 change-resource-record-sets`
```

### Revoking the IAM role / trust patch

If something is badly wrong:
- terraform destroy targeting `aws_iam_role.extd_usxpress_io` from iaac-talos
- Network team removes the trust statement from `iaac-route53-zone`

---

## 9. Next steps (NOT part of this deploy)

- **DNS naming convention** — confirm with team. Today the orphan VSes are mixed
  (`api.brands.dev.usxpress.io` vs `geoservices.geoenrichment-sync-handler.dev.usxpress.io`).
  Define convention BEFORE wiring more.
- **Piece 3 (cert-manager public ClusterIssuer)** — gives HTTPS via DNS-01.
  DNS-01 needs DNS to work — that's now.
- **File ONPREM-25 in Jira** (currently a local planning doc only) — needed to
  give the network team a tracking artifact for the trust patch.
- **Add a second `external-dns` deployment for internal-only zone** (cloud has
  one) — only if we identify the need; on-prem may not for now.

---

## Troubleshooting cheatsheet

| Symptom | Likely cause | Action |
|---|---|---|
| Kustomization NotReady, helm error about CRDs | First-time install needs CRDs created | `install.crds: CreateReplace` is set; check helm logs |
| Pod Pending | nodeSelector mismatch | We removed cloud's `iaac=true / arm64` nodeSelector; verify with `kubectl describe po` |
| Pod CrashLoopBackOff with `WebIdentityErr` | IRSA broken (OIDC issuer, SA annotation, role trust) | `kubectl describe sa extd-usxpress-io -n external-dns`; verify role-arn annotation matches Terraform output |
| Pod Running but `AccessDenied` on AssumeRole | Network-team trust patch not applied (§3) | Confirm with `aws sts assume-role` from WSL |
| Records not appearing in Route53 | Gateway resource missing the host OR `domainFilters` mismatch | Check Gateway `spec.servers[].hosts`; confirm host is under `usxpress.io` |
| dig returns NXDOMAIN | Route53 propagation OR wrong resolver | Try `dig @8.8.8.8`, then `aws route53 list-resource-record-sets` to verify record presence |
| Records appearing but DELETED constantly | txtOwnerId collision with cloud | Verify our pod uses `iaac-talos/us-east-2/op-usxpress-dev`; check DynamoDB items have our OwnerID |
| RW psql fails post-deploy | Something broke RW — STOP, rollback | Execute §8 |
