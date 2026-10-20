# What Octopus does today, where DX fits, and where every variable comes from

**Date:** 2026-10-20. **Subject:** the pricing application, first app through the on-prem
intake. **Companion:** `ONBOARDING-pricing-app-onprem-2026-10-20.md` (the on-prem side).

**Scope warning, up front.** Every mechanic below is **measured** — but measured on
`iaac-talos`, `iaac-risingwave-onprem`, `ix-kafka-topics-users` and
`netradyne-coaching-session-sync`, not on the pricing project. **Nothing in this document is
a reading of the pricing app's own Octopus configuration**, because nobody has read it yet.
§5 is how to read it, and it can be done today without waiting for Matt.

---

## 0. The answer up front

**Shrikant is not asking to keep Octopus.** Andres asked the Octopus question — *"why didn't
we just add something in Octopus to create a similar deploy YAML and push it to the on-prem
Kubernetes… what's the big push for Argo?"* Shrikant then answered it himself: *"I think
Andres's question was more of why you guys have chosen the path. I don't think he was
necessarily asking for path changing."* What he did ask for, twice, is **parity**: *"I would
like to see some level of feature parity between what you guys are building on-prem versus
cloud, because what I don't want to do is lose what we already got in cloud… as long as you
give us the same functionality, that doesn't bother me personally."*

So the thing to answer is §8, the parity table — not a tooling debate.

**Octopus does four separable jobs for an app.** Only one of them is contested:

| | Job | Who cares | On-prem |
|---|---|---|---|
| 1 | **Variable store** — per-environment config and secrets | **the app team, a lot** | replaced by a values file + Secrets Manager |
| 2 | **Release and promotion gate** | the app team, somewhat | replaced by a promotion PR per environment |
| 3 | **Runner of DX-Apply** — creating the app's AWS resources | nobody, until it breaks | replaced by our own Terraform |
| 4 | **Deployer** — applying manifests to EKS | nobody | replaced by Argo CD |

**Can we keep it?** For cloud, yes — that is already the decision and nothing is changing
there *"for a very long time"*. For on-prem app deploys, no, and **the blocker is not Octopus,
it is DX**. Octopus does not know how to deploy this app on its own: DX generates the
manifests and creates the AWS resources, and Octopus runs DX. Keeping Octopus for on-prem
means bringing DX on-prem, which is the one thing Doke has ruled out, with a reason:
*"implementing DX on-prem is not a minor endeavour… it's tied to the cloud."*

Worth saying out loud to the app team, because it defuses the argument: **Octopus is already
staying.** On-prem uses it to build the Talos clusters. What moves is app deployment.

---

## 1. Octopus, job by job

### Job 1 — the variable store

This is the part that matters and the part the app team is attached to. Doke's own
description: *"one of the key things it does for us is it manages our variables. You have
those application variables that are stored in Octopus that are used during runtime."*

How it works: a project holds a flat list of **project variables**. Each has a name, a value,
an optional **environment scope**, and an **IsSensitive** flag. At deploy time Octopus
substitutes them into whatever the deployment process emits.

**Measured properties, all four of which have cost us real time:**

| Property | Consequence | Where measured |
|---|---|---|
| Variables live **in a web form, in no repo, under no review** | `iaac-talos` has 121 `TF_VAR_*` maintained by hand; `iaac-octopus-config` creates spaces, environments, pools and lifecycles but **no `octopusdeploy_variable`** | `octopus-config-builds-the-stage-not-the-play` |
| A **release freezes** the variable snapshot | correcting a variable does nothing to an existing release; the log prints the stale value with no hint a newer one exists. Cost two identical prod failures 2026-09-01 | `octopus-release-freezes-variables` |
| **`[ALL]` scope hides inheritance** | a tool that copies what an environment scopes *explicitly* never sees inherited values. QA2 planned 13 VMs for a 4-VM cluster | `octopus-all-scope-hides-inherited-values` |
| **A non-sensitive value prints into the deploy log** | Matt, unprompted: *"sometimes those sensitive Octopus fields can just dump right into the log"* | his own words, 2026-10-20 |

That last row is the one to carry into the conversation. It is the single place where the new
path is **plainly better** than the old, and the app developer raised it himself.

