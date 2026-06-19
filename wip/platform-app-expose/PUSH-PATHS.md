# Push paths — `platform-app-expose` + Tim's RW exposure

WSL2 push instructions. Codespace can't reach cluster; you push from WSL2 after pulling these files.

## Repos involved

| Repo | Branch | Why |
|---|---|---|
| `variant-inc/iaac-talos-flux-platform` | `op-dev` | Chart + Tim's HelmReleases live here |
| `variant-inc/iaac-talos-flux-cluster` | `master` | Cluster wiring (Kustomization for risingwave-exposure) |

## File mapping (codespace → target repo)

| Codespace path | Target repo + path |
|---|---|
| `wip/platform-app-expose/chart/` | `iaac-talos-flux-platform op-dev` → `infrastructure/platform-app-expose/chart/` |
| `wip/platform-app-expose/risingwave-exposure/` | `iaac-talos-flux-platform op-dev` → `infrastructure/risingwave-exposure/` |
| `wip/platform-app-expose/cluster-kustomization-entry.yaml` | append to `iaac-talos-flux-cluster master` → `clusters/bm-dev/flux-system/infra.yaml` |

## PR sequence (low → high risk)

### PR 1 — Chart + Tim's dashboard exposure

**Repo:** `iaac-talos-flux-platform` (branch `op-dev`)
**New branch:** `feat/platform-app-expose-rw-dashboard`
**Files:**
- `infrastructure/platform-app-expose/chart/Chart.yaml`
- `infrastructure/platform-app-expose/chart/values.yaml`
- `infrastructure/platform-app-expose/chart/templates/_helpers.tpl`
- `infrastructure/platform-app-expose/chart/templates/virtualservice.yaml`
- `infrastructure/platform-app-expose/chart/templates/certificate.yaml`
- `infrastructure/platform-app-expose/chart/templates/cnp.yaml`
- `infrastructure/risingwave-exposure/kustomization.yaml`
- `infrastructure/risingwave-exposure/rw-dashboard-helmrelease.yaml`
- `infrastructure/risingwave-exposure/rw-sql-helmrelease.yaml` *(suspended; safe to land)*

**PR title:** `feat: platform-app-expose chart + Tim's RW dashboard exposure (INFRA-1527)`

**PR body:**
```
## What
- Introduces `platform-app-expose` Helm chart: reusable ingress + TLS pattern
  for any namespace. Composes with shared-http Gateway + tcp-passthrough Gateway
  + cert-manager + Cilium.
- First consumer: Tim's RW namespace.
- Dashboard HelmRelease is live; SQL HelmRelease is `suspend: true` until Tim's
  ghostunnel sidecar lands.

## Risk
- Additive only. Existing NodePort services in `risingwave` ns stay up.
- CNP off by default. Will be turned on after Tim inventories consumers.
- Chart pulled from this repo's `infra` GitRepository (Flux source).

## INFRA-1527
```

### PR 2 — Cluster wiring

**Repo:** `iaac-talos-flux-cluster` (branch `master`)
**New branch:** `feat/wire-risingwave-exposure`
**File:** `clusters/bm-dev/flux-system/infra.yaml`
**Change:** append the contents of `cluster-kustomization-entry.yaml` at the end of the file.

**PR title:** `feat: wire risingwave-exposure Kustomization (INFRA-1527)`

**PR body:**
```
## What
Wires the `risingwave-exposure` directory from iaac-talos-flux-platform
into Flux reconcile loop. dependsOn istiod + cert-manager-issuers.

## INFRA-1527
```

**Order matters:** merge PR 1 first (so the source dir exists), then PR 2 (so Flux finds it on reconcile).

### Post-PR validation

Once both PRs merge + Flux reconciles:

```bash
kubectl -n flux-system get kustomization risingwave-exposure
# Ready=True

kubectl -n risingwave get helmrelease
# rw-dashboard-expose: Ready=True
# rw-sql-expose: Suspended=True

kubectl -n istio-ingress get virtualservice rw-dashboard-expose-http
# Spec OK

dig rw-dashboard.op-dev.usxpress.io
# Resolves to worker IPs (via external-dns)

curl -fsv https://rw-dashboard.op-dev.usxpress.io/
# 200 OK + LE-prod chain
```

### Follow-up — SQL exposure (after Tim's sidecar)

When Tim's ghostunnel sidecar on `risingwave-frontend` is live:

```bash
kubectl -n risingwave patch helmrelease rw-sql-expose --type merge -p '{"spec":{"suspend":false}}'
```

Flux reconciles, VS comes up. Validate:

```bash
openssl s_client -connect rw-sql.op-dev.usxpress.io:4567 -servername rw-sql.op-dev.usxpress.io
# Verification: OK against LE-prod chain
psql 'host=rw-sql.op-dev.usxpress.io port=4567 sslmode=require dbname=dev user=root'
```

Then PR a code change to remove `suspend: true` from the HelmRelease yaml (so it stays unsuspended on next reconcile).

### Follow-up — CNP

Once Tim has inventoried his consumers + cut over from NodePort:

1. Update `rw-dashboard-helmrelease.yaml` + `rw-sql-helmrelease.yaml` to set `cnp.enabled: true`
2. If Tim's consumers include non-default namespaces, add them to `cnp.allowedNamespaces`
3. Validate: existing consumers still work; unauthorized sources blocked

### Follow-up — Tim retires NodePort

Tim removes the 3 NodePort services in his `risingwave` ns. Validate dashboard + SQL still reachable via the chart-driven path.

## Verification before push

Things to confirm against the live cluster before pushing PR 1:

1. **`infra` GitRepository name** — confirm via `kubectl -n flux-system get gitrepository`. If named something other than `infra`, update both `cluster-kustomization-entry.yaml` and the HelmRelease `sourceRef.name`.
2. **external-dns target** — `kubectl -n istio-ingress get virtualservice rw2-sql-tcp -o yaml | yq '.metadata.annotations'`. The `external-dns.alpha.kubernetes.io/target` value RW-2 uses is what we should mirror. If RW-2 uses a different hostname (or worker-IP list), update both HelmRelease files.
3. **Service name + port for Tim's dashboard** — `kubectl -n risingwave get svc`. Defaults assume `risingwave-dashboard-ext:5691`. Adjust if Tim's actual Service name + port differ.

## Risk + rollback

| PR | Rollback |
|---|---|
| PR 1 | Revert. Chart removed; HelmRelease removed. Tim's setup unchanged (NodePort stayed live). |
| PR 2 | Revert. Flux Kustomization removed; HelmRelease orphaned but not actively reconciling. Safe. |
| Post-merge | `kubectl -n flux-system delete kustomization risingwave-exposure` → all chart-driven resources pruned. ~5 seconds. |

No impact to RW-2. No impact to Tim's existing NodePort consumers. The only invasive piece is the SQL sidecar (later, gated on Tim).
