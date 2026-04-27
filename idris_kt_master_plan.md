# Idris Onboarding — Knowledge Transfer Master Plan

**Owner:** Dare Oke
**Onboardee:** Idris Fagbemi
**Team:** Cloud Platform / On-Prem
**Kickoff:** Week of 2026-04-27
**Format:** 1 session per week-ish (60–90 min each), live walk-through + recording. Doc-per-session lives alongside this plan.

---

## How to use this plan

Each session has its own deep-dive document in this folder:

| # | Session | Doc |
|---|---------|-----|
| 0 | Platform Overview (the big picture) | [idris_kt_session0_overview.md](idris_kt_session0_overview.md) |
| 1 | iaac-talos + flux-platform (on-prem cluster) | [idris_kt_session1_talos_flux.md](idris_kt_session1_talos_flux.md) |
| 2 | Octopus (config + onprem + overrides) | [idris_kt_session2_octopus.md](idris_kt_session2_octopus.md) |
| 3 | terraform-variant-apps | [idris_kt_session3_terraform_variant_apps.md](idris_kt_session3_terraform_variant_apps.md) |
| 4 | DX & mage-runner | [idris_kt_session4_dx_mage.md](idris_kt_session4_dx_mage.md) |
| 5 | iaac-eks (RisingWave's home) | [idris_kt_session5_iaac_eks.md](idris_kt_session5_iaac_eks.md) |
| 6 | Supporting repos (monitoring, flux-manifests, pod-identity-webhook) | [idris_kt_session6_supporting.md](idris_kt_session6_supporting.md) |
| 7 | RisingWave deep-dive (his project kickoff) | [idris_kt_session7_risingwave.md](idris_kt_session7_risingwave.md) |

Each session doc contains: **goals, prerequisites, agenda with timings, the deep-dive content (file paths, real code snippets, key variables), hands-on exercises, common pitfalls, and homework**.

---

## Sequencing logic (why this order)

We ordered the sessions to **build mental model bottom-up**:

1. **Session 0** establishes the big picture so every subsequent session has a place to hang detail off of.
2. **Session 1 (iaac-talos)** is concrete — VMs, OS, Kubernetes — the physical/virtual foundation. Easiest to reason about.
3. **Session 2 (Octopus)** sits on top — the deployment system that fires terraform/helm against the cluster from Session 1.
4. **Session 3 (terraform-variant-apps)** is what Octopus actually runs — per-app TF that builds infra.
5. **Session 4 (DX & mage-runner)** wraps Session 3 — the orchestrator that drives terraform-variant-apps from spec.yaml.
6. **Session 5 (iaac-eks)** finally — the cloud cluster, where RisingWave will live. By now Idris understands every layer above and below.
7. **Session 6** mops up the supporting repos.
8. **Session 7** kicks off his actual project.

**Cloud-tied pieces are introduced incrementally**: Octopus (Session 2) introduces cloud↔on-prem space mirroring, terraform-variant-apps (Session 3) is shared with cloud, DX/mage (Session 4) is *fully* cloud-shared. Session 5 puts him in the cloud cluster directly.

---

## What he should be able to do after each session

- **After Session 0**: Draw the platform on a whiteboard. Name every repo. Explain on-prem vs cloud at a high level.
- **After Session 1**: Walk through what happens when we `terraform apply` on iaac-talos. Read a Flux Kustomization and trace its dependency chain.
- **After Session 2**: Onboard a new app to the OnPremise Octopus space using `onboard-app.yaml` workflow. Read `onprem-development.yaml` and explain how a variable lands in Octopus.
- **After Session 3**: Open spec.yaml for a real app and predict what terraform-variant-apps will create. Explain why we forked it.
- **After Session 4**: Trace a deploy from `git push` → ECR → mage-runner → Octopus → terraform-variant-apps → cluster. Run mage-runner locally.
- **After Session 5**: Read iaac-eks code, understand cluster module composition, locate where RisingWave will be added.
- **After Session 6**: Operate the monitoring stack and Flux manifests; understand pod-identity-webhook deeply.
- **After Session 7**: Have a working RisingWave deployment in usx-dev EKS and a clear 4-week roadmap.

---

## Pre-reads (before Session 0)

Send Idris these the day before kickoff:

1. The current standup update (so he has context on where we are).
2. `magerunner_deep_dive.md` — gives him a head start on mage-runner conceptually.
3. `dpl2_platform_architecture_document.md` — the original platform architecture write-up. Some of it is dpl2-era (now replaced by op-usxpress-dev) but the architecture concepts carry over.
4. `design_doc_magerunner_bare_metal.md` — explains *why* we did all this on-prem work.
5. The repo list (Section "Repo Map" below).

Tell him: don't try to absorb all of it. Skim. Ask "I don't get this" liberally during sessions.

---

## Repo map (one-liner per repo)

### Cloud-team owned (he should not edit these)
- **iaac-eks** — Cloud EKS clusters (usx-dev, qa-one, usxpress-prod). RisingWave will land here.
- **terraform-variant-apps** — Per-app TF module library (api, auth, mongodb, kafka, postgres, etc). Cloud-team owned; we have a fork on `feature/onprem-support`.
- **mage-runner** — CI/CD orchestrator. Reads spec.yaml, drives terraform-variant-apps. We have a fork on `feature/onprem-support`.
- **DX** — Glue scripts (`patch-dx-apply.py`, deploy lifecycle). Lives inside the deployment tooling pipeline.
- **iaac-octopus-config** — Cloud Octopus space configuration. Cloud-team owned. **PR #89 was closed**; we don't put on-prem here.
- **iaac-flux-manifests** — Cloud-side Flux manifests for cloud EKS clusters.
- **iaac-monitoring** — Prometheus/Grafana stack (cloud).
- **terraform-mongodb-atlas-user** — Mongo Atlas user TF module. We have a fork with `use_eks_api` gate.

### On-prem team owned
- **iaac-talos** — Talos cluster Terraform (vSphere → Talos VMs → cluster bootstrap → Flux).
- **iaac-talos-flux-cluster** — Per-cluster Flux Kustomization CRDs (cluster bootstrap configs).
- **iaac-talos-flux-platform** — Cluster-wide Flux platform (cert-manager, ESO, KEDA, istio, app namespaces, etc).
- **iaac-octopus-onprem** *(NEW, 2026-04-24)* — On-prem Octopus space automation. Created per Vibin's direction after PR #89 was closed. Replaces what was attempted in iaac-octopus-overrides (now consolidated).
- **iaac-octopus-overrides** *(working name)* — The actual repo we've been building in. Contains apply.py, mirror-release.py, onboard-app.py, patch-dx-apply.py, GHA workflows, override YAMLs, terraform/worker-iam-policies.tf, cross-cluster-eso/. Functionally what iaac-octopus-onprem will be.
- **amazon-eks-pod-identity-webhook** — Vendored fork of the EKS pod identity webhook (used for IRSA on Talos).

### Forks (on `feature/onprem-support` branches)
- mage-runner fork (variant-inc/mage-runner) — env gate adds "dev"; namespace.go gates ambient+privileged labels by `TF_VAR_use_eks_api=false`.
- terraform-variant-apps fork — api module injects `extraSecrets` for azuread; mongo `use_eks_api` gate; auth/mongodb gated by `use_eks_api`.
- terraform-mongodb-atlas-user fork — `use_eks_api` gate (the mongo-atlas v2 architectural fix).

---

## Cloud↔on-prem relationship (the rule that explains everything)

**On-prem references cloud-created shared resources. It does not duplicate them.**

| Resource type | Created where | Consumed how on on-prem |
|---|---|---|
| Azure AD app registration | Cloud (terraform-variant-apps `auth` module) | ExternalSecret reads `azure-app-dx-<env>-<space>-<app>` from AWS SM |
| MongoDB Atlas user | Cloud (cloud account or terraform-mongodb-atlas-user) | `<app>-m-u` cert via cross-cluster ESO bridge (POC) or AWS SM (prod path) |
| Kafka credentials | Cloud TF writes to AWS SM | On-prem ExternalSecret reads from default ClusterSecretStore |
| AWS SM secrets | Cloud | On-prem ESO reads via IRSA (pod-identity-webhook injects role) |

**Key fork mechanism**: `TF_VAR_use_eks_api=false` is the on-prem gate. When set:
- mage-runner skips ambient + privileged namespace labels
- terraform-variant-apps `api` module injects `extraSecrets` instead of relying on cloud auth submodule
- terraform-variant-apps `mongodb_user` switches to the v2 fork pattern
- DX-Apply patched script reads cluster config from SSM (not from EKS API)

**This is the single most important concept Idris needs to understand.** Spend extra time on it in Session 0.

---

## Where RisingWave fits

- **Project:** Streaming database (Kafka source → materialized views → Postgres-compatible sink).
- **Where it lives:** iaac-eks repo (per Vibin's March 31 decision — RisingWave is an "iaac-eks pattern", not a new repo).
- **Cluster:** usx-dev EKS first (us-east-2, account 700736442855).
- **Why him:** Vibin assigned this to Idris as ramp-up project. Tim Preble (RisingWave SME) intro meeting still pending — flag this as a gate.
- **Scope of session 7:** What it is + how it ties in + concrete first 2-week tasks.

---

## Things to be honest about up front

When briefing Idris, lead with these caveats so he doesn't bake POC patterns into prod work:

1. **Cross-cluster ESO is POC-only**. Pulling secrets from the cloud cluster creates an SPOF on cloud. Prod migration path: AWS SM as source.
2. **Forks aren't merged upstream**. mage-runner fork on `feature/onprem-support` and terraform-variant-apps fork are not yet PR'd. Authoritative branches are the forks, not main. Vibin must sign off before PRs.
3. **AHV / Rook-Ceph are coming Q4 2026**. Some of what's on-prem now (e.g., S3 dependency for state) will change.
4. **dpl2 is dead**. Any doc/script/branch that references dpl2 is stale unless explicitly noted as historical context. The live cluster is **op-usxpress-dev**.
5. **Naming evolution**: bm-dev → dpl2 → op-usxpress-dev. He'll see all three names in old docs. Only op-usxpress-dev is real today.

---

## Recurring themes across sessions

These show up in multiple sessions; flag them when they appear:

- **IRSA on Talos** uses pod-identity-webhook (vendored EKS webhook) + a CloudFront-fronted S3 OIDC discovery doc + AWS IAM OIDC provider. Session 1 introduces it; Session 6 deep-dives.
- **Flux dependency chain**: cert-manager → pod-identity-webhook → app-namespaces → ecr-credentials → app-deployments. Sessions 1 and 6.
- **State buckets**: cluster TF state in `lazy-tf-state-65v583i6my68y6x9/iaac/talos/op-usxpress-dev.tfstate`. Per-app TF state in `op-usxpress-dev-tfstate`. Sessions 1 and 3.
- **Spec.yaml** is the contract. Sessions 3, 4, and 7 all touch it.
- **`TF_VAR_use_eks_api=false`** is the on-prem gate — it shows up in mage-runner, terraform-variant-apps, and DX-Apply. Sessions 3 and 4.

---

## Logistics

- **Cadence:** Aim for 2 sessions/week. He's full-time, no PTO scheduled. Dare PTO 5/4–5/8.
- **Session structure:** 60–90 min live + 15-min Q&A buffer. Record everything. Pause to whiteboard when needed.
- **Hands-on:** Every session has at least one hands-on exercise. He learns by doing, not watching.
- **Homework:** End each session with 1–2 concrete tasks before next session.
- **Office hours:** Daily 30-min slot in afternoon for him to ask anything (no agenda).
- **Slack:** Use the cloud-platform channel for written follow-up; don't let things stay verbal.
- **Drive:** Recordings + slides + this folder of docs all go in the team Drive folder.

---

## Pre-reqs to get him set up Day 1

This is access/setup that needs to happen before sessions can be productive:

- [ ] GitHub access to all variant-inc repos
- [ ] Slack channels: cloud-platform, on-prem-platform
- [ ] Octopus accounts (USXpress + OnPremise spaces) with at least Reader role
- [ ] AWS SSO access to USX-Dev (700736442855) and devops/ECR (064859874041)
- [ ] WSL2 setup with kubeconfig for op-usxpress-dev (10.10.82.50:6443) — he needs corp VPN
- [ ] Azure CLI installed + access to USX Applications Dev subscription (for mage auth module)
- [ ] Atlassian account for Jira (INFRA project) and Confluence
- [ ] Repo clones: iaac-talos, iaac-talos-flux-platform, iaac-octopus-overrides, mage-runner, terraform-variant-apps (all on the right branch)
- [ ] tfswitch installed (Terraform version manager — see [tfswitch_pgp_fix.md](tfswitch_pgp_fix.md))
- [ ] AWS CLI profiles configured: `usx-dev`, `playground`, `ops-controller`

I'll set up a shared Day-1 checklist doc and we'll work through this with him on his first morning before Session 0.

---

## Open questions to resolve before kickoff

- Which day/time slots? Need to land 2 standing 90-min slots on his calendar.
- Tim Preble intro meeting — when? RisingWave session 7 needs Tim. Schedule before week 4.
- Does he get a sandbox AWS account or just usx-dev? (Recommend: usx-dev only, no separate sandbox.)
- Who owns the "design doc" he'll co-author for RisingWave? (Recommend: he writes, Vibin reviews.)