### Job 2 — release and promotion gate

Dev deploys **on commit**; QA and prod are **manual** — Andres: *"we do QA deployments
manually… dev on commit."* That shape survives on-prem unchanged (dev automatic, QA and prod
by PR), so there is nothing to argue about here.

⚠️ One measured variant to watch for: in `ix-kafka-topics-users` the **dev deploy runs from
the branch and is a required check before merge** (`octopus-deploy-can-gate-the-pr`). If the
pricing project is wired that way, removing Octopus removes a merge gate, and that has to be
replaced deliberately rather than noticed later.

### Job 3 — runner of DX-Apply

Octopus does not create the app's AWS resources; it **runs DX's Terraform** on an Octopus
worker (a pod from `variant-inc/iaac-octopus`). Two measured traps:

* **`TfApply=false` by default.** The step prints the full plan — `Plan: 0 to add, 3 to
  change` — then skips `terraform apply` and exits 0. **Green means a plan was printed.** The
  printed plan makes it *more* convincing, not less. Grep the log for `Apply complete!`.
* **The worker is shared and fills up.** Twelve apps × ~2.8 GB of provider cache on a 40 GB
  volume; the app that deploys last fails on `no space left on device` and it reads as an app
  fault (`dx-apply-triage`).

### Job 4 — deployer to EKS

Applies the DX-generated manifests. Replaced one-for-one by Argo CD, which the app team gets
*more* from, not less: Doke's pitch — drift management, per-app visibility, live logs, restart
a service. The honest caveat is in §8.

### What Octopus does **not** do

* **It does not build the image.** GitHub Actions already builds and pushes to ECR, and
  Octopus pulls from there — Andres: *"I think we upload the image in the GitHub Action to ECR
  and then Octopus uses that image."* That is why on-prem reuses the existing ECR repository
  and why the build question is already closed.
* **It does not decide secret values.** For a DX-deployed app most secrets are DX's.

---

## 2. Where DX fits, and why it is the actual blocker

DX is custom USX code (`terraform-variant-apps` + modules), run by Octopus, and it is what
makes an app deployable at all today. Four jobs:

| DX does | Evidence | Why it matters on-prem |
|---|---|---|
| **Generates the deployment YAML** — limits, replicas, probes | Andres: *"they generate the deployment YAML files on the DX side"*; Shrikant was learning this on the call | **the app repo contains no sizing and the app team has never set it.** Read it off the live cluster |
| **Creates the app's AWS resources in Terraform, including its secrets, and injects them into EKS** | Andres: *"the Terraform handles all that. It creates the AWS secrets for the cloud deployments and then injects them into EKS as secrets"* | this is the **second variable source**, invisible in Octopus and unknown to the app team |
| **Creates — and destroys — the Entra app registration on every deploy** | measured 2026-08-10: new client ID every deploy, consumers break with `AADSTS500011`/`IDX10214`, and a config change does not fix it | if this app authenticates through Entra, the migration has an identity hazard nobody has mentioned |
| **Provisions services** (Mongo, Postgres) | Andres: *"it already provisions Mongo, it can provision Postgres"* | on-prem those become platform-orchestrated by agreement |

**So "keep Octopus" is really "keep DX",** and DX is leaving — not because Octopus is bad but
because DX is a bespoke product that needs a team behind it and is tied to the cloud. Doke's
framing, which is the one to repeat: *"Octopus has not really been the enemy… it's DX."*

---

## 3. The runtime supply chain today — the map

Where each class of configuration is **housed**, and how it **reaches the running pod**.

```
  Octopus project variables ──┐
  (scoped per environment,    │
   IsSensitive flag)          ├──► substituted into the DX-generated manifest
                              │       ──► env vars / ConfigMap on the pod
  DX Terraform  ──► AWS       │
  Secrets Manager ────────────┴──► injected into EKS as a k8s Secret ──► env
  GitHub Actions ──► ECR ─────────► image pulled by the Deployment
```

