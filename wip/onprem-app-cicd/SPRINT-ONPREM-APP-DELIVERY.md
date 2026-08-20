# Sprint — On-prem application delivery

**Created in Jira 2026-08-18.** Epic **INFRA-1632**. Stories INFRA-1633 … INFRA-1643, all
parented to the epic and in sprint **959 "UI Sprint 3"** (board 322), dated
**2026-08-17 → 2026-08-28**.

Sprint 6088 "UI Sprint 2" was closed on 2026-08-18 with its end date set to 2026-08-14;
its unfinished work moved into UI Sprint 3. A separate sprint 6155 "On-Prem App Delivery"
was created first and then emptied — the work was consolidated into UI Sprint 3 so the
team runs one sprint, with the epic doing the grouping.

**Status 2026-08-20** — closed via `scripts/close-sprint3-tickets.py`, evidence in
`FINDINGS-2026-08-20.md`. Four follow-ups filed for what the work uncovered.

| # | Key | Ticket |
|---|---|---|
| 1 | INFRA-1633 | ECR repository + GitHub OIDC push role — ✅ **DONE**, but the repo and its policy are outside Terraform; successor ticket filed |
| 2 | INFRA-1634 | RisingWave ETL application repository — ✅ **DONE**, premise was wrong (the repo existed); re-scoped work shipped as #9/#10/#11 |
| 3 | INFRA-1635 | Deploy overlays for QA and prod, pinned by digest — 🟡 **open**: AC met on QA, but `PIPELINE_DIR` is still the smoke payload |
| 4 | INFRA-1636 | ApplicationSet for op-usxpress-prod |
| 5 | INFRA-1637 | **SECURITY** — rotate the Confluent Cloud credentials |
| 6 | INFRA-1638 | Extend AWS SSO to op-usxpress-dev and op-usxpress-prod |
| 7 | INFRA-1639 | Argo CD SSO for application teams — **BLOCKED** |
| 8 | INFRA-1640 | Kyverno policies Audit → Enforce |
| 9 | INFRA-1641 | Harden ecr-credentials-sync |
| 10 | INFRA-1642 | Flux Git token at source + alert on stale sources |
| 11 | INFRA-1643 | Review the shared ECR registry policy |
| 12 | INFRA-1647 | Argo CD Git credential — ✅ **DONE on QA** 2026-08-20 (deploy key; prod outstanding) |
| 13 | INFRA-1648 | Smoke test — ✅ **DONE** 2026-08-20, `pipeline_applied` row is the proof |

**Filed 2026-08-20** from what the work uncovered, all parented to INFRA-1632:

| Key | Ticket |
|---|---|
| INFRA-1650 | Argo CD Git credential + ApplicationSet on op-usxpress-prod |
| INFRA-1651 | Bootstrap a Terraform path into ECR account 064859874041, adopt the hand-made repo and policy |
| INFRA-1652 | QA Postgres never learned its rotated password — recreate the meta pod, check dev and prod |
| INFRA-1653 | Argo CD sync hooks delete their own evidence — `BeforeHookCreation,HookSucceeded` + retry limit |


**Goal.** An app team can build an image and have it deployed to QA and prod through a
path they can see and troubleshoot themselves, with the platform owning namespaces,
credentials and guardrails — and no manual steps in between.

**Why now.** RisingWave QA (INFRA-1624) is the first app that needs this. Today its
pipeline exists only as DDL applied by hand to a dev cluster, with credentials in
plaintext, and no way to move it to QA except doing the same thing again. That does not
scale past one app and cannot be audited.

**Not in scope.** RisingWave's SQL itself, and what the pipeline computes. That is Tim's.

---

## Already delivered (2026-08-18, close these or log as done)

| Item | Evidence |
|---|---|
| `ecr-credentials` wired on QA and prod | Kustomizations Ready; pull secret in 21 (QA) / 18 (prod) namespaces |
| Per-cluster IRSA role ARNs corrected | platform#94, #95 — all three branches carried dev's ARN |
| `app-namespaces` live on QA and prod | `app-risingwave` with ambient, PSA restricted, quota, limits |
| Kyverno registry + digest policies | fired correctly on a real image, Audit mode |
| ApplicationSet on QA | generating `risingwave-etl` |
| Cross-account ECR pull proven | real image pulled in 3.0s on QA |
| QA Flux Git auth restored | expired 2026-08-16, silently green for 2 days |

---

## Tickets

### 1. Create the ECR repository and GitHub OIDC push role — **BLOCKED**
**Blocked on:** which IaC repo manages account `064859874041`. Tags on existing
repositories are empty, so it cannot be inferred. This is the single blocker on the
entire app-side path — ask whoever owns infra-common.

Create `risingwave/etl-pipeline` with IMMUTABLE tags, scan-on-push and lifecycle rules,
plus role `gha-risingwave-etl-ecr-push` trusted only from that one GitHub repo on
`refs/heads/main`, permitted `ecr:PutImage` on that one repository ARN.

