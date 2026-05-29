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

## Agenda (105 min)

| Time | Topic |
|------|-------|
| 0–10 | Knight-Swift / USXpress / Variant context — who we are, who Vibin is, who Cloud Team is |
| 10–25 | What we run + where: 3 cloud EKS + 1 on-prem Talos |
| 25–45 | The deployment flow end-to-end — single slide, repeated 3 times in increasing detail |
| 45–55 | Repo map — one-line per repo, group by ownership |
| 55–90 | Cloud↔on-prem rule (the most important concept) — with real code |
| 90–100 | Where RisingWave fits |
| 100–105 | Q&A + homework |

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

## Section 5 — Cloud↔on-prem rule (35 min) ⭐ MOST IMPORTANT

This is the concept to *over-emphasize*. Slow down. We're going to walk through real code from the repos here.

> **On-prem references cloud-created shared resources. It does not duplicate them.**

### The metaphor

Think of an Azure AD app like a **Spotify Family Plan password**:
- One person creates the plan and gets the password (cloud).
- Family members use the *same* password to log in (on-prem).
- If everyone created their own plan, you'd have 5 separate accounts paying separately and nothing shared.

That's the cloud↔on-prem rule: **one resource, many consumers**.

### The four shared-resource types — and the two paths

| Shared resource | Created by | Where the secret lives | On-prem reads via |
|---|---|---|---|
| Azure AD app registration | Cloud `terraform-variant-apps/auth` module | **AWS Secrets Manager** as `azure-app-dx-<env>-<space>-<app>` | "default" ClusterSecretStore (AWS SM provider, IRSA auth) — **Path 1** |
| Generic AWS SM secrets | Cloud | **AWS Secrets Manager** | "default" ClusterSecretStore — **Path 1** |
| Kafka credentials | Cloud `kafka` TF module | **Cloud cluster K8s Secret** in app's namespace | "cloud-eks" ClusterSecretStore (Kubernetes provider, bearer token) — **Path 2** |
| MongoDB Atlas user + cert | Cloud `terraform-mongodb-atlas-user` | **Cloud cluster K8s Secret** of type `kubernetes.io/tls` | "cloud-eks" ClusterSecretStore — **Path 2** |

⚠️ **The original design treated everything as Path 1, but Kafka and Mongo currently use Path 2.** This is the SPOF concern (covered below). Migration to Path 1 for both is on the roadmap.

### Path 1 — AWS SM bridge (clean) — walked through with real code

**Example: `brands-api` Azure AD app**

The shared inbox is AWS Secrets Manager (in USX-Dev account 700736442855). The slot is named:

```
azure-app-dx-dev-usxpress-brands-api
```

Inside is JSON: `{ "client_id": "...", "client_secret": "...", "tenant_id": "..." }`. **Cloud puts it there. On-prem reads it out. Neither creates a duplicate.**

**Cloud path (when brands-api deploys to cloud):**
1. Mage reads `spec.yaml`. Sees `infrastructure.auth: { scopes: [...], redirect_uris: [...] }`.
2. Mage runs the `auth` TF module → calls Azure AD → creates app `dx-dev-usxpress-brands-api` → writes credentials to AWS SM at the path above.
3. Mage runs the `api` module → deploys Helm chart → chart wires up an ExternalSecret reading from SM → pod gets creds via envFrom.

**On-prem path (when brands-api deploys to on-prem)** — three things change:

**Change #1: We strip `infrastructure.auth` from spec.yaml before mage runs.**

The patched DX-Apply step in Octopus (see [iaac-octopus-overrides/patch-dx-apply.py](iaac-octopus-overrides/patch-dx-apply.py)) injects this PowerShell + inline Python that runs before mage:

```python
# Inline Python in DX-Apply — patch-dx-apply.py:127-167
import sys
STRIP_KEYS = ["auth"]    # ← removes infrastructure.auth
p = sys.argv[1]          # path to spec.yaml
with open(p) as f:
    lines = f.readlines()
out = []
in_strip = False
for line in lines:
    matched = None
    for k in STRIP_KEYS:
        if line.rstrip("\n").rstrip() == "  " + k + ":":
            matched = k; break
    if matched:
        in_strip = True   # found "  auth:" — start dropping lines
        continue
    if in_strip:
        if line.strip() == "" or line.startswith("    "):
            continue       # still inside the auth block — drop
        in_strip = False   # back to top level — stop dropping
    out.append(line)
with open(p, "w") as f:
    f.writelines(out)
```

So on-prem mage **never sees** `infrastructure.auth`. It cannot try to create an Azure AD app. Without the strip, on-prem would create a *duplicate* Azure AD app with the same name — split-brain auth.