| Config class | Housed today | Supplied at runtime by | On-prem equivalent | Status |
|---|---|---|---|---|
| Non-sensitive app config | **Octopus project variable**, env-scoped | substitution into the manifest → env / ConfigMap | `values-<env>.yaml` in the platform repo, reviewed in a PR | built |
| Sensitive config **Octopus holds** | **Octopus sensitive variable** | substitution → env var. ⚠️ can print into the deploy log | AWS Secrets Manager → ESO → k8s Secret | built |
| Sensitive config **DX creates** | **AWS Secrets Manager**, written by DX's Terraform | DX injects a k8s Secret; pod reads `secretKeyRef` | same store, but **we** write the value | built, but we must learn what DX writes |
| Service coordinates (Mongo, Postgres) | DX Terraform output | injected as above | platform-owned, by agreement | per-service decision |
| **OTEL endpoints** | **Octopus-injected variables** — *"it injects certain variables to help it know where all the otel endpoints are"* | env vars read by the OTEL SDK | `values-<env>.yaml` | ⚠️ **nothing does this yet** |
| Entra client ID / secret | DX, **recreated every deploy** | env | one app registration, a redirect URI per environment, secret copied | open — does this app use it? |
| Image | GitHub Actions → ECR | Deployment pulls it | **same ECR repo**, pinned by digest, promoted by PR | decided |
| CPU / memory / replicas | **DX-generated. In no repo.** | the Deployment spec | `values-<env>.yaml` | read off live prod |

**Three readings of that table worth stating plainly:**

1. **The inventory has two halves and only one is visible to the app team.** Octopus's half
   they can read; DX's half they cannot. That is exactly why *"all of ours should be in
   Octopus"* and *"we have SQL passwords in sensitive variables and I'm not sure DX provisions
   them"* were said minutes apart and both were honest.
2. **The OTEL row is the dangerous one.** It is non-sensitive, nobody thinks of it as config,
   and if it is missing the app starts, Argo CD is green, the pod logs to nowhere, and the
   dashboard the team actually uses stays empty. Nothing reports it.
3. **Sizing is not a variable at all today.** It is generated. On-prem it becomes a declared
   value, which is an improvement — and the first time anyone has to decide it on purpose.

---

## 4. The two axes, applied

Every row above sorts into one of four cells. Ownership and secret-ness are **independent**;
a three-way ownership split always strands keys (`secret-and-owner-are-two-axes`).

| | non-sensitive | sensitive |
|---|---|---|
| **platform-owned** | ConfigMap / values file, **our** PR — OTEL endpoints, service hostnames | Secrets Manager, **we** write the value — anything that rotates or expires |
| **app-owned** | values file, **their** PR — feature flags, timeouts, business config | Secrets Manager, **they** give key names, we write it once — partner tokens, their SQL passwords |

**The test for platform ownership is expiry, not secrecy** — Doke, in both calls: *"anything
that is going to be expiring, things that should be abstracted away from the application
itself, those should live within the platform processes, and those should be created as
infrastructure as code."*

**And the approver is the app developer, not us.** *"We can only propose at the end of the
day. The application developer that understands the in and out of the application is the one
that approves."* A classification recorded without Matt's sign-off is an unsigned change to
his app.

---

## 5. Collecting the inventory — start now, do not wait

**Status: NOT COLLECTED.** It is open item 1 from the call, owned by Matt. But the Octopus
half does not need him — it is an API call, and reading it first means he reviews a list
instead of writing one.

`scripts/octopus-dump-app-vars.py` prints every variable's **name**, environment scope and
sensitive flag, never a sensitive value, and seeds a classification sheet. It also raises the
three findings that matter, which a hand-written list would never surface:

* **named like a credential and not flagged sensitive** — already in plain text in Octopus and
  in every deploy log that substituted it. Treat as disclosed and rotate on the move.
* **compound values** — one variable carrying host, port, database *and* password cannot be
  classified as one thing. This is exactly what Matt offered to change: *"if you want to give
  us a connection string instead of pieces of it… I'd be willing to make that change myself."*
  His instinct is right and the direction is the opposite of what he assumed — **split** it, or
  the password rides into git inside a value labelled config.
* **`[ALL]`-scoped** — inherited by every environment and invisible to anything that copies
  explicit scopes.

Run it on WSL, in **bash**, where the Octopus key lives. One block, nothing is written
anywhere but `/tmp`:

