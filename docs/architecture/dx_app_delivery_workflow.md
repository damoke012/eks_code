# DX app delivery — release → Octopus → Terraform → Kubernetes → runtime

How an application on the AWS EKS estate (`usxpress-dev` / `qa-one` / `usxpress-prod`) gets from a
git push to a running pod, and what it depends on once it's there.

Reconstructed from live inspection during the 2026-08-10 `orders-api` outage. Sections marked
**(inferred)** are pattern-matched rather than read from source — verify before relying on them.

---

## The seven artifacts every app has

Learn these names once and you can find anything. For an app called `mosh` in group
`mcleod-data-sync`, production:

| Layer | Name |
|---|---|
| Source repo | `variant-inc/mcleod-orders-sync-handler` |
| Container image | `064859874041.dkr.ecr.us-east-2.amazonaws.com/mcleod-data-sync/mcleod-orders-sync-handler:0.2.8` |
| Octopus project | `mosh` (space `USXpress`) |
| Entra app registration | `dx-prod-usxpress-mosh` — App ID URI `api://dx-prod-usxpress-mosh` |
| AWS Secrets Manager | `azure-app-dx-prod-usxpress-mosh` |
| Kubernetes ConfigMaps | `mosh-chart` (app config) + `mosh-api-apps` (outbound auth scopes) |
| Kubernetes workload | `Deployment/mosh` in namespace `mcleod-data-sync` |

The namespace is the **group**; the deployment is the **project**. Both are stamped on every object
as labels: `cloudops.io.octopus/project`, `cloudops.io.octopus/group`,
`cloudops.io.octopus/environment`, `cloudops.io/revision`.

---

## Stage 1 — source to release

```
git push
   ↓
GitHub Actions (variant-inc)
   ├─ build + test
   ├─ docker build → push to ECR  064859874041.dkr.ecr.us-east-2.amazonaws.com/<group>/<repo>:<ver>
   └─ package deploy/ → push a RELEASE to Octopus   (.github/workflows/octo.yaml)
```

A release is cut on **every branch push**, not just main. The release is a versioned bundle; it does
nothing until it is *deployed* to an environment.

---

## Stage 2 — Octopus deploys, and Terraform runs

Octopus picks a worker, assumes `arn:aws:sts::937464026810:assumed-role/octopus-usxpress/*`, and runs
Terraform (`terraform-variant-apps`). Each app's `spec` drives a set of shared modules.

```
terraform-variant-apps
   └─ modules/common/auth  →  github.com/variant-inc/terraform-azuread-app?ref=v5.0
        ├─ azuread_application.main_app            ← the app's IDENTITY
        │     display_name    = dx-<env>-usxpress-<name>
        │     identifier_uris = ["api://dx-<env>-usxpress-<name>"]
        ├─ azuread_application_password.main_app   ← client secret
        ├─ azuread_application_api_access           ← permission to call OTHER apps
        ├─ azuread_application_pre_authorized       ← which client apps may call THIS one
        └─ aws_secretsmanager_secret "azure-app-dx-<env>-usxpress-<name>"
              recovery_window_in_days = 0           ⚠ deletion is irreversible
              secret_string = { AUTH__ClientId, AUTH__ClientSecret, AUTH__TenantId,
                                AUTH__IdentifierUri, AUTH__IssuerUrl, AUTH__Scopes,
                                AUTH__TokenEndpoint, AUTH__CallbackUrl }
```

**The critical output** — `outputs.tf` generates the app's outbound scopes by looking up *other*
apps' client IDs at apply time:

```hcl
"AUTH__ApiAppScopes__${app.reference}" = "${data.azuread_application.api_apps[app.name].client_id}/.default"
```

That is a **snapshot of another app's identity, frozen at this app's deploy time.** Nothing
refreshes it later. This is the single most important thing to understand about the platform's
auth model — see "Where the outage fits" below.

Other modules in the same run provision S3 buckets, IRSA roles, and similar per-app AWS resources.
**(inferred — not read directly.)**

---

## Stage 3 — Kubernetes objects

Terraform/Helm then renders the workload. For each app:

```
namespace <group>
├─ Deployment/<app>              image from ECR, Istio sidecar injected at admission
├─ Service/<app>                 :8080 http, :9000 grpc (varies by app)
├─ ConfigMap/<app>-chart         app settings — Kafka, Mongo, base URLs, OTEL, Pyroscope
├─ ConfigMap/<app>-api-apps      AUTH__ApiAppScopes__* — who this app may call
├─ ExternalSecret/<app>-azuread-secret
│     ClusterSecretStore "default" → AWS Secrets Manager, refresh 24h
│     dataFrom.extract.key = azure-app-dx-<env>-usxpress-<app>
│     └─ Secret/<app>-azuread-secret   ← consumed via envFrom
├─ Secret/<app>-m-u              MongoDB Atlas client certs (mounted at /etc/mongodb/certs)
└─ PodMonitor, HPA/KEDA ScaledObject   (per app)
```

