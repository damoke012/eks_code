# On-prem CI/CD — the standard, what is built, what remains

**Decision, 2026-08-25 (Doke).** This path is **the standard for every net-new deployment on
the on-prem side.** DX / MageRunner is used *only* for existing workloads being moved on-prem
from somewhere else. New work does not go through DX.

RisingWave is the first consumer and the proving ground, but nothing in the path is specific
to it.

---

## 1. The model

**Build once. Promote by digest. Never rebuild between environments.**

```
commit ─► GitHub Actions ─► ECR by digest ─► PR bumps QA overlay ─► Argo CD (QA) auto-syncs
 (app)    (GitHub-hosted)    064859874041          (app repo)              │
                                                                          │
                                          PR bumps prod overlay, SAME digest
                                                                          │
                                            Argo CD (prod) — synced by a human, never automatically
```

What this buys: what runs in production is provably the artefact that passed QA, because it is
the same bytes. A tag can be moved and a rebuild can pick a different base image; a digest cannot.

Builds run on **GitHub-hosted runners**. The clusters only pull. No CI credential exists inside
a production cluster, and nothing in CI needs a route into on-prem.

**Two shapes.** *Service* = Deployment + Service. *Job* = migrations, SQL, batch — run as an Argo CD
**sync hook**, so it re-runs on every sync and its logs land in the Argo UI. The Job shape matters
because most on-prem dependencies (Postgres, brokers, RisingWave's SQL frontend) are `ClusterIP`
with no external route: a Job *inside* the cluster reaches them over cluster DNS, a CI runner cannot.

---

## 2. Built and proven

| # | Item | Where | Evidence |
|---|---|---|---|
| 1 | Shared ECR, cross-account pull | 064859874041 | pull secret live in 18 prod namespaces |
| 2 | GHA → ECR push by digest, via OIDC | `risingwave-pipeline` | `sha256:d6162426…` from commit `987ea1ca` |
| 3 | Immutable tags | ECR | re-dispatch refused the overwrite |
| 4 | `app-<name>` namespace factory | Flux, all 3 clusters | `app-risingwave`: ambient mesh, PSA restricted, quota |
| 5 | Kyverno policy | QA + prod | non-ECR images and tag-pinned images both refused |
| 6 | Argo CD + `apps` AppProject | QA | destinations restricted to `app-*`, `CreateNamespace=false` |
| 7 | ApplicationSet `onprem-apps` | QA | generates `risingwave-etl` |
| 8 | Argo CD Git credential | QA | deploy key, `ssh://`, exact-URL match |
| 9 | **End to end, once** | QA, 2026-08-20 | `pipeline_applied` row: `smoke/001-connectivity.rw \| 4b65ef49e1c4 \| argocd-qa` |
| 10 | Credential drift check | `scripts/check-argocd-repo-credentials.sh` | red on the real defect, green after the fix |

Item 9 was written only if **every** link held: GHA build → ECR by digest → cross-account pull →
Argo CD reading an internal repo → sync-hook Job in-cluster → ESO credentials → Postgres →
RisingWave.

> ⚠️ **"Proven end to end" described one execution, not the system.** One hour later the QA path
> was dead for 18 hours: a PR about Kyverno was assembled from a stale `wip/` copy and silently
> reverted the ApplicationSet's Git URL from `ssh://` to `https://`. A deploy key matches on the
> **exact** URL, so no credential matched, and GitHub answers "Repository not found" for a private
> repo — which reads like deletion, not auth. Argo showed `sync=Unknown`, `health=Healthy`,
> `operationState=Succeeded` from the previous day.

---

## 3. What remains — platform (us)

| # | Item | Cluster | Ticket | Note |
|---|---|---|---|---|
| P1 | ApplicationSet + Git credential | **prod** | INFRA-1650 | prod deliberately has none yet; needed before any app deploys there |
| P2 | Extend the path to **dev** | dev | — | dev has the namespace factory but no ApplicationSet |
| P3 | Org GitHub App instead of a deploy key | all | — | deploy key is per-repository; `REQUEST-GITHUB-APP-OWNER.md` drafted. Needs a `variant-inc` **owner** — `dare-x` is only a member |
| P4 | ECR bootstrap into Terraform | ECR acct | INFRA-1651 | repo + push role exist **outside** IaC; owning repo unidentified |
| P5 | ECR registry policy | ECR acct | — | `PutImage` granted to the whole org `o-yza5l1xhrc`, which weakens the scoped per-app push roles |
| P6 | Argo CD **RBAC for app teams** | dev + QA | — | see §5 — SSO authenticates, group-based authorisation does not |
| P7 | Prod ingress | prod | INFRA-1663 | Gateway served QA hostnames; wildcard cert failed 27 days; cert-manager had no IRSA. Being fixed 2026-08-25 |
| P8 | Auto-merge on green | platform repo | filed | every PR is an immediate deploy to that branch's cluster — "ship to dev, then prod" is not achievable by intent today |

## 4. What remains — RisingWave (Idris)

| # | Item | Why it is his |
|---|---|---|
| R1 | **Containerise the RW workload properly** | he built the RW platform and has the dev background; this is the piece the path cannot supply |
| R2 | A `deploy/` directory in the app repo: base + `overlays/{dev,qa,prod}` | app-owned by design |
| R3 | **Nothing environment-specific in the image** | hostnames, topics, ports → ConfigMap in the overlay; credentials → Secrets Manager → ExternalSecret. An inlined `dev-` topic will not fail loudly in QA — it will succeed against the wrong thing |
| R4 | Digest-bump PRs (QA, then prod with the same digest) | the promotion decision is the app team's |
| R5 | Secret **values** in Secrets Manager | platform owns delivery, app owns values |
| R6 | Decide the dev pipeline's future | `risingwave-pipeline` + ARC runner reaches `risingwave-2` on dev only, and repo vs live cluster have diverged (`400-sink.rw` defines sinks dev does not run) — INFRA-1644 |
| R7 | The 238 SIGSEGV restarts on `risingwave-meta-default-0` | unexplained; 16 hours, then stable |
| R8 | **Does RisingWave go to prod at all?** | it was omitted from the prod stand-up, yet the prod branch carries RW routes and certificates copied from dev — wrong, and currently inert |

## 5. How the RW team sees its deployments in Argo CD

**Today, honestly:** they cannot, yet. Three things stand between them and a working view.

1. **Authentication — done.** Argo CD on dev and QA authenticates against Entra ID directly
   (Dex removed). `https://argocd.op-dev.usxpress.io`, `https://argocd.op-qa.usxpress.io`.
2. **Authorisation — blocked.** Entra issues a valid token with **no `groups` claim**, so
   `policy.csv` matches nothing and `policy.default: ""` applies. Everyone lands with no access.
   Under investigation with whoever owns the tenant; every field on our side is verified.
3. **No read-only role exists yet.** `policy.csv` currently maps one admin group. The app-team
   view needs its own entry, scoped to the project rather than the cluster:

   ```
   p, role:app-viewer, applications, get,  apps/*, allow
   p, role:app-viewer, applications, sync, apps/*, allow      # QA only, if we want them to sync
   p, role:app-viewer, logs,         get,  apps/*, allow
   g, <RW group object ID>, role:app-viewer
   ```

   Note the subject is an **object ID**, not a name: `usx-cloud-admin` is a cloud-only Entra
   group and Entra can only emit display names for AD-synced groups.

**What they get once it is on:** their `risingwave-etl` Application — sync status, health, the
resource tree, and **the sync-hook Job's logs in the UI**, which is the main day-to-day value.
They cannot deploy outside `app-*`, cannot create namespaces, and on prod cannot sync at all
(manual, human-initiated, by design).

**Decision needed:** which Entra group represents the RW team, and whether QA sync is theirs or
ours. Prod stays manual regardless.

**Update, later 2026-08-25.** The role now exists as a PR builder rather than a proposal:
`scripts/pr-argocd-rbac-app-viewer.sh` writes it to all three branches, scoped to the
AppProject read off each branch, with `sync` on dev and QA and withheld on prod. It needs
one value from Idris — the group's object ID.

And the authorisation blocker has a route around it that does not depend on the directory
team: `roles` is a separate claim issued from appRoleAssignments on our own service
principal, and Argo's `configs.rbac.scopes` can be told to match it
(`scripts/entra-argocd-app-roles.sh`). Unproven until a fresh token is read, but it is ours
to try. Sequence and commands: `wip/onprem-argocd/RUNBOOK-FINISH-INFRA-1639-AND-1663.md`.

## 6. Where Idris is most useful

He has the dev background and built the RW platform, so the highest-leverage split is:

* **Him:** containerising RW (R1), the `deploy/` layout and overlays (R2–R3), the SIGSEGV
  question (R7), and being the first real user of the onboarding doc — if it does not work for
  him it will not work for anyone.
* **Us:** everything in §3, plus unblocking the Argo view (P6).

The onboarding doc (`ONBOARDING.md`) is written for app teams and has never been used by one.
He is the test.
