# Session 6 — Supporting repos

**Duration:** 60 min (shorter than others — these are smaller scope)
**Goal:** Idris understands iaac-monitoring, iaac-flux-manifests, and the vendored amazon-eks-pod-identity-webhook. Knows when to touch each.
**Format:** Repo walk + a closer look at the IRSA webhook (since it's central to on-prem).

---

## Why this session is here

These three repos are smaller and less central than the previous five, but Idris will encounter all of them. iaac-monitoring is where Prometheus/Grafana lives (he'll consume it for RisingWave). iaac-flux-manifests is the cloud Flux repo (analogous to iaac-talos-flux-platform but for cloud EKS). amazon-eks-pod-identity-webhook is the IRSA bridge — vendored, occasionally needs patches.

---

## Prerequisites

- Cloned `iaac-monitoring`, `iaac-flux-manifests`, `amazon-eks-pod-identity-webhook`.
- Has access to Grafana (in cluster).

---

## Agenda (60 min)

| Time | Topic |
|------|-------|
| 0–5 | Recap |
| 5–20 | iaac-monitoring deep dive |
| 20–35 | iaac-flux-manifests vs iaac-talos-flux-platform |
| 35–55 | amazon-eks-pod-identity-webhook deep dive (IRSA on Talos) |
| 55–60 | Q&A |

---

## Section 1 — iaac-monitoring (15 min)

### What it is

The repo for our Prometheus/Grafana monitoring stack. Lives across both cloud EKS and on-prem.

### Layout

```
iaac-monitoring/
├── deploy/terraform/      # TF that deploys monitoring on EKS
│   └── modules/
│       ├── prometheus/
│       ├── grafana/
│       ├── alertmanager/
│       └── dashboards/
├── manifests/             # Raw K8s manifests (or kustomize)
└── README.md
```

### What it deploys

- **kube-prometheus-stack** (Helm chart) — Prometheus + Operator + Alertmanager + Grafana + node-exporter + kube-state-metrics.
- **Custom dashboards** (JSON definitions, mounted as ConfigMaps).
- **ServiceMonitors / PodMonitors** for app teams' workloads.
- **Alert rules** (PrometheusRules CRDs).

### Cloud vs on-prem

- **Cloud EKS clusters**: full kube-prometheus-stack with persistent storage, Grafana with auth, AlertManager wired to PagerDuty/Slack.
- **On-prem**: minimal Prometheus only (see Session 1 — no Grafana, no AlertManager, ephemeral storage). We'll grow this. AHV (Q4 2026) gives us proper persistent storage.

### What Idris will use it for (RisingWave)

RisingWave exposes Prometheus metrics (`/metrics` endpoint per component). We'll need:
1. ServiceMonitor pointing at RisingWave service.
2. Dashboard for RisingWave-specific metrics (compute throughput, materialized view freshness, S3 state-store IOPS).
3. Alert rules for RW-specific failures (compute pod OOM, materialized view lag).

These will land in iaac-monitoring as part of Session 7's project deliverable.

### Hands-on (5 min)

- Open Grafana in usx-dev EKS. Look at existing dashboards. Note the structure — folder per app domain.
- Show how a dashboard JSON gets into Grafana: ConfigMap with `grafana_dashboard: "1"` label, sidecar picks it up.
- Open a ServiceMonitor for an existing app. Read it. Predict what metrics it scrapes.

---

## Section 2 — iaac-flux-manifests vs iaac-talos-flux-platform (15 min)

### iaac-flux-manifests — cloud Flux

For cloud EKS clusters. Same purpose as iaac-talos-flux-platform but for cloud.

```
iaac-flux-manifests/
├── clusters/
│   ├── dev/
│   ├── qa/
│   └── prod/
├── infrastructure/         # Common manifests
└── apps/
```

Differences from iaac-talos-flux-platform:
- **No pod-identity-webhook** — EKS provides this built-in.
- **No CloudFront-fronted OIDC** — EKS has it natively.
- **AWS Load Balancer Controller** — used for Ingress; on-prem uses Istio Gateway/MetalLB instead.
- **EBS CSI driver** — for persistent storage; on-prem uses local PVs (until AHV).
- **More complete observability** — full Grafana + AlertManager.

### Why the split

Cloud Flux manifests assume EKS-specific resources. On-prem Flux manifests assume Talos-specific resources (Cilium L2 IPAM, ambient Istio without sidecar, etc.). Trying to share a single repo would require gating every manifest.

### What Idris should know

- He'll consume both at different times: iaac-flux-manifests when adding RisingWave to cloud Flux config; iaac-talos-flux-platform when migrating RW patterns to on-prem (post-MVP).
- **Don't push to iaac-flux-manifests without cloud team review** — it's prod-impacting.

---

## Section 3 — amazon-eks-pod-identity-webhook (20 min) — the IRSA bridge

This is the most important repo in this session. It's the *thing* that makes IRSA work on Talos.

### What it is

A vendored fork of [aws/amazon-eks-pod-identity-webhook](https://github.com/aws/amazon-eks-pod-identity-webhook). The original is open-source, designed to run as part of the EKS managed control plane. We extract it and run it as a Deployment inside on-prem clusters.

### What it does (mechanics)

It's a **Kubernetes MutatingAdmissionWebhook**. Steps:

1. K8s API server receives a Pod CREATE request.
2. K8s sees the Pod's ServiceAccount has annotation `eks.amazonaws.com/role-arn: arn:aws:iam::...:role/...`.
3. K8s calls the webhook (HTTPS POST with the AdmissionRequest).
4. Webhook patches the Pod spec to add:
   - Env var: `AWS_ROLE_ARN=arn:aws:iam::...:role/...`
   - Env var: `AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token`
   - Volume: a projected SA token volume mount (audience=`sts.amazonaws.com`).
5. K8s applies the patched spec; pod starts with these env vars.
6. AWS SDK in the pod sees `AWS_WEB_IDENTITY_TOKEN_FILE`, calls `sts:AssumeRoleWithWebIdentity` with the token.
7. STS verifies the token against the OIDC provider (which is registered in IAM and points at our CloudFront discovery URL).
8. STS returns short-lived AWS creds to the pod.
9. Pod uses creds to call AWS APIs.

### Repo layout

```
amazon-eks-pod-identity-webhook/
├── cmd/                    # Go entry point
├── pkg/                    # Webhook logic (mutator, cert handling)
├── deploy/                 # Kubernetes manifests for self-deploy
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── webhook.yaml        # MutatingWebhookConfiguration
│   └── rbac.yaml
├── Dockerfile
└── go.mod
```

### How we deploy it on Talos

In `iaac-talos-flux-platform/infrastructure/pod-identity-webhook/`:
- Deployment runs the webhook (`public.ecr.aws/eks/amazon-eks-pod-identity-webhook:latest`).
- Service (ClusterIP) exposes port 443.
- MutatingWebhookConfiguration registers the webhook with the API server.
- Certificate (cert-manager) provides TLS — webhook needs HTTPS.

The certificate has DNS names:
- `pod-identity-webhook.pod-identity-webhook.svc`
- `pod-identity-webhook.pod-identity-webhook.svc.cluster.local`

The MutatingWebhookConfiguration's caBundle is patched at install time from the cert-manager-issued cert.

### Why we vendor it

1. **Customization**: original assumes EKS-managed deployment; we run it standalone. Some flags differ.
2. **Image lifecycle**: AWS publishes the image to ECR Public. We could pull from there, but vendoring means we control the version + can patch.
3. **Future patches**: when we add support for non-EKS-style identity providers (audience customization, OIDC issuer overrides), the patches go here.

### What Idris should know

- **Don't break it.** Pod-identity-webhook is the keystone of on-prem IRSA. If it crashes, every pod that needs AWS access starts failing.
- **Cert rotation is automatic.** cert-manager renews the cert; the webhook reloads. But `MutatingWebhookConfiguration.caBundle` isn't auto-updated — there's a `cainjector` annotation that handles that.
- **Debugging IRSA failures** usually starts here:
  - `kubectl -n pod-identity-webhook get pods` — webhook running?
  - `kubectl -n <app-ns> describe pod <pod>` — does the pod have AWS_ROLE_ARN env? If not, webhook didn't fire.
  - `kubectl -n pod-identity-webhook logs <webhook-pod>` — admission errors?
  - Pod has env but can't assume role? Check IAM trust policy: subject must match `system:serviceaccount:<ns>:<sa>` exactly.
  - AssumeRole call succeeds but call fails? Check the IAM policy attached to the role.

### Compare to EKS

On EKS, this webhook is **part of the managed control plane**. You don't see it. You don't deploy it. AWS runs it for you. The Talos setup makes it visible — which is good for understanding, painful for ops.

---

## Section 4 — Q&A (5 min)

Common questions:

**"Why don't we use IAM Roles Anywhere instead?"**
→ Considered. Adds X.509 cert distribution complexity. IRSA via OIDC is simpler and matches EKS pattern.

**"What about EKS Pod Identity (the new AWS feature)?"**
→ It's EKS-only. We need on-prem support, so we stick with IRSA.

**"How is the OIDC discovery doc kept in sync?"**
→ Talos's API server signs SA tokens with a key. The corresponding public key (JWKS) is uploaded to S3 by the iaac-talos `irsa` module. If the key rotates, we re-upload. Currently manual; should automate.

---

## Homework before Session 7

1. Open Grafana, browse dashboards. Pick one app, look at its dashboard, understand the metrics graph layout.
2. Read the actual `MutatingWebhookConfiguration` YAML in cluster: `kubectl get mutatingwebhookconfiguration pod-identity-webhook -o yaml`.
3. Read this excellent blog post on IRSA: https://aws.amazon.com/blogs/containers/diving-into-iam-roles-for-service-accounts/ (the original IRSA explainer; everything we do is built on this).
4. Skim the RisingWave docs at https://docs.risingwave.com/ to prep for Session 7.

---

## Reference cheat sheet

| Repo | What's it for |
|---|---|
| iaac-monitoring | Prometheus/Grafana stack TF + dashboards |
| iaac-flux-manifests | Cloud EKS Flux manifests (counterpart to iaac-talos-flux-platform) |
| amazon-eks-pod-identity-webhook | Vendored IRSA webhook for Talos |

| Concept | Where it lives |
|---|---|
| Pod-identity-webhook deployment | `iaac-talos-flux-platform/infrastructure/pod-identity-webhook/` |
| MutatingWebhookConfiguration | Same path, `webhook.yaml` |
| Webhook image | `public.ecr.aws/eks/amazon-eks-pod-identity-webhook:latest` |
| OIDC discovery JWKS | S3 bucket from iaac-talos irsa module, fronted by CloudFront |
| OIDC provider in IAM | `aws_iam_openid_connect_provider.irsa` in iaac-talos irsa module |