**Change #2: A Flux-managed ExternalSecret bridges from AWS SM into the on-prem cluster.**

See [iaac-octopus-overrides/flux-manifest-brands-api-app-secret.yaml](iaac-octopus-overrides/flux-manifest-brands-api-app-secret.yaml):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: brands-api-azuread-secret
  namespace: enterprise              # on-prem brands-api lives in 'enterprise' ns
spec:
  refreshInterval: 1h                # re-pull from SM every hour
  secretStoreRef:
    kind: ClusterSecretStore
    name: default                    # ← AWS SM via IRSA
  target:
    name: brands-api-azuread-secret  # creates a K8s Secret with this name
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: azure-app-dx-dev-usxpress-brands-api    # ← the SM slot cloud writes to
```

**Change #3: How does on-prem ESO actually authenticate to AWS SM?**

Through [iaac-talos-flux-platform/infrastructure/external-secrets-config/clustersecretstore.yaml](iaac-talos-flux-platform/infrastructure/external-secrets-config/clustersecretstore.yaml):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: default
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-2
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets       # ← ESO ServiceAccount
            namespace: external-secrets
```

The `external-secrets` SA has an IRSA annotation pointing at IAM role `op-usxpress-dev-external-secrets`. Pod-identity-webhook injects AWS env into the ESO pod. ESO calls AWS STS using its projected SA token. STS hands back creds. ESO calls AWS SM `GetSecretValue`. **Same creds the cloud cluster's ESO would use, just from on-prem.**

### Path 2 — Cross-cluster K8s bridge (POC, SPOF risk) — walked through with real code

**Example: `geoenrichment-sync-handler` (geo-handler) — needs Kafka creds + Mongo X.509 cert**

These secrets are written by cloud TF directly to **K8s secrets in the cloud cluster** (not to AWS SM). So we built a Kubernetes-to-Kubernetes bridge.

**Step 1 — Cloud creates the secrets normally.** When geo-handler deploys to cloud EKS:
- mage's `kafka` module → Confluent gives SASL creds → chart creates K8s secret `geoenrichment-sync-handler-kafka-creds` in cloud cluster's `geoservices` namespace.
- mage's `mongodb` module → Atlas mints X.509 cert → cloud TF writes K8s secret `geoenrichment-sync-handler-m-u` (type `kubernetes.io/tls`) in cloud's `geoservices` namespace.
- These secrets live **only on the cloud cluster**.

**Step 2 — Cloud team plants a ServiceAccount + read-only Role + long-lived bearer token.**

[iaac-octopus-overrides/cross-cluster-eso/cloud-rbac/onprem-reader-geoservices.yaml](iaac-octopus-overrides/cross-cluster-eso/cloud-rbac/onprem-reader-geoservices.yaml) — applied to **cloud** EKS:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: onprem-secret-reader
  namespace: geoservices
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: onprem-secret-reader
  namespace: geoservices
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]   # ← READ-ONLY, geoservices ns ONLY
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: onprem-secret-reader
  namespace: geoservices
roleRef: { kind: Role, name: onprem-secret-reader, apiGroup: rbac.authorization.k8s.io }
subjects: [{ kind: ServiceAccount, name: onprem-secret-reader, namespace: geoservices }]
---
apiVersion: v1
kind: Secret                # ← long-lived SA token (K8s 1.24+ pattern)
metadata:
  name: onprem-secret-reader-token
  namespace: geoservices
  annotations:
    kubernetes.io/service-account.name: onprem-secret-reader
type: kubernetes.io/service-account-token
```

**Step 3 — On-prem ops one-time extracts the token and plants it on the on-prem cluster.**

`bootstrap-onprem-token.sh` runs:

```bash
# Pull token from cloud
kubectl --context=cloud-usxpress-dev get secret onprem-secret-reader-token \
  -n geoservices -o jsonpath='{.data.token}' | base64 -d > token.txt

# Plant on on-prem
kubectl --context=op-usxpress-dev create secret generic cloud-eks-reader-token \
  --from-file=token=token.txt -n external-secrets-system
```

**Step 4 — On-prem defines a second ClusterSecretStore that points at the cloud cluster's K8s API.**

[iaac-octopus-overrides/cross-cluster-eso/cluster-secret-store/cloud-eks.yaml](iaac-octopus-overrides/cross-cluster-eso/cluster-secret-store/cloud-eks.yaml) — applied to **on-prem**:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: cloud-eks                    # ← named "cloud-eks", different from "default"
spec:
  provider:
    kubernetes:                       # ← Kubernetes provider, not AWS
      remoteNamespace: geoservices
      server:
        url: "https://<cloud-eks-api-endpoint>"
        caBundle: "<base64-CA>"
      auth:
        token:
          bearerToken:
            name: cloud-eks-reader-token       # ← the secret we planted in Step 3
            key: token
            namespace: external-secrets-system
```