Code is written: `wip/onprem-app-cicd/terraform/ecr-app-repos.tf`.

**AC:** a GitHub Actions run assuming that role can push, and cannot push to any other
repository.

### 2. Create the RisingWave ETL application repository
Scaffold from `wip/onprem-app-cicd/app-template/`: `build/Dockerfile`, `build/apply.sh`
(idempotent, tracks applied files in Postgres, refuses a file whose hash changed),
`.github/workflows/build-and-push.yml`.

**Open decision:** repository name and owning team. It is Tim's code and his build; do not
create it in his team's name without agreement.

**AC:** a push to `main` produces an image in ECR, addressed by digest.

### 3. Deploy overlays for QA and prod, pinned by digest
`deploy/overlays/qa` and `deploy/overlays/prod`, both referencing `repo@sha256:…`.
Promotion to prod is a PR that moves the same digest — never a rebuild.

**AC:** `risingwave-etl` in Argo CD goes Synced/Healthy on QA. Kyverno raises no
digest violation (it did on today's tag-based pull test — that is the check working).

### 4. ApplicationSet for prod
Prod has `app-namespaces` but deliberately no `argocd-apps`. Add
`applicationset-prod.yaml` with **no** automated sync — prod deployments are a
deliberate act.

**AC:** a prod Application appears, syncs only when a human triggers it.

### 5. Rotate the Confluent Cloud credentials — **SECURITY, do not wait**
SASL username and password are in `rw_catalog.rw_sources.connector_props` as
`"type": "plaintext"`, readable by anyone with a SQL session. Move to AWS Secrets
Manager, deliver via External Secrets, reference from DDL with `SECRET`.

**AC:** no plaintext credential in any RisingWave catalog table on any cluster; the old
credential is revoked, not merely replaced.

### 6. Extend AWS SSO cluster access to op-dev and op-prod
`aws-iam-authenticator` is wired only on `op-usxpress-qa`. Prod has no routine human
access path — verifying today's prod change required break-glass `talosconfig`, which is
not a sustainable way to check production.

Three cluster-specific values per cluster: the `AWSReservedSSO_*` role ARN in
`aws-auth-configmap.yaml`, and `--cluster-id` in two places in `daemonset.yaml`.

**Open decision for prod:** map the existing `usx-on-prem-admins` permission set (no
Identity Center change, available immediately) or mirror QA with a purpose-built
`op-prod-platform-admin` (needs Identity Center, tighter scope). QA has both sets and
deliberately uses the purpose-built one — so mirroring is the consistent choice, and the
question is whether prod access is needed sooner than that takes.

**AC:** `kubectl auth whoami` returns `sso:<email>` on dev and prod, with no cert.

### 7. Argo CD SSO for app teams — **BLOCKED**
**Blocked on:** an Entra app registration, which requires Azure access nobody on this
team has. Until then app teams cannot log in to see their own deployments, which
undermines the "troubleshooting is separated" goal — they would still have to ask us.

### 8. Flip Kyverno policies from Audit to Enforce
`require-approved-registry` and `require-image-digest` are `validationFailureAction:
Audit`. They work — proven today. Enforce once the first real app deploys cleanly, so
the first thing they block is a mistake and not the pipeline's own bring-up.

### 9. Harden `ecr-credentials-sync`
* Runs `public.ecr.aws/aws-cli/aws-cli:latest` — unpinned, while holding cluster-wide
  secret-write. Pin by digest.
* The standalone init Job races the ServiceAccount annotation. It failed on both QA and
  prod today, and because Jobs are immutable it pins the Kustomization at Failed until
  someone deletes it. Add an ordering guard or drop the init Job — the scheduled run
  covers it within 5 minutes.
* Its schedule comment says "every 6 hours"; the cron is `*/5`. Fix the comment.

### 10. Fix the QA Flux Git token at source, and audit the others
The working token is hand-patched into the cluster. The next `iaac-talos` deploy
overwrites it with the expired one. Put it in the Octopus variable — and watch that the
deploy actually applies, since `TfApply=false` is scoped `(all)` outside production.

Then check every cluster's token expiry. QA's died on 2026-08-16 and every Kustomization
kept reporting `Ready=True` on two-day-old config. Nothing alerted.

**AC:** an alert exists for a GitRepository that has not successfully fetched in N hours.
The absence of that alert is what made this cost two days.

### 11. Review the ECR registry policy
The repository policy grants `PutImage` to the entire org `o-yza5l1xhrc`, not just pull.
The scoped per-app push roles in ticket 1 constrain the pipeline; nothing constrains
anyone else in the org. IMMUTABLE tags prevent overwriting an existing tag, but any
principal can introduce a new one.

**AC:** a decision, recorded — either narrow the policy, or accept it explicitly with the
reasoning written down.

---

## Suggested ordering

Ticket 5 first — it is a live credential exposure and independent of everything else.
Then 1 (unblocks 2, 3), then 2 and 3 together, then 4. Tickets 6 and 10 are platform
hygiene that can run in parallel. 8 waits on 3. 7 waits on Azure.