```bash
( cd ~/eks_code 2>/dev/null || cd /mnt/c/code/eks_code 2>/dev/null || true
  if [ ! -f scripts/octopus-dump-app-vars.py ]; then
    echo "NOT MEASURED - not in the eks_code checkout, cd there first"
  elif [ ! -f "$HOME/.octopus-api-key" ]; then
    echo "NOT MEASURED - no ~/.octopus-api-key on this box; a key is needed, not a login"
  else
    python3 scripts/octopus-dump-app-vars.py --project pricing --tsv /tmp/pricing.vars.tsv
  fi )
```

If the project's name is not literally "pricing", that prints a NOT MEASURED naming the bad
filter rather than an empty list that reads like an empty project. Shorten the substring and
re-run.

**The DX half cannot be read this way.** It needs 30 minutes with **Parul or Rohit** —
Doke's own instruction on the call — to answer one question: *for this app, which AWS secrets
and which services does DX create at deploy time, and what key names does it inject?*

**The inventory is complete when all four buckets are accounted for**, and "Octopus had
nothing else" is not completeness:

1. Octopus project variables (readable today)
2. Octopus **library variable sets** the project includes (the script follows these)
3. AWS secrets **DX creates** (Parul/Rohit)
4. Anything the app reads from the **environment of the pod** that nobody declared — found
   only by reading the app's own configuration code, which is Matt's half

---

## 6. If Octopus goes away — what has to be replaced

| Octopus job | On-prem replacement | Status |
|---|---|---|
| Variable store, non-sensitive | `values-<env>.yaml` in the platform repo | **built.** Reviewed, audited, diffable — which is the point |
| Variable store, sensitive | AWS Secrets Manager → External Secrets → k8s Secret | **built.** Proven on dev and QA |
| Which variables exist at all | a **declaration** next to the code, validated in CI | **designed, not built** — `DESIGN-variable-contract-2026-10-19.md` |
| Release + promotion gate | promotion PR per environment, digest-pinned; prod waits for a person | **built for RisingWave**, generic version designed |
| DX-Apply — the app's AWS resources | our own Terraform in our own repos | **the real gap.** This is the "100% IaC coverage" work |
| Deployer | Argo CD | **built and proven** |
| Image build | unchanged — GitHub Actions → ECR | **nothing to do** |

**What is genuinely lost, and should be conceded rather than argued:** today an app team can
open a web form, see every variable for every environment, and change one without a PR. On-prem
that becomes a pull request. For them that is slower. It is also the entire point — review,
history, and an environment that can be rebuilt from git — but calling it a pure upgrade would
be dishonest and they will notice. Say it is a deliberate trade and name what they get: a
change that cannot be made by accident, and a config that is not lost when a release snapshot
freezes.

**And one capability we owe them in exchange:** a way to *see* their effective configuration
per environment without reading three files. Argo CD's resource view partly does it. Nobody
has checked whether it is enough.

---

## 7. Can we keep it? Three options, honestly costed

**A — Keep Octopus for on-prem app deploys.** Requires DX on-prem to generate manifests and
create AWS resources. Doke: *"implementing DX on-prem is not a minor endeavour."* Also
abandons drift management and GitOps reconciliation, since an Octopus push is a one-shot
apply, not a controller. **Cost: high. Benefit: familiarity. Already ruled out.**

**B — Octopus for cloud, Argo CD on-prem.** The decision. The app team learns exactly one new
thing: where their variables live. Image build, observability, release cadence and the
promotion shape are unchanged. **Cost: one concept. This is the recommendation.**

**C — Hybrid: Octopus stays the variable store of record for cloud while on-prem reads git +
Secrets Manager.** This is not a choice — it is what will actually be true for as long as the
app runs in both places. The trap is that the same app then has **two variable sources that
will drift**, silently, and a cloud-side correction will not reach on-prem. Mitigation, and it
needs an owner: **one direction of copy only** (cloud → on-prem, never both), and a dated
reconciliation each time either side changes, until cloud follows. Without that, the first
production incident after a cloud variable fix will look like an on-prem fault.

---

## 8. What to say to Shrikant — the parity table