**Step 5 — Per-app ExternalSecrets pull what's needed.**

[iaac-octopus-overrides/cross-cluster-eso/app-secrets/geoenrichment-sync-handler.yaml](iaac-octopus-overrides/cross-cluster-eso/app-secrets/geoenrichment-sync-handler.yaml):

```yaml
# Kafka SASL creds
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: geoenrichment-sync-handler-kafka-creds
  namespace: geoservices
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: cloud-eks }     # ← cross-cluster store
  target: { name: geoenrichment-sync-handler-kafka-creds, creationPolicy: Owner }
  dataFrom:
    - extract: { key: geoenrichment-sync-handler-kafka-creds }      # ← exact name in cloud's geoservices ns
---
# Mongo X.509 cert — note the type preservation
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: geoenrichment-sync-handler-m-u
  namespace: geoservices
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: cloud-eks }
  target:
    name: geoenrichment-sync-handler-m-u
    template: { type: kubernetes.io/tls }                            # ← preserve TLS type
  dataFrom:
    - extract: { key: geoenrichment-sync-handler-m-u }
```

Every hour, on-prem ESO calls cloud's K8s API and pulls these secrets. Pod mounts via envFrom (Kafka) and TLS volume mount (Mongo).

### Side-by-side: the two paths

```
┌─────────────────────── Path 1: AWS SM (clean) ────────────────────────┐
│   Azure AD                                                            │
│     │                                                                 │
│     ▼                                                                 │
│   AWS Secrets Manager                                                 │
│     ▲                                       ▲                         │
│     │ (default store, IRSA)                 │ (default store, IRSA)   │
│   Cloud ESO                               On-prem ESO                 │
│     │                                       │                         │
│   Cloud pod                              On-prem pod                  │
└───────────────────────────────────────────────────────────────────────┘

┌──────────── Path 2: Cross-cluster K8s (POC, SPOF risk) ───────────────┐
│   Confluent Kafka / Mongo Atlas                                       │
│     │                                                                 │
│     ▼                                                                 │
│   Cloud cluster K8s Secret  (in geoservices ns)                       │
│     ▲                                       ▲                         │
│     │ envFrom                               │ on-prem ESO calls cloud │
│     │                                       │  K8s API (bearer token) │
│   Cloud pod                                 │                         │
│                                          On-prem ESO                  │
│                                              │                        │
│                                       On-prem K8s Secret              │
│                                              │ envFrom                │
│                                          On-prem pod                  │
└───────────────────────────────────────────────────────────────────────┘
```

### Why Path 2 is the SPOF — and the migration plan

In Path 2, **on-prem depends on the cloud cluster being reachable**. If the cloud cluster goes offline:
- Existing on-prem K8s secrets keep working (cached locally on the on-prem cluster).
- After the 1-hour refresh fails, ESO logs errors but doesn't delete the secret.
- If a creds rotation happens during the outage, on-prem can't pull the new value → on-prem pod's auth eventually breaks.

This is the SPOF concern flagged by [memory: onprem_prod_readiness_cross_cluster_eso_spof.md] — **for prod, we MUST migrate Kafka and Mongo to Path 1 (AWS SM)**.

The fix is two changes per shared resource:
1. **Cloud TF**: have the kafka / mongo modules ALSO write to AWS SM (in addition to the current K8s Secret writeback).
2. **On-prem ExternalSecret**: change `secretStoreRef.name` from `cloud-eks` to `default`.

Cloud-side TF skeleton for Kafka:
```hcl
# Proposed addition to terraform-variant-apps/modules/infrastructure/kafka/main.tf
resource "aws_secretsmanager_secret" "kafka_creds" {
  name = "${var.app_name}-kafka-creds"
}

resource "aws_secretsmanager_secret_version" "kafka_creds" {
  secret_id = aws_secretsmanager_secret.kafka_creds.id
  secret_string = jsonencode({
    bootstrap_servers = confluent_service_account.app.bootstrap_servers
    api_key           = confluent_api_key.app.api_key
    api_secret        = confluent_api_key.app.api_secret
  })
}
```

### Mongo's extra wrinkle (the trickiest one)

Mongo has **three pieces** that have to converge on one Atlas user:

