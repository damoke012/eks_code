---
name: wiz-sensor-onprem-dev
description: "Wiz eBPF runtime sensor deployed to op-usxpress-dev via Flux (INFRA-1586) — CP exclusion verified live, blocked only on the real Wiz token"
metadata: 
  node_type: memory
  type: project
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
  modified: 2026-07-20T15:22:16.253Z
---

Wiz runtime sensor (eBPF DaemonSet, chart 1.0.11492) deployed to **op-usxpress-dev** with Steve Vives. **INFRA-1586** (sprint), not INFRA-1505 (I mislabeled the commits/PRs as 1505 — fix traceability).

**Shipped + verified live 2026-07-17:**
- PR **variant-inc/iaac-talos-flux-platform#74** (merged) — HelmRepository + HelmRelease + values ConfigMap + 2 ExternalSecrets under `infrastructure/wiz-sensor/`, base branch `op-dev`.
- PR **variant-inc/iaac-talos-flux-cluster#25** (merged) — wires the Flux Kustomization into `clusters/bm-dev/flux-system/infra.yaml` (path `./infrastructure/wiz-sensor`, sourceRef `infra` GitRepository = iaac-talos-flux-platform@op-dev, dependsOn external-secrets).
- **CP exclusion HELD live**: 7 sensor pods, one per worker (talos-wk-op-dev-1..7), ZERO on the 3×8GB control-planes, held through a full rollout. Proven in the rendered chart (`tolerations: []` overrides chart's `operator: Exists`; nodeAffinity `DoesNotExist` on control-plane + master). This was THE risk given the 2026-06-17 CP OOM cascade. RisingWave (both ns) unaffected.

**BLOCKED on the token (ONLY remaining item — no engineering left).** As of 2026-07-20: all 7 pods `ImagePullBackOff` on `wizio.azurecr.io`; both ExternalSecrets `SecretSynced True`. **Everything else is proven working** — ESO plumbing validated end-to-end (SM → ClusterSecretStore → k8s Secret; it faithfully synced junk, proving ESO checks *shape* not *content*), and CP exclusion held across multiple rollouts (7 pods / 7 workers / 0 CPs).

SM `op-usxpress-dev/platform/wiz/sensor-token` `AWSCURRENT` = **placeholder junk** (literal `<real>` strings, version `3f25fa1c`, written 2026-07-20). **4 placeholder seeds so far** — every time I hand Doke a *runnable* command containing placeholders, it gets run verbatim. **RULE: never provide a runnable `put-secret-value` until the real values are actually in hand** — describe it, or have it read from a file/env, so there is no placeholder to submit.

**Exact SM contract** (verified from `infrastructure/wiz-sensor/externalsecrets.yaml` header, single JSON entry, 4 distinct keys):
`{"clientId":..,"clientToken":..,"pullUsername":..,"pullPassword":..}` — `clientId`/`clientToken` = Wiz sensor service account for **registration** (names are a hard contract with the chart: `wizApiToken.secret.create=false` expects exactly these); `pullUsername`/`pullPassword` = **pull key for `wizio.azurecr.io`**. The current ImagePullBackOff is specifically the **pull key**; clientId/clientToken only matter after the image pulls.

Real values are Steve Vives' to supply via 1Password **wiz-sensor-onprem** — open question is whether it's *populated* vs merely *not shared* to doke@usxpress.com. Fix when they land: `put-secret-value` (NOT `create-secret` — it exists) on profile `usx-dev` → `kubectl -n wiz annotate externalsecret wiz-api-token sensor-image-pull force-sync=$(date +%s) --overwrite` → `kubectl -n wiz rollout restart daemonset wiz-sensor`. ⚠️ The kubectl half needs `export KUBECONFIG=~/.kube/op-usxpress-dev.yaml` + VPN and a `kubectl cluster-info` check for `10.10.82.50` — the default kubeconfig points at **prod** ([[wsl-kubeconfig-churn]]); a stale SSO token was the only thing that stopped a prod hit on 2026-07-20.

**Decisions recorded:** no CP runtime coverage in dev (revisit QA where CPs spec'd 16GB — [[qa-cluster-standup]] / INFRA-1560); PSA `privileged` on `wiz` ns accepted (inherent to privileged eBPF + hostPath cache). **Follow-up:** chart's `node-role.kubernetes.io/master` affinity term throws a deprecation warning every apply — drop in a later PR.

Related: [[qa-cluster-standup]], [[onprem-deploy-via-octopus]].
