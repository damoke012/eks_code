# BeyondTrust impact audit — cloud + CICD + Octopus + Terraform + on-prem

**Date:** 2026-06-08
**Owner:** Doke (Cloud Platform / On-prem)
**Audience:** internal + Christopher Matthews (cybersec) for scoping confirmation
**Status:** AWS audit complete; on-prem kubectl probe pending

## Executive summary

BeyondTrust PAM rollout (phase 2 = humans get `_ELEV` accounts, 7-day password rotation) lands on top of an environment that is **structurally clean** for the workload identity surface — but the deep IAM audit (Block A) uncovered **three pre-existing critical findings** that warrant cleanup independent of BeyondTrust scope:

### Structural cleanliness (good signal)
- **Zero** `aws_iam_user` or `aws_iam_access_key` resources in any cloned IaC repo
- **Zero** `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars in any helm manifest, workflow, or kubernetes Secret
- **All** cloud + on-prem workloads use IRSA (web-identity to OIDC provider)
- **All** GHA workflows that touch AWS use `aws-actions/configure-aws-credentials@v4` + `role-to-assume:` (OIDC), never static keys

### Pre-existing critical findings (not BeyondTrust-caused, but BeyondTrust-adjacent)
- **`serverless-test` (data-dev)** holds `AdministratorAccess` on an active key, last used 2022-09. Abandoned admin identity.
- **`analyst_test` (usx-qa)** created 2026-01-27 with `AmazonS3FullAccess` — key NEVER authenticated. Phantom identity.
- **`bolei-test` (data-dev)** — human-named, 4-year stale.

### BeyondTrust phase 2 itself
- 11 IAM users have static keys across 4 of 7 USX accounts. Of those, 2 are hot today (`svc_mulesoft_prod` in PROD, `svc_confluentbridge_dev` in usx-dev), 2 are rotation-stuck, 3 are over-permissioned, and the rest are cleanup candidates.
- All 11 were created out-of-band (console click-ops), not GitOps-tracked.
- Recommended pilot account: `infra-playground` (786...) — zero IAM users, one GHA OIDC role, no production workload.

## Methodology

1. **AWS API audit** across all 8 SSO profiles (`infra-common`, `data-dev`, `ops-controller`, `infra-playground`, `playground`, `usx-dev`, `usx-qa`, `network`) → output: `~/work/beyondtrust-audit/audit-20260608-1628.txt` on WSL2
2. **Code sweep** across 12 cloned IaC repos for: `aws-actions/configure-aws-credentials`, `AWS_ACCESS_KEY_ID`, `role-to-assume:`, `AWS_PROFILE`, `eks.amazonaws.com/role-arn`, `access_key`, `secret_key`, `assume_role`, `sts:AssumeRole`, `aws_iam_user`, `aws_iam_access_key`
3. **Mage-runner source dive**: Go code, GHA workflows, deployment manifests, README
4. **On-prem IRSA module review**: `iaac-talos/deploy/terraform/modules/irsa/main.tf`

Repos covered: `amazon-eks-pod-identity-webhook`, `iaac-flux-manifests`, `iaac-monitoring`, `iaac-octopus-overrides`, `iaac-risingwave-cicd`, `iaac-talos-flux-cluster`, `iaac-talos-flux-platform`, `iaac-talos`, `ix-kafka-topics-users`, `mage-runner`, `mongo-edi-cluster`, `terraform-irsa-roles`.

## Findings

### Tier 1 — IAM users + access keys (BeyondTrust-relevant) — enriched with Block A LastUsed + policy data

| Account | Profile | User | Key created | Last used (key) | Policies attached | Tier |
|---|---|---|---|---|---|---|
| 854762601885 | data-dev | `serverless-test` | 2022-09 | **2022-09-13 (stale)** | `AdministratorAccess` | **CRITICAL — delete** |
| 527101283767 | usx-qa | `analyst_test` | 2026-01 | **NEVER (N/A)** | `AmazonS3FullAccess` | **CRITICAL — delete** |
| 854762601885 | data-dev | `bolei-test` | 2022-03 | **2022-03-09 (4yr stale)** | custom `test-bolei` | **CRITICAL — delete** |
| 527101283767 | usx-qa | `svc-gcr-s3-qa` | 2025-09 | 2026-06-07 (hot) | s3 on `*/*` (over-broad) | **HIGH — scope down** |
| 700736442855 | usx-dev | `svc-mulesoft-dev` | (1) 2022, (2) 2024-01 | (1) 2026-06-04 hot; (2) **NEVER** | `S3BucketAccessReadWrite` + narrow SM | **HIGH — deactivate key #2** |
| 527101283767 | usx-qa | `svc-mulesoft-qa` | (1) 2022, (2) 2022 | (1) **2023-01-18 (stale)**; (2) 2026-05-01 | narrow S3 mule-logs + narrow SM | **HIGH — deactivate key #1** |
| 937464026810 | **PROD** | `svc_mulesoft_prod` | 2022-08 | **2026-06-08 (today)** | narrow s3 mule-logs + 1 narrow SM secret | MEDIUM — long-term IRSA/federated plan |
| 700736442855 | usx-dev | `svc_confluentbridge_dev` | 2022-03 | **2026-06-08 (today)** | 4 narrow Kafka/Confluent SM secrets | MEDIUM — long-term plan |
| 064859874041 | infra-common | `test-octopus` | 2025-01 | 2025-03-20 | `AmazonS3FullAccess` (over-broad) | LOW — scope down or delete |
| 854762601885 | data-dev | `github-workflow-user` | 2021-09 | 0 active keys | ECR + Lambda (idle) | LOW — cleanup |
| 700736442855 | usx-dev | `svc_config_mgmt` | 2024-02 | no recent key activity | `SecretsManagerReadWrite` | LOW — review |

**Zero IAM users in**: 786352483360 (playground), 155768531003 (network) → all SSO-only.

**Critical pattern**: 3 of the 11 users have over-broad managed policies (`AdministratorAccess`, `AmazonS3FullAccess` ×2, `AmazonS3FullAccess` on test-octopus). Independent of BeyondTrust, these warrant immediate review.

### Tier 2 — IaC sweep (cloud + on-prem)

| Pattern searched | Result |
|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (any file) | **0 hits** |
| `aws_iam_user` (Terraform resource) | **0 hits** |
| `aws_iam_access_key` (Terraform resource) | **0 hits** |
| `name: AWS_ACCESS_KEY_ID` (pod env var) | **0 hits** |
| `access_key` / `secret_key` (yaml/tf/go) | **0 hits** |
| Kubernetes Secrets containing AWS creds | **0 of 9 inspected** |
| `eks.amazonaws.com/role-arn` (IRSA annotation) | 30+ hits — every cloud platform component |
| `aws-actions/configure-aws-credentials@v4` | 4 workflows (all use `role-to-assume:`) |
| `sts:AssumeRoleWithWebIdentity` (Terraform trust policy) | 5 modules (all IRSA web-identity) |

### Tier 3 — Mage-runner auth chain

| Phase | Mechanism | BeyondTrust verdict |
|---|---|---|
| Build / publish (GHA `package-push.yml`) | Runner: `ubuntu-latest` (GitHub-hosted) + `id-token: write` + `variant-inc/actions-collection/s3-package-push@v2`. No `aws_access_key_id` env; action invokes inline OIDC assume-role | Clean (verify `s3PackagePush.ps1` if Christopher asks for 100%) |
| Runtime cloud | IRSA via `iaac-octopus-worker-{cluster}`; trust = cluster OIDC, sub=`system:serviceaccount:octopus:octopusworker`; permissions = `s3:Get*` on `dx-packages*` + `sts:AssumeRole *` chain | Clean |
| Runtime on-prem | Mirrored: `iaac-octopus-worker-op-usxpress-dev` in `iaac-talos/deploy/terraform/modules/irsa/main.tf` lines 199-264. Same trust pattern via cluster's CloudFront OIDC provider | Clean |
| Local dev | Developer SSO (per README: `assume -x dpl` then sops decrypt `.env`) | **Affected indirectly** — devs running mage-runner locally use SSO; BeyondTrust adds `_ELEV` layer to elevate-needing sessions |

### Tier 4 — DX on-prem GHA workflows (iaac-octopus-overrides)

| Workflow | AWS auth | Role assumed (secret) |
|---|---|---|
| `apply-cloud-rbac.yaml` | OIDC | `${{ secrets.CLOUD_RBAC_APPLY_ROLE_ARN }}` |
| `onboard-app.yaml` | OIDC | `${{ secrets.ONPREM_DEPLOY_ROLE_ARN }}` + `${{ secrets.CLOUD_AWS_PROFILE }}` (profile name only) |
| `onprem-account-bootstrap.yaml` | OIDC | `${{ steps.role.outputs.arn }}` (dynamic) |

**All clean.** Secrets stored in the repo are role ARNs and profile names, not credentials.

### Tier 5 — Octopus + Terraform operations

| Surface | Auth | Verdict |
|---|---|---|
| Octopus Worker (cloud) | IRSA via `iaac-octopus-worker-usxpress-{dev,qa,prod}`, chains via `octopus-usxpress` per-account role | Clean |
| Octopus Worker (on-prem) | Same IRSA pattern on op-usxpress-dev's OIDC provider, references PG account 700736442855 in current annotation | Clean |
| Terraform state backend (cloud) | S3 + DynamoDB lock per cluster, accessed via the running pod's IRSA | Clean |
| Terraform state backend (on-prem MageRunner) | S3 `dpl2-local-test-tfstate` in Playground 786352483360. **DynamoDB locking OFF** (`DYNAMO_DB_TABLE: ""`). Single-engineer pattern. | **Operational risk independent of BeyondTrust** — flag separately |
| GHA OIDC roles enumerated in AWS | `infra-common`: 3 (`eks-github-runner`, `github-runner`, `ops-github-runner`). `infra-playground`/`playground`: 1. `usx-dev`: 2 (Tim's RW pipeline). `usx-qa`, `ops-controller`, `data-dev`, `network`: **0** | PROD has zero GHA OIDC — deploys reach PROD via Octopus IRSA chain, not direct GHA → AWS. Confirm with Jeff. |

### Tier 6 — Cloud monitoring + utility roles

| System | Pattern | Verdict |
|---|---|---|
| Kubecost / Grafana CUR access | `assume_role_arn: arn:aws:iam::660075424663:role/kubecost-cur-access` (CUR data-lake account) | Clean cross-account IRSA |
| Velero | IRSA: `arn:aws:iam::700736442855:role/eks/usxpress-dev/velero-...` | Clean |
| external-dns, ALB controller, cert-manager, cilium, EBS/EFS CSI, ESO, Karpenter | All IRSA via per-cluster role pattern | Clean |
| Kafka topics/users (`ix-kafka-topics-users`) | TF defines IRSA role `connect_build` with `AssumeRoleWithWebIdentity` to cluster OIDC | Clean |

## Impact tier matrix for Christopher

| Tier | Identity class | Count | BeyondTrust verdict |
|---|---|---|---|
| **A** | Long-lived IAM users with active keys | 11 across 4 accounts | **In scope to flag** (Tier 1 table) |
| **B** | IRSA roles (workload identity) | ~120 across 4 EKS + on-prem | **Out of scope — safe** |
| **C** | GHA OIDC roles | 6 total (audit) + 5 referenced via secrets (overrides) | **Out of scope — safe** |
| **D** | Cross-account IRSA / kubecost CUR | 1 | **Out of scope — safe** |
| **E** | SSO permission sets (humans) | `AWSAdministratorAccess` per profile | **Direct target of BeyondTrust phase 2** |
| **F** | Octopus worker IRSA chain | per-cluster | **Out of scope — safe** |
| **G** | Mage-runner runtime IRSA | per-cluster | **Out of scope — safe** |
| **H** | Engineers running mage-runner locally | session-scoped SSO | **Indirect impact** — admin elevation surface |

## Concerns to escalate — REFRAMED after Block A deep audit (2026-06-08 PM)

Block A re-ran each IAM user through `list-attached-user-policies`, `list-user-policies`, `get-user-policy`, `get-access-key-last-used`, and `get-login-profile`. The LastUsed data inverted the priority order I had after Block A — some "stale" keys are hot, and one "test" user has admin.

### CRITICAL — immediate action warranted

#### C1. `serverless-test` (data-dev) — abandoned + `AdministratorAccess`
- Account: 854762601885 (data-dev)
- Attached policy: `arn:aws:iam::aws:policy/AdministratorAccess`
- Key `AKIA4OA6SHWO4NMR7FLX` last used **2022-09-13** (3.7 years stale)
- No console password set
- **Recommendation: delete user + key today.** Independent of BeyondTrust; this is a standalone security finding. Worth flagging to Christopher as "this is what your policy is designed to prevent."

#### C2. `analyst_test` (usx-qa) — created 4 months ago, never used, has `S3FullAccess`
- Account: 527101283767 (usx-qa)
- Attached policy: `arn:aws:iam::aws:policy/AmazonS3FullAccess`
- Key `AKIAXVONPJW3UBCHZ6M3` `LastUsedDate: N/A` (created 2026-01-27 but never authenticated)
- **Recommendation: delete (or owner-confirm + scope down) before BeyondTrust phase 2 begins.**

#### C3. `bolei-test` (data-dev) — human-named, 4yr stale
- Custom policy `test-bolei`
- Key `AKIA4OA6SHWOS4K6TF64` last used **2022-03-09**
- **Recommendation: confirm Bolei dept'd + delete.**

### HIGH — active key with over-broad policy

#### H1. `svc-gcr-s3-qa` (usx-qa) — hot key, S3 on `*/*`
- Last used 2026-06-07 (sts in us-west-2)
- Policy resource scope: `arn:aws:s3:::*/*` — any S3 bucket in account 527101283767
- **Recommendation: narrow policy to specific buckets / accesspoints before BeyondTrust phase 2.**

#### H2. Stuck-rotation pattern (two Mulesoft users)
- `svc-mulesoft-dev`: 2022 key is the live one (used 2026-06-04). The 2024 key **was never used** (`LastUsedDate: N/A`). Rotation issued, cutover never happened.
- `svc-mulesoft-qa`: 2022 key #1 last used 2023-01-18 (stale); 2022 key #2 last used 2026-05-01. Old key still active.
- **Recommendation: deactivate the never-used and the stale keys.** Mulesoft team should drive cutover.

### MEDIUM — working integrations, plan eventual migration

#### M1. `svc_mulesoft_prod` (PROD 937464026810) — actively used today
- Key last used **2026-06-08T19:46 (today)** — s3 in us-east-2. NOT stale.
- Scope is appropriately narrow: `usx-*-mule-logs*` r/w + one specific SM secret `prod/mulesoft/mssql-zc4Vrk`
- No console password, no MFA — pure programmatic
- **Long-term recommendation: migrate to AWS-Mulesoft federated identity if Mulesoft Cloud supports it; else SM-rotation-Lambda pattern.** Not urgent for BeyondTrust phase 2.

#### M2. `svc_confluentbridge_dev` (usx-dev) — actively used today
- Last used **2026-06-08T12:55 (today)** — sts in us-east-1 (assuming roles via this key)
- Narrow scope: 4 specific Kafka/Confluent SM secrets
- **Long-term: same plan as M1.**

### LOW — cleanup candidates

- `test-octopus` (infra-common) — last used 2025-03 + `AmazonS3FullAccess` overly broad. Confirm if still in use, scope down or delete.
- `github-workflow-user` (data-dev) — no active keys, ECR + Lambda policies attached; cleanup candidate.
- `svc_config_mgmt` (usx-dev) — no recent key usage in audit; review if console-only/role-only.

### Operational findings (not BeyondTrust)

#### O1. PROD has zero GitHub OIDC roles
`ops-controller` (937...) showed no `token.actions.githubusercontent.com` trust policies. Either:
- GHA deploys to PROD chain through Octopus IRSA (likely, via `iaac-octopus-worker-usxpress-prod`)
- Or via the `svc_mulesoft_prod` static key (which is hot today)

**Confirm with Jeff Shaw**: auth path from PROD deploy GHA workflow into account 937.

#### O2. Mage-runner publish step — verify s3 push uses OIDC inline
`variant-inc/actions-collection/s3-package-push@v2` documents `id-token: write` as required but `s3PackagePush.ps1` does the AWS call. Should be OIDC by construction (`ubuntu-latest`, no cached creds), but one-line confirmation worth getting.

#### O3. On-prem TF state locking off
`onprem-development.yaml`: `DYNAMO_DB_TABLE: ""`. Operational risk if two engineers run MageRunner against op-usxpress-dev simultaneously. Cleanup independent of BeyondTrust.

### CloudTrail ConsoleLogin (cross-region re-run, last 24h)

Only one hit: **`syerra2@usxpress.com`** in usx-qa us-east-1 (2026-06-08 10:34 EDT).

Everything else empty across infra-common, data-dev, ops-controller, usx-dev, usx-qa for both us-east-1 and us-east-2. Confirms console usage is uncommon — most access is via SSO + CLI.

## Asks for Christopher (next email)

1. **Scope confirmation in writing**: phase 1 = login flow / `_ELEV` permission set only, NOT a restructuring of existing SSO permission sets. NOT touching IAM users, IRSA, or GHA OIDC at this stage.
2. **List of AWS accounts in scope** for phase 2.
3. **Existing SSO permission set inventory** they intend to overlay `_ELEV` onto.
4. **Proposed `_ELEV` permission set spec** (what actions does it grant beyond standard SSO?).
5. **Pilot account suggestion**: `infra-playground` (786352483360) — zero IAM users + only one GHA OIDC role + no production workload. Cleanest test bed.
6. **Service-account scope-out statement** — IRSA + GHA OIDC + Octopus worker chain explicitly NOT in phase 2.
7. **Break-glass procedure** — how does an SRE recover access if BeyondTrust itself is down at 3am during an incident?

## Asks for Jeff Shaw (DX side)

1. Confirm `variant-inc/actions-collection/s3-package-push@v2` → `s3PackagePush.ps1` uses inline OIDC, no static-key fallback path
2. How do GHA workflows that deploy to PROD (937...) reach AWS? Via Octopus IRSA chain or direct?
3. Are there any DX-owned IAM users with active keys I might have missed (e.g. in accounts outside Doke's SSO scope)?
4. Mage-runner upstream `variant-inc/actions-go@v1` — does it set any AWS env vars from runner-level creds?

## Asks for Steve Duck

1. Confirm ownership of `analyst_test`, `bolei-test`, `serverless-test`, `test-octopus`
2. Awareness of `svc_mulesoft_*` rotation drift — should Mulesoft team be looped in?
3. Variant/XT inherited cross-account roles — anything to flag before BeyondTrust phase 2?

## Live-cluster verification (Blocks B, C, D — 2026-06-08 PM)

### Block B — on-prem `op-usxpress-dev` → CLEAN

- 6 IRSA-annotated SAs (cert-manager, ecr-credentials-sync, external-dns, external-secrets, risingwave, risingwave-2) — all cross-account into 700736442855 (USX-Dev)
- **0 pods with `AWS_ACCESS_KEY_ID` env**
- ESO `default` ClusterSecretStore uses jwt + serviceAccountRef (IRSA-style)
- cert-manager controller pod env confirms IRSA token-file injection
- letsencrypt-prod/staging ClusterIssuers chain to network account (155...) — Phase 0 pattern intact
- pod-identity-webhook Running 19d
- No Wiz/Orca pods deployed on-prem

### Block C — cloud × 3 clusters (`cloud-usxpress-dev`, `usxpress-prod`, `qa-one`)

- 30-36 IRSA-annotated SAs per cluster (95+ total)
- Octopus worker IRSA chain confirmed running on all 3 (`octopusworker-{0,1,2}` Running 43h)
- No GHA self-hosted runners in-cluster
- No live mage-runner deploy pods

#### Resolved-benign: EBS CSI controllers declare AWS_* env vars across all 3 clusters

`ebs-csi-controller` pods declare `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` env vars on the `ebs-plugin` container in `kube-system`. **Confirmed 2026-06-08 to be the upstream chart's `valueFrom: secretKeyRef.optional: true` pattern.**

Verified by checking `kubectl -n kube-system get secret aws-secret` on all 3 cloud clusters:
- `cloud-usxpress-dev` → NotFound
- `usxpress-prod` → NotFound
- `qa-one` → NotFound

Since the referenced Secret doesn't exist, the env vars are unset at runtime, and the SDK uses the IRSA web identity token (SA `ebs-csi-controller-sa` has `eks.amazonaws.com/role-arn` on all 3 clusters). **No static-key path exists. Clean.**

### Block D — CICD via GitHub Actions

| Repo | Auditable? | Secrets we saw | Workflow pattern | Verdict |
|---|---|---|---|---|
| variant-inc/mage-runner | yes | — | Package Push uses `id-token: write` + actions-collection (OIDC) | Clean |
| variant-inc/iaac-octopus-onprem | yes | `OCTOPUS_API_KEY` | Re-mirror on-prem releases — Octopus API only | Clean |
| variant-inc/iaac-talos | yes | `OCTOPUS_API_KEY` | Validate & Push to Octopus | Clean |
| variant-inc/iaac-risingwave-2, -onprem, iaac-flux-manifests, iaac-talos-flux-platform | yes (no secrets visible) | — | Same Validate & Push pattern | Clean |
| variant-inc/iaac-octopus-overrides | **404 — admin gap** | unknown | — | **Cannot audit — need admin spot-check** |
| variant-inc/terraform-irsa-roles | **404 — admin gap** | unknown | — | **Cannot audit — need admin spot-check** |

#### The CICD chain in one line

```
GHA workflow → (uses OCTOPUS_API_KEY only) → Octopus Server → Octopus worker pods (IRSA in-cluster) → AWS
```

**No GHA workflow in any USX-owned IaC repo holds an AWS static key.** The only sensitive credential is `OCTOPUS_API_KEY`, which authenticates to Octopus, which then does the AWS work via in-cluster IRSA.

#### Two access-control gaps to escalate

- **`iaac-octopus-overrides`** and **`terraform-irsa-roles`** returned 404 on `gh api repos/.../secrets` — Doke isn't admin. These are exactly the repos most likely to hold AWS-relevant secrets. Either ask current admin (Steve Duck or Jeff Shaw post-Vibin) to grant audit access, or have them spot-check.

## Final impact matrix (post Blocks A-D)

| Surface | Verdict |
|---|---|
| On-prem cluster (op-usxpress-dev) | ✅ Clean — pure IRSA + jwt SA ref |
| Cloud × 3 clusters (workload identity) | ✅ Clean — 95+ IRSA SAs total |
| Cloud EBS CSI env vars | ✅ Verified benign 2026-06-08 — `aws-secret` NotFound on all 3 clusters; SDK falls back to IRSA |
| Octopus runtime (cloud + on-prem) | ✅ Clean — IRSA chain |
| GHA workflows in USX IaC repos | ✅ Clean — no `configure-aws-credentials` static-key path |
| Mage-runner publish (GHA) | ✅ Clean — OIDC via `id-token: write` |
| **Legacy IAM users (Block A)** | ⚠️ 3 CRITICAL + 2 HIGH + 2 MEDIUM + 4 LOW |
| **`iaac-octopus-overrides` + `terraform-irsa-roles` secrets** | ❓ Unknown — admin-only repos, escalate for spot-check |

## What remains to do

- [x] EBS CSI `aws-secret` verification — DONE 2026-06-08, NotFound on all 3 clusters, benign confirmed
- [ ] Read `s3PackagePush.ps1` source to lock down mage-runner publish auth (low priority — runner constraints make OIDC the only viable mechanism)
- [ ] Spot-check `iaac-octopus-overrides` + `terraform-irsa-roles` secrets via admin (Steve Duck or Jeff Shaw)
- [ ] Verify no IAM users in accounts Doke doesn't have SSO access to (need org-admin trace)
- [ ] Draft Christopher follow-up email using this doc as the body source