| Piece | Lives where | On-prem behavior |
|---|---|---|
| Atlas user (cloud-issued) | Mongo Atlas | Cloud creates. On-prem **skips** (fork gate on `use_eks_api` in `terraform-mongodb-atlas-user`) so we don't double-create. |
| X.509 cert (K8s Secret type tls) | Cloud cluster's K8s | On-prem reads via cross-cluster ESO bridge (Path 2). |
| Connection string (ConfigMap `<app>-m-u`) | Each cluster's K8s | Cloud and on-prem each generate locally — same Atlas SRV, same DB name. |

This is also why `patch-dx-apply.py` strips `auth` but **deliberately keeps `mongodb` in the spec**:

```python
STRIP_KEYS = ["auth"]    # mongodb intentionally NOT in this list
```

The fork (`terraform-mongodb-atlas-user` with `use_eks_api` gate) prevents the **Atlas user creation** submodule from running — so we don't double-create the user — while still letting mage generate the `m-u` ConfigMap with the connection string. The actual cert Secret comes via the cross-cluster ESO bridge.

So the Mongo path is:
- **User (in Atlas)**: cloud creates, on-prem skips (fork gate on `use_eks_api`).
- **Cert (K8s Secret of type tls)**: cloud writes to K8s, on-prem reads via cross-cluster ESO bridge.
- **Connection string (ConfigMap)**: cloud and on-prem each generate locally.

Three pieces, three different mechanisms, all converging on one Atlas user.

### The on-prem gate

The mechanism that makes "reference don't duplicate" actually work across all of this:

```
TF_VAR_use_eks_api=false
```

When set, four things change:

1. **mage-runner** (`internal/kube/namespace.go`) skips ambient + privileged labels (those need real EKS API + a different Pod Security Admission posture).
2. **terraform-variant-apps `api` module** injects `extraSecrets: [<app>-azuread-secret, ...]` into the chart values, instead of relying on the auth submodule's outputs.
3. **terraform-variant-apps `mongodb_user` submodule** is short-circuited (the v2 architectural fix using a fork of `terraform-mongodb-atlas-user`).
4. **DX-Apply patched script** reads cluster endpoint/CA/token from AWS SSM Parameter Store at `/clusters/op-usxpress-dev/*` instead of calling EKS DescribeCluster, AND strips `infrastructure.auth` from spec.yaml.

### How to recognize the pattern in code

Whenever Idris is reading on-prem code, drill these two questions:

1. **"Is this resource one cloud creates?"** (Azure AD apps, Mongo users, Kafka topics, anything in AWS SM)
   - Yes → look for an **ExternalSecret** in the on-prem path that reads it.
   - Yes → look for a **strip or gate** somewhere that prevents on-prem from re-creating it.

2. **"Is this resource on-prem-only?"** (the cluster itself, IRSA OIDC for Talos, on-prem Octopus space)
   - Yes → on-prem fully owns the lifecycle. No cloud reference.

Once he internalizes this, every fork, every patch, every odd-looking config will make sense — they're all consequences of "reference don't duplicate."

### Why this matters for him

If he understands this rule, he can read any on-prem code and predict its behavior. If he doesn't, every fork looks like magic.

**Whiteboard exercise:** Walk through one app deploy in detail. Pick `brands-api`. Show: Azure AD app exists in cloud (created Q1). On-prem deploy starts. `TF_VAR_use_eks_api=false`. DX-Apply preflight strips `infrastructure.auth`. Mage skips auth module. TF api module injects `extraSecrets: [brands-api-azuread-secret]`. K8s pod mounts that secret via envFrom. Pod talks to Azure AD using cloud-issued client_id/secret. → "If we destroyed the cloud Azure AD app, the on-prem pod would still have its credentials cached for ~1h, then break."

Then do it again for `geoenrichment-sync-handler` to expose Path 2 — cross-cluster bridge, SPOF risk, three-piece Mongo.

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

**"Why is Path 2 needed at all? Why don't all secrets go to AWS SM?"**
→ Historical. The cloud charts/modules wrote Kafka and Mongo creds directly into K8s secrets because consumers were on the same cluster. Nobody bothered routing through SM. When we built on-prem, we had to read those secrets from somewhere — so we built Path 2. The fix is to extend cloud TF to *also* write to SM, then point on-prem at SM. That's prioritized for prod readiness.

**"What happens if cloud cluster is down?"**
→ Path 1 (Azure AD, generic SM): unaffected — AWS SM is independent. Path 2 (Kafka, Mongo): existing on-prem secrets keep working from cache; new rotations break. This is exactly the SPOF we want to kill.

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
