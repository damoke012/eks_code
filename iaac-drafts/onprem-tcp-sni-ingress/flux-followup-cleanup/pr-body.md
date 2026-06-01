## Summary

Phase 1 (INFRA-1494) followup — two small cleanups identified in the closure trail (`wip/onprem-networking/phase1-closure-jun01.md`):

1. **Persist Gateway + VirtualService to GitOps source.** Both were `kubectl apply`'d during Phase 1 closure 2026-06-01 and are not yet under Flux inventory. A cluster rebuild would drop them. This PR puts them under Flux management.
2. **Move external-dns target from per-VS annotation to chart-level `--default-targets`.** Same effective A-record (all 7 worker IPs), but applies to every VS the chart sees — drift-resistant and scales to future TCP backends without per-resource annotation work.

## Changes

| File | Change |
|---|---|
| `infrastructure/istio-ingress/gateway-tcp-passthrough.yaml` | NEW. Same content as live `Gateway istio-ingress/tcp-passthrough`. TLS-PASSTHROUGH on 4567 + 5432. |
| `infrastructure/istio-ingress/virtualservice-rw2-sql.yaml` | NEW. Same content as live `VirtualService istio-ingress/rw2-sql-passthrough`, minus per-VS `external-dns.alpha.kubernetes.io/target` annotation. |
| `infrastructure/external-dns/release.yaml` | +7 lines under `values.extraArgs` — `--default-targets=<each of 7 worker IPs>`. |

## Test plan

- [ ] `flux reconcile source git infra` + `flux reconcile kustomization infrastructure` complete Ready=True
- [ ] `kubectl -n istio-ingress get gateway,virtualservice` shows Flux ownership labels (kustomize.toolkit.fluxcd.io/name)
- [ ] external-dns logs reference the new `--default-targets`
- [ ] `kubectl -n istio-ingress annotate virtualservice rw2-sql-passthrough external-dns.alpha.kubernetes.io/target-` removes per-VS annotation; A-record unchanged afterwards
- [ ] `getent hosts rw2-sql.op-dev.usxpress.io` returns all 7 worker IPs
- [ ] `openssl s_client -servername rw2-sql.op-dev.usxpress.io -connect ...:4567` still returns `CONNECTED + errno=104` (gateway accepted; backend RSTs pre-Phase-2)
- [ ] RW-2 healthy throughout (`kubectl get rw -n risingwave-2` Running=True before/after)

## Rollback

Revert PR → Flux removes from inventory → resources prune. Pre-revert mitigation if needed: `kubectl apply -f` the originals locally first (orphans them), then revert source.

## Refs

- Ticket: INFRA-1494 (Phase 1) — already in Done state; this is cleanup.
- Umbrella: INFRA-1492 (TCP/SNI ingress)
- Phase 1 closure: `wip/onprem-networking/phase1-closure-jun01.md`
