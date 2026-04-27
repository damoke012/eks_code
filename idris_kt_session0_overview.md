# Session 0 — Platform Overview

**Duration:** 90 min (60 walk-through + 30 Q&A)
**Format:** Whiteboard / shared screen. No code yet.
**Goal:** Idris can draw the platform and name every repo by the end.

---

## Why this session exists

If we dump him into iaac-talos in week 1 he'll memorize TF without understanding *why*. Session 0 builds the mental model so every subsequent session has a place to attach detail.

By the end of this session, when we say "the on-prem ESO bridge pulls from cloud k8s", he knows what every word in that sentence means.

---

## Prerequisites

- Skim `dpl2_platform_architecture_document.md` (architecture concepts; ignore dpl2-specific names — replaced by op-usxpress-dev)
- Skim `design_doc_magerunner_bare_metal.md` (the *why* behind on-prem)
- Quick read of the standup update from 4/27

---

## Agenda (90 min)

| Time | Topic |
|------|-------|
| 0–10 | Knight-Swift / USXpress / Variant context — who we are, who Vibin is, who Cloud Team is |
| 10–25 | What we run + where: 3 cloud EKS + 1 on-prem Talos |
| 25–45 | The deployment flow end-to-end — single slide, repeated 3 times in increasing detail |
| 45–60 | Repo map — one-line per repo, group by ownership |
| 60–75 | Cloud↔on-prem rule (the most important concept) |
| 75–85 | Where RisingWave fits |
| 85–90 | Q&A + homework |

---

## Section 1 — Org context (10 min)

Give him the people-and-teams map. He needs this to know who to ask what.

```
Knight-Swift (parent company)
└── USXpress (the business unit we work with)
    └── Variant (the engineering arm — variant-inc on GitHub)
        ├── Cloud Team (Vibin Joseph leads — owns iaac-eks, mage-runner, DX, terraform-variant-apps)
        ├── On-Prem Team (us — Dare, Idris, James/Mayowa contractors, Steve Duck mgr)
        ├── Application teams (their apps run on our platform)
        └── Cloud Ops / SRE (oncall, incident response)
```

**Key relationships:**
- **Vibin** signs off on architecture decisions that touch cloud repos (forks, PRs, RisingWave shape).
- **Steve Duck** is our manager — he's the GIF guy from the standup screenshot.
- **Tim Preble** is the RisingWave SME — Idris's eventual collaborator.
- **Frankie / Scott McGee** are senior engineers we borrow context from.

---

## Section 2 — What we run + where (15 min)

### Cloud EKS clusters (us-east-2)

| Account | Profile | EKS cluster |
|---|---|---|
| 700736442855 (USX-Development) | `usx-dev` | `usxpress-dev` |
| 527101283767 (USX-QA) | `usx-qa` | `qa-one` |
| 937464026810 (USX-Production) | `ops-controller` | `usxpress-prod` |

Plus:
- **064859874041 (devops/ECR)** — the shared image registry. Profile: `devops` or `usx-devops`.

### On-prem Talos cluster

- **Name**: `op-usxpress-dev`
- **Hardware**: 8 nodes (3 control plane + 5 workers) on vSphere, in our on-prem datacenter
- **Talos version**: v1.10.6 (or close — check actual)
- **K8s version**: v1.32.0
- **API**: `https://10.10.82.50:6443`
- **Why "op-usxpress-dev" not "dpl2"?** dpl2 was the *old* cluster name. Phase 2 migration (April 2026) destroyed Playground-account dpl2 and rebuilt as op-usxpress-dev in the USX-Dev account.

**Whiteboard exercise:** Draw 4 clusters. Label them. Have Idris repeat back the AWS accounts.

---

## Section 3 — The deployment flow (20 min)

Walk this same diagram **three times**, each time adding detail. Repetition is the point.

### Pass 1 — naive view (3 min)

```
git push → cluster
```

### Pass 2 — adds the pipeline (5 min)

