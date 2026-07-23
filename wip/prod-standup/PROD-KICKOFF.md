# op-usxpress-prod — kickoff plan (INFRA-1621)

**Started 2026-07-22.** Companion to `wip/qa-cluster-standup/PROD-AUTOMATION.md`,
which holds the manual-step inventory (§A), the acceptance gates (§B), and the
branch-per-env fix (§C). This document is the ordered build.

## The governing constraint

**QA is not being torn down.** So the teardown→rebuild path has never been executed,
and **prod's first build is the first real test of it**. Everything below is arranged so
that as much as possible is proven on QA — which is live and safe to change — before prod
hardware exists.

## Inputs still needed (nobody can proceed on these without answers)

| # | Input | Who | Blocks |
|---|---|---|---|
| P1 | Prod AWS account ID | Doke / Cloud | `prod.tfvars`, all ARNs, Octopus vars |
| P2 | vSphere capacity: cluster, datastore, resource pool, network/portgroup | Infra | Terraform apply |
| P3 | Prod IP plan: VIP + CP IPs + worker ranges per pool | Networking | `prod.tfvars`, etcd-backup endpoint |
| P4 | Prod DNS domain + `external-dns` owner ID | Networking | external-dns, Istio, cert-manager |
| P5 | Node counts/sizes per pool (application/platform/system) | Doke | `TF_VAR_worker_pools` JSON |
| P6 | Entra app registration for prod Grafana SSO | Entra owner | Grafana SSO only (not the build) |

P1–P4 are hard blockers on any prod apply. P5 is a decision you can make now.
P6 is the one genuinely-manual step and does not block — Grafana boots on admin login.

## Phase 0 — de-risk on QA first (do this before prod hardware arrives)

Every item here reduces what can go wrong on prod's one-shot build.

| # | Task | Why it must precede prod |
|---|---|---|
| 0.1 | Fix every remaining `op-usxpress-dev` string on `op-qa` (`external-dns txtOwnerId` known) | Prod cut from a dirty branch inherits the same bugs |
| 0.2 | Roll out `postBuild.substituteFrom` per-Kustomization on op-qa (PROD-AUTOMATION §C) | Removes branch-copy drift **structurally**; this is the single highest-value item |
| 0.3 | Deploy the etcd staleness alert to op-qa **and** op-dev | Prod inherits it; also proves the rule label matches the Prometheus ruleSelector |
| 0.4 | Script the Octopus prod variables (model: `add-qa-vars.py`) and diff against QA's set | ~29 vars are the largest body of prod config living nowhere in git |
| 0.5 | Argo CD proven on dev, then QA | Do not debut a new controller on prod |

⚠️ **0.2 landmine:** Flux `postBuild` substitutes `${...}` across the whole rendered
manifest, and Grafana dashboard ConfigMaps are full of `${datasource}`/`${interval}`.
Roll out per-Kustomization, checking rendered output each time; annotate dashboard
Kustomizations `kustomize.toolkit.fluxcd.io/substitute: disabled`.

## Phase 1 — code prep (no hardware needed)

1. `iaac-talos/deploy/terraform/envs/prod.tfvars` — **`enable_irsa = true`**.
   Never commit `false`: the committed QA file said `false` while state said `true`, and
   any apply that resolved it would have destroyed every IRSA resource.
2. Octopus: `prod` environment + the full `TF_VAR_*` set (from 0.4).
   Include `TF_VAR_manage_platform_secret_values=true` — without it the talosconfig
   value-write is count-gated to zero and the deploy is a silent no-op.
3. Flux: cut `op-prod` **from the unified/cleaned branch**, not from `op-dev`.
4. `iaac-talos-flux-cluster`: `clusters/op-usxpress-prod/flux-system/` incl. `cluster-vars`.
5. Prod state backend: bucket + DynamoDB table in the prod account (mirror `tf-state-usx-qa/`).

## Phase 2 — build

Octopus only. Never a local `terraform apply`.

## Phase 3 — acceptance

Run gates **B1–B7** from PROD-AUTOMATION.md §B verbatim. The two that matter most,
because each maps to a defect that actually shipped:

- **B4** — an etcd snapshot object exists in S3, non-zero, < 2h old.
  *A green ExternalSecret and a successful deploy both lied about this for 13 days.*
- **B5** — `git grep -nE "op-usxpress-(dev|qa)|10\.10\.82\.(50|51)" origin/op-prod`
  returns **zero hits**.

Then, and only then, is "prod is 100% IaC" a statement of fact rather than an aspiration.

## What "no manual intervention" honestly means

- **Automated and proven on QA:** Talos, Flux, IRSA, storage, talosconfig value,
  Grafana admin password, etcd snapshots.
- **Automated, never proven:** full teardown → rebuild. Prod is the first execution.
- **Manual and staying manual:** the Entra app-registration secret (P6). One secret,
  cross-team, and Grafana works without it.
- **Not covered by automation at all:** environment-correctness of copied manifests.
  Phase 0.2 is what fixes that; §B gates are what catch it meanwhile.
