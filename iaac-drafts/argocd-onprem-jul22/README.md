# Argo CD on-prem — design and rollout (INFRA-1622)

**Repo:** `variant-inc/iaac-argocd-onprem` (created by Idris) · **Decision date:** 2026-07-22
**Supersedes:** PR `iaac-talos-flux-platform#73`, which added Argo CD inside the platform
branch pointed at a repo and namespace Flux already reconciles.

## Why this exists

Flux reconciles every platform component and `iaac-risingwave-onprem`. Argo CD adds nothing
to *that* job. It is being adopted for the one thing Flux does not serve: **app-team
self-service** — a UI, per-app RBAC, and developers syncing their own applications without
a platform PR.

That framing dictates the entire design below. Argo CD is an **app-layer** controller. It
must never touch a namespace Flux owns.

## Non-negotiable guardrails

| # | Rule | Enforced by |
|---|---|---|
| G1 | Argo CD manages **only** `app-*` namespaces | `AppProject.spec.destinations` glob |
| G2 | The permissive built-in `default` project is neutered | `appprojects.yaml` overwrites it with an empty allow-list |
| G3 | No cluster-scoped resources | `clusterResourceWhitelist: []` |
| G4 | No committed secrets | repo creds via ESO from SM |
| G5 | No NodePort — Istio ingress only | `server.service.type: ClusterIP` + VirtualService |
| G6 | Argo CD itself is installed **by Flux** | HelmRelease, reconciled from this repo |
| G7 | Overlays, not branch-per-env | `manifests/base` + `manifests/<cluster>` |

**G1/G2 are the split-brain protection.** PR #73's failure mode was Argo CD and Flux both
owning `risingwave` — Tim's namespace — with `ServerSideApply: true` fighting over field
ownership. The `default` AppProject ships allowing `'*'` destinations, so leaving it alone
would silently undo G1.

**G7 applies today's most expensive lesson.** Branch-per-env is what produced the dev-VIP
in QA's etcd CronJob (13 days of silent backup failure), dev SM paths in QA's Grafana, and
`external-dns txtOwnerId=op-usxpress-dev` still live on QA. A new repo should not inherit
that pattern. See `wip/qa-cluster-standup/PROD-AUTOMATION.md` §C.

## Layout

```
manifests/
  base/                      env-agnostic
    kustomization.yaml
    namespace.yaml
    helmrepository.yaml
    helmrelease.yaml
    appprojects.yaml
    externalsecret-repo-creds.yaml
  op-usxpress-dev/           overlay: SM prefix, hostname, replicas
  op-usxpress-qa/            overlay
cluster-wiring/
  argocd.yaml                -> iaac-talos-flux-cluster clusters/<cluster>/flux-system/
```

## Rollout order — dev first

Argo CD is **new**, unlike the RisingWave work which mirrors a running dev deployment.
Prove it on dev, then QA, then prod. QA is the prod-standard mirror, so anything landing
there should already be known-good.

1. **Dev** — merge, wire `clusters/bm-dev/`, verify guardrails (below)
2. **QA** — same overlay pattern, after dev is green for a few days
3. **Prod** — only once an app team is actually using it

## Verification — prove behaviour, not object existence

The recurring failure this week was healthy-looking objects that did nothing (Wiz secrets
synced green with 6-char placeholders; QA etcd's ExternalSecret green over a placeholder;
the Velero Schedule in the wrong namespace). Argo CD gets the same treatment:

```bash
# G1/G2 — the guardrail that matters. MUST be refused.
kubectl -n argocd get appproject default -o jsonpath='{.spec.destinations}'   # expect []
argocd app create probe --repo <repo> --path . --dest-namespace risingwave --dest-server https://kubernetes.default.svc
#   ^ MUST fail with "application destination is not permitted in project"

# G5 — no NodePort anywhere
kubectl -n argocd get svc -o jsonpath='{.items[*].spec.type}'    # expect all ClusterIP

# G4 — no literal Secret in git
git grep -nEi "sshPrivateKey|BEGIN .*PRIVATE KEY" -- manifests/    # expect no hits

# Flux owns it
flux get helmreleases -n argocd
```

**If the `probe` app is accepted into `risingwave`, stop the rollout.** That is exactly the
condition PR #73 was rejected for.

## Prerequisites (Doke)

- SM secret `op-usxpress-<env>/argocd/deploy-key` — a **new** GitHub deploy key.
  ⚠️ The `sshPrivateKey` committed in PR #73 is compromised and must be rotated
  regardless of what happens to that PR. Do not reuse it here.
- `cluster-wiring/argocd.yaml` into `iaac-talos-flux-cluster`.
- Istio Gateway name + hostname for the overlay (`VirtualService` is a TODO until confirmed
  against the live cluster — see the overlay comment).

## Deliberately deferred

- **Entra SSO** — dex/OIDC. Ties to the reusable service-account SSO pattern; admin login
  works meanwhile. Do not block rollout on Azure access.
- **HA** — single replica per component until an app team depends on it.
- **ApplicationSets** — no use case yet.