```
git push                    Application repo (e.g., variant-inc/brands-api)
   ↓
GitHub Actions              builds + tests + pushes Docker image to ECR (account 064859874041)
   ↓
Octopus release             mage-runner creates an Octopus project + release with the new image tag
   ↓
Octopus deploy              human clicks "Deploy" in Octopus UI
   ↓
mage-runner runs            (this time in CD mode) and drives terraform-variant-apps
   ↓
terraform-variant-apps      creates per-app infra (S3, IAM role, Azure AD app, Kafka topics, MongoDB user)
                            and finally deploys the Helm chart
   ↓
Kubernetes cluster          app pod is running
```

### Pass 3 — adds the cloud↔on-prem split (12 min)

For a single app (say `brands-api`) deploying to **both** cloud and on-prem:

```
git push variant-inc/brands-api
   ↓
GHA → ECR (064859874041)
   ↓
   ├──→ Octopus USXpress space (Spaces-245)        [cloud path]
   │       ↓
   │    Deploy to dev/qa/prod EKS
   │       ↓
   │    mage-runner → terraform-variant-apps (main branch)
   │       ↓
   │    Cloud TF creates: Azure AD app, Kafka, Mongo Atlas user, K8s deploy
   │
   └──→ Octopus OnPremise space (Spaces-302)        [on-prem path]
           ↓ (mirror-release.py copies the release from cloud space)
        Deploy to op-usxpress-dev Talos
           ↓
        mage-runner (fork on feature/onprem-support) → terraform-variant-apps (fork)
           ↓ TF_VAR_use_eks_api=false
        On-prem TF skips: auth submodule, mongo-user submodule (those are cloud-only)
        On-prem TF creates: K8s deploy with extraSecrets pointing at azuread/mongo cert in SM
```

**Key insight to drill home:** the on-prem path *references* the Azure AD app and Mongo user that the cloud path created. It does not create its own. This is **the cloud↔on-prem rule**.

---

## Section 4 — Repo map (15 min)

Put up the table from the master plan (`idris_kt_master_plan.md` "Repo map"). Walk every row:

- **Cloud-team-owned**: don't push to these without Vibin sign-off.
- **On-prem-team-owned**: we move fast.
- **Forks**: live on `feature/onprem-support` branches; not merged upstream.

For each repo, give him a one-sentence "what this is" and tag whose ownership it falls under. Tell him we'll go deep on each one in the corresponding session.

**Show him the variant-inc GitHub org page.** Click into 3-4 repos so he sees the README of each.

---

## Section 5 — Cloud↔on-prem rule (15 min) ⭐ MOST IMPORTANT

This is the concept to *over-emphasize*. Slow down.

> **On-prem references cloud-created shared resources. It does not duplicate them.**

### The four shared-resource types

| Shared resource | Created by | On-prem consumes via |
|---|---|---|
| Azure AD app registration | Cloud `terraform-variant-apps/auth` module | ExternalSecret reads `azure-app-dx-<env>-<space>-<app>` from AWS SM (cloud-side TF writes to SM) |
| MongoDB Atlas user + cert | Cloud `terraform-mongodb-atlas-user` (or cloud azure_app submodule) | `<app>-m-u` cert via cross-cluster ESO bridge OR AWS SM |
| Kafka credentials | Cloud TF writes to AWS SM | Default ClusterSecretStore reads SM via IRSA |
| Generic AWS SM secrets | Cloud | On-prem ESO via IRSA (pod-identity-webhook injects AWS env into pod) |

### The on-prem gate

The mechanism that makes "reference don't duplicate" actually work:

```
TF_VAR_use_eks_api=false
```

When set, four things change:

1. **mage-runner** namespace.go skips ambient + privileged labels (those need real EKS API).
2. **terraform-variant-apps `api` module** injects `extraSecrets: [<app>-azuread-secret, ...]` into the chart values, instead of relying on the auth submodule's outputs.
3. **terraform-variant-apps `mongodb_user` submodule** is short-circuited (the v2 architectural fix using a fork of `terraform-mongodb-atlas-user`).
4. **DX-Apply patched script** reads cluster endpoint/CA/token from AWS SSM Parameter Store at `/clusters/op-usxpress-dev/*` instead of calling EKS DescribeCluster.