This is his actual question. Status column is honest, including where it is unknown.

| Cloud capability today | On-prem answer | Status |
|---|---|---|
| **Aggregated log search across all pods** from one Grafana dashboard | the same dashboard — logs go OTEL → `otel_logs_custom` exactly as now, **provided the OTEL endpoint variables are carried into the values file** | **designed, not built.** The one real gap |
| P90/P95 metrics per dependency | unchanged; same OTEL pipeline | designed, same gap |
| Per-pod live logs | Argo CD, **plus** what they have today | better |
| See every app in one place | Argo CD application list | better |
| Restart a service without a deploy | Argo CD | **new** — they cannot do this today |
| Config drift detection and repair | Argo CD self-heal | **new** |
| Change a variable without a PR | no — it becomes a PR | **a deliberate regression**, see §6 |
| Rollback | re-point the digest, merge | equivalent, by PR |
| Log retention | unknown on both sides — nobody on the call knew | **unowned** |

**The honest headline:** everything they rely on is preserved, two things improve, one thing
gets slower on purpose, and one — aggregated logging — is a real gap we have named and not yet
closed. Leading with that gap is what makes the rest credible.

---

## Proven

* Octopus performs **four separable jobs** for an app; only the variable store is contested,
  and the build is not one of them — GitHub Actions already pushes to ECR.
* **DX, not Octopus, is what cannot come on-prem**, and DX is what generates the manifests and
  creates the app's AWS resources. "Keep Octopus" is "keep DX".
* The config inventory for a DX-deployed app has **two halves**; the app team can only see one.
* `TfApply=false` means **green ≠ applied**, in two repos, so it is a house convention.
* An Octopus **release freezes** its variable snapshot; a corrected variable never reaches an
  existing release.
* **`[ALL]` scope is invisible to anything that copies explicit scopes.**
* A non-sensitive Octopus value **prints into the deploy log** — stated by the app's own
  developer, and the strongest argument for the move.
* Shrikant's requirement is **parity, not Octopus**, and he said so after deflecting Andres's
  Octopus question himself.

## Tested and killed

* **"Shrikant wants to keep Octopus."** Killed by reading the transcript: Andres asked, and
  Shrikant explicitly said it was not a request to change path.
* **"We could run the on-prem deploy from Octopus."** Killed on the dependency, not the
  preference — it needs DX on-prem.
* **Asking the app team for CPU, memory and replicas.** Killed: DX generates them and the app
  team has never set them.
* **`docker-compose.yml` as the variable inventory.** Killed by Andres — local development
  only, *"may not even work correctly"*.
* **Giving the app a single connection string** (Matt's offer). Right instinct, wrong
  direction: a compound value cannot be classified, so **split** it instead.

## Not measured

* **The pricing project's own Octopus variables.** Zero read so far. §5 is the instrument.
* **Which AWS secrets and services DX creates for this app** — needs Parul or Rohit.
* **Whether this app uses Entra auth**, and therefore whether the per-deploy app-registration
  recreation is a migration hazard for it.
* **Whether the pricing project's dev deploy is a required merge check**, as
  `ix-kafka-topics-users`'s is. If it is, removing Octopus removes a merge gate.
* **Which ECR repository and account** the app's build actually pushes to. RisingWave's is
  `064859874041 / us-east-2`; do not assume this app's is the same.
* **Log retention**, on either side.

## Traps

* **Octopus is already staying.** It builds the Talos clusters. Arguing "Octopus versus Argo
  CD" concedes a framing that is not true and makes the change sound bigger than it is.
* **A green Octopus task proves a plan was printed**, not that anything applied — and the
  printed plan is what makes it convincing.
* **"All our variables are in Octopus" is honest and incomplete.** Enumerate both halves.
* **A variable named like a credential but not flagged sensitive is already disclosed.**
  Rotate it on the move; do not just reclassify it.
* **The OTEL endpoint variables have no home on-prem yet.** Miss them and logging dies green.
* **Octopus and git as two variable stores will drift**, and the drift surfaces as an on-prem
  fault after a cloud fix. One direction of copy, with an owner.
* **We propose the classification; Matt approves it.** Not the other way round.
