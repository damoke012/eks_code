## What

Prepares `op-usxpress-prod` to serve RisingWave: corrects the six `risingwave-routes/` files, adds the missing TCP passthrough Gateway, and adds the metastore backup Schedule.

## The routes were a dev copy

Every file under `infrastructure/risingwave-routes/` on this branch carried **dev** values:

| File | Was | Now |
|---|---|---|
| `certificate-dashboard.yaml` | `risingwave-dashboard.op-dev…` | `…op-prod…` |
| `certificate-overview.yaml` | `risingwave-overview.op-dev…` | `…op-prod…` |
| `virtualservice-dashboard.yaml` | dev host + dev's 7 workers | prod host + prod's 10 workers |
| `virtualservice-overview.yaml` | dev host + dev's 7 workers | prod host + prod's 10 workers |
| `virtualservice-postgres.yaml` | dev host ×3 + dev's 7 workers | prod host ×3 + prod's 10 workers |
| `virtualservice-sql.yaml` | dev host ×3 + dev's 7 workers | prod host ×3 + prod's 10 workers |

Rewritten from `origin/op-qa`'s corrected copies, which carry the INFRA-1645 fix and its explanation. The target addresses are not a substitution — each cluster targets a different set of nodes — so they were read from **this cluster's own working `argocd` VirtualService**, which is the only local evidence of what actually resolves here.

**Why nothing looked wrong.** external-dns runs `--policy=sync` but keys ownership on `--txt-owner-id` in a DynamoDB registry. A route publishing another environment's hostname is silently skipped: no error, no event, no record, no conflict with the cluster that does own it. Tenth instance of this class; `op-qa` was the ninth.

## The Gateway both L4 routes already selected

`virtualservice-sql.yaml` and `virtualservice-postgres.yaml` name `tcp-passthrough`, and no such Gateway exists on this branch. A VirtualService bound to a missing Gateway reports no error, no status condition and no event — it simply never serves.

Ported from `op-qa`. No `release.yaml` change is needed: this branch's ingress DaemonSet already binds `hostPort` 4567 and 5432 (verified against `infrastructure/istio-ingress/release.yaml`, identical to QA's). `infrastructure/istio-ingress/` has no `kustomization.yaml`, so Flux generates one and the file reconciles from the directory.

## The metastore backup

S3 holds RisingWave's streaming state, but the Postgres metastore is a **PVC**, and a PVC does not survive a cluster teardown. This Schedule is the only thing that makes the metastore restorable.

`infrastructure/velero/kustomization.yaml` **enumerates its resources explicitly**, so the Schedule is listed there as well — a file dropped into that directory alone would sit in git and never be applied, which is the same silent-nothing failure the routes had.

## What this activates

- **Gateway + Schedule: immediately.** `istio-ingress` and `velero` are already wired in prod's `infra.yaml`.
- **Routes: not yet.** Prod's `infra.yaml` has no `risingwave-routes` Kustomization. They stay inert until that is added, which is deliberate — the routes should activate when the workload exists, not before.

## Verification

```
kubectl kustomize infrastructure/velero            # builds; Schedule present in velero ns
kubectl kustomize infrastructure/risingwave-routes # builds; all four hosts are op-prod
```

All four VirtualServices parse, name `op-prod` hosts, and select the right gateways. No `spec:` field in any file names another environment; the remaining `op-qa` / `op-dev` strings are provenance in comment headers.

After merge, `scripts/onprem-dns-claims.sh dev qa prod` should report no MISMATCH for prod's RisingWave routes.

## Known, not in this PR

`grafana`'s VirtualService on this branch still carries `grafana.op-dev.usxpress.io` and dev's seven addresses. Same defect, unrelated to RisingWave, and it deserves its own change rather than riding along here.