**Auth values reach the process by `envFrom`, not by the pod template.** This is why *rolling back a
Deployment does not roll back credentials* — every ReplicaSet references the same Secret, whose
content is whatever ESO last pulled.

Ingress for public APIs:

```
api.<app>.usxpress.io
   → external-dns (Route53) → Istio ingressgateway → Service → pod :8080
   cert-manager issues TLS; Istio sidecar emits the JSON access log
```

---

## Stage 4 — runtime dependencies

What a typical handler actually talks to, using `mosh` as the worked example:

```
                         ┌──────────────────────────────┐
   Confluent Cloud ─────▶│                              │
   (Kafka topics,        │        Deployment/mosh       │
    batch 100 / 10s)     │   (10 replicas, .NET)        │
                         │                              │
   MongoDB Atlas ◀───────┤  order.orders                │
   PrivateLink           │  readPreference=secondary    │
   pl-0-us-east-2…       │  certs from Secret <app>-m-u │
                         │                              │
   orders-api ◀──────────┤  token from Entra using      │
   allocation (Fade) ◀───┤  AUTH__ApiAppScopes__*       │
   missions-api ◀────────┤                              │
   Mulesoft ◀────────────┤  (separate hardcoded client) │
                         │                              │
   AWS (S3, SM) ◀────────┤  IRSA — OIDC, no keys        │
                         │                              │
   OTEL → Grafana/Loki ◀─┤  otel_logs_custom            │
   Prometheus ◀──────────┤  PodMonitor                  │
   Pyroscope ◀───────────┤  continuous profiling        │
                         └──────────────────────────────┘
```

**Service-to-service auth, step by step:**

1. mosh reads `AUTH__ApiAppScopes__orders` from `mosh-api-apps` → e.g. `dfa69e93…/.default`
2. mosh authenticates to Entra with its own `AUTH__ClientId` + `AUTH__ClientSecret` (client credentials)
3. Entra checks mosh's **app-role assignment** on the target, then issues a token with
   `aud` = the target's client ID (`requestedAccessTokenVersion: 2`)
4. mosh calls `orders-api` with that bearer token
5. orders-api validates `aud` against **its own** `AUTH__ClientId` — mismatch is `IDX10214`

Both halves must be right: the **scope** (which resource) and the **role assignment** (permission
to ask for it). A config change fixes only the first.

**Infrastructure underneath:** Karpenter provisions Bottlerocket/Graviton nodes; Cilium is the CNI
(overlay `172.24.0.0/16`); Istio provides mTLS and access logs; Flux reconciles platform addons;
Argo CD is the app-layer controller for `app-*` namespaces only.

---

## Where the 2026-08-10 outage fits

Every deploy of an app **destroys and recreates** `azuread_application.main_app`, so the app gets a
brand-new client ID. Consumers hold that ID frozen from their own last deploy.

```
13:50  graphql-gateway deploys  →  captures orders-api client ID 992e68a9
16:28  orders-api deploys       →  registration destroyed + recreated (new ID)
16:42  orders-api deploys again →  another new ID
17:24  consumers' cached tokens expire  →  100% 401 begins
18:30  orders-api deploys again →  dfa69e93 (current)
```

18 consumers were left pointing at `992e68a9`, which no longer existed. The recreation also
destroyed every consumer's app-role assignment, so **changing the scope string alone fails** with
`AADSTS501051`. Only a full consumer release fixes both halves.

Full triage runbook: [`/prod-auth-triage`](../../.claude/skills/prod-auth-triage/SKILL.md).

---

## Known gaps in this workflow

1. **`outputs.tf` emits `client_id`, not `identifier_uris[0]`.** The URI is deterministic
   (`api://dx-${env}-${name}`) and survives recreation; the GUID does not. One-line fix, removes the
   whole failure class.
2. **Deploys delete the app registration.** Rotating a password should never destroy the
   application. Root fault behind every occurrence.
3. **`recovery_window_in_days = 0`** destroys the only copy of the credential; no rollback possible.
4. **No back-reference.** Nothing notifies or redeploys a consumer when a callee's identity changes.
5. **Cross-service client IDs also live in `*-chart` ConfigMaps** under arbitrary keys
   (`OrdersLumperApi__AUTH__ClientId`, `Mulesoft__Authorization__ClientId`) — outside the
   `AUTH__ApiAppScopes__*` convention, so they escape any sweep that only checks that prefix.
6. **Apps log no HTTP.** `otel.logging.enabled: false` means the istio-proxy access log is the only
   source of truth for request outcomes.
