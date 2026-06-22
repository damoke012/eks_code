# istio-ingress IaC — staging artifacts (op-usxpress-dev)

Drafted 2026-05-13 in codespace. Copy to WSL and commit to the two on-prem GitOps repos:

- **Data plane** (platform-owned): `iaac-talos-flux-platform` branch `op-dev`, path `infrastructure/istio-ingress/`
- **Cluster wiring**: `iaac-talos-flux-cluster` branch `master`, path `clusters/bm-dev/flux-system/infra.yaml`
- **App Gateway** (smoke-test, hand-applied): `app-gateways/brands-api.yaml` — not in any Flux Kustomization yet

This is **piece 1 of 3** in the post-PTO networking plan
(see `steve_duck_networking_message_draft_may13.md` for the strategic frame and
`memory/onprem_networking_gap_may13.md` for the full plan).

## Cloud Gateway pattern (confirmed 2026-05-13 from existing on-prem VSes)

**Platform owns the data plane. App teams own their routing.**

- The `istio-ingressgateway` DaemonSet (this piece 1) is shared infrastructure with selector `istio: ingressgateway`.
- Each app creates its own `Gateway` resource in its own namespace (e.g. `enterprise/brands-api`, `attrition/attrition-api`).
- VirtualServices live in `istio-system` and reference the app-namespace Gateway by name.
- All 5 existing on-prem VSes follow this pattern. They were templated from cloud waiting on their Gateways.

**Open architectural question**: where do per-app Gateway YAML files live long-term?
- MageRunner/DX-generated alongside each app's deployment (matches cloud most closely)
- Or platform-managed in `iaac-talos-flux-platform/infrastructure/app-gateways/`
- Decided after smoke test. For now: hand-applied.

## What this deploys (piece 1 = data plane only)

- Namespace `istio-ingress` with PSA `enforce=privileged` (required for `hostNetwork: true`).
- HelmRelease `istio-ingressgateway` (chart `istio/gateway` v1.27.3, matches running istiod).
- Values ConfigMap: `kind: DaemonSet`, `hostNetwork: true`, worker-only affinity,
  container binds 80/443 directly via `NET_BIND_SERVICE` capability.

That's it. No Gateway resource shipped in piece 1.

## Files

| File | Destination | Owner |
|---|---|---|
| `infrastructure/istio-ingress/namespace.yaml` | `iaac-talos-flux-platform/op-dev` | platform |
| `infrastructure/istio-ingress/release.yaml` | `iaac-talos-flux-platform/op-dev` | platform |
| `infrastructure/istio-ingress/values.yaml` | `iaac-talos-flux-platform/op-dev` | platform |
| `cluster-kustomization-snippet.yaml` | append into `iaac-talos-flux-cluster/master` `infra.yaml` | platform |
| `app-gateways/brands-api.yaml` | hand-applied to `enterprise` namespace | enterprise team (we apply for smoke test) |
| `RUNBOOK.md` | reference — full deploy + rollback flow | platform |

## Order of operations (high-level)

1. **Pre-flight RW protection check** — RUNBOOK § 1
2. Push platform repo (manifests) + cluster repo (Kustomization wiring)
3. Watch Flux reconcile `istio-ingress` Kustomization (~5m)
4. **Post-flight RW protection check** — RUNBOOK § 5
5. **Smoke test**: apply `app-gateways/brands-api.yaml`; `curl -H "Host: api.brands.dev.usxpress.io" http://10.10.82.26/` from VPN → real brands-api response
6. **Post-smoke-test RW check again** — additive change but verify nothing drifted
7. Decide: wire remaining 4 VSes the same way (one at a time), or move on to piece 2 first

## What this does NOT do

- Public TLS (waits on piece 3 — cert-manager ClusterIssuer)
- DNS records (waits on piece 2 — external-dns + Route53, ONPREM-25)
- Modify any existing service. RW NodePorts (32567, 32546, 32114) keep working untouched.
- Wire the other 4 orphan VSes — separate follow-up after brands-api smoke test passes