### Why this matters for him

If he understands this rule, he can read any on-prem code and predict its behavior. If he doesn't, every fork looks like magic.

**Whiteboard exercise:** Walk through one app deploy in detail. Pick `brands-api`. Show: Azure AD app exists in cloud (created Q1). On-prem deploy starts. `TF_VAR_use_eks_api=false`. mage skips auth. TF api module injects `extraSecrets: [brands-api-azuread-secret]`. K8s pod mounts that secret via envFrom. Pod talks to Azure AD using cloud-issued client_id/secret. → "If we destroyed the cloud Azure AD app, the on-prem pod would still have its credentials cached for ~1h, then break."

---

## Section 6 — Where RisingWave fits (10 min)

Light touch — Session 7 deep-dives this. The goal here is just to plant the flag.

- **What it is**: open-source streaming database. SQL syntax. Kafka in, materialized views, Postgres-compatible sink out.
- **Why us**: Knight-Swift wants real-time analytics on operational data we already publish to Kafka (truck telemetry, freight events). Tim Preble has been pushing it. Vibin signed off March 31.
- **Where it'll live**: `iaac-eks` repo, in `usx-dev` cluster first. Per Vibin: "RisingWave is an iaac-eks pattern."
- **Why his project**: ramp-up. It exercises iaac-eks (cluster IaC), ECR (image), AWS S3 (state store), IAM (IRSA), Kafka (consumer), and gets him into the cloud team's repos. Perfect 4-week onboarding project.
- **Pending blocker**: Tim Preble intro meeting. Schedule before week 4.

---

## Section 7 — Q&A + homework (5 min)

### Likely questions to be ready for

**"Why on-prem at all if cloud works?"**
→ AWS outage independence. Knight-Swift wants to operate during a regional AWS outage. See `design_doc_onprem_aws_outage_independence.md`.

**"Why Talos, not standard Linux + kubeadm?"**
→ Immutable, API-driven, minimal attack surface. The on-prem cluster is treated as cattle, not pets.

**"Why so many forks?"**
→ Vibin doesn't want on-prem changes to risk cloud stability. Forks let us iterate without blocking cloud team. PRs upstream once Vibin signs off.

**"Why isn't this in iaac-octopus-config?"**
→ It was. PR #89. Vibin closed it asking for separate on-prem repo. Result: iaac-octopus-onprem.

**"Cross-cluster ESO sounds scary."**
→ It is. POC only. Migration path is AWS SM as source. Don't bake it into prod work.

### Homework before Session 1

1. Clone these locally: `iaac-talos`, `iaac-talos-flux-platform`, `iaac-talos-flux-cluster`. Don't read code yet — just clone.
2. Get on the corp VPN. Confirm `kubectl --context op-usxpress-dev get nodes` returns 8 nodes.
3. Skim the iaac-talos README. One question to bring to Session 1.
4. Read `magerunner_deep_dive.md` if not already.

---

## Pitfalls to call out

- **Old docs reference dpl2.** When he sees dpl2 in any doc, the doc is pre-April 2026 and the cluster name is now op-usxpress-dev. The architecture concepts still apply.
- **"bm-dev" = "dpl2" = "op-usxpress-dev"** in different historical eras. They're all the same conceptual cluster, just renamed.
- **Cloud Octopus = Spaces-245 (USXpress).** On-prem Octopus = Spaces-302 (OnPremise). He'll see both.
- **"DX" is overloaded.** It refers to (a) the deployment system as a whole, (b) the patched scripts inside Octopus library variable sets, (c) sometimes the team that builds it. Context disambiguates.

---

## Recording / artifacts

- Record the whole session.
- Save the whiteboard photos to Drive.
- After session, send him the link to this doc + idris_kt_session1_talos_flux.md as pre-read for next time.
