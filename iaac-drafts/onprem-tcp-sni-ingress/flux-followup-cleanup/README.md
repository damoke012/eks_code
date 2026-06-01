# Phase 1 followup cleanups — persist + de-annotate

Two small followups identified in `wip/onprem-networking/phase1-closure-jun01.md`:

1. **Persist `Gateway tcp-passthrough` + `VirtualService rw2-sql-passthrough` to GitOps source.**
   Today they live only as `kubectl apply`'d resources. If the cluster rebuilds (or someone runs `flux reconcile ... --reset`), they vanish.
2. **Move the `external-dns.alpha.kubernetes.io/target` annotation off per-VS** onto the external-dns chart `--default-targets` flag. Same outcome (A-record points at all 7 worker IPs), but applies to every VS without per-resource annotation drift risk.

Both ride into one PR on `variant-inc/iaac-talos-flux-platform` `op-dev`.

## Files in this folder

| File | Lands at (in upstream `op-dev`) | Purpose |
|---|---|---|
| `gateway-tcp-passthrough.yaml` | `infrastructure/istio-ingress/gateway-tcp-passthrough.yaml` | Same as currently kubectl-applied. Hosts `*.op-dev.usxpress.io` on TLS-PASSTHROUGH ports 4567 + 5432. |
| `virtualservice-rw2-sql.yaml` | `infrastructure/istio-ingress/virtualservice-rw2-sql.yaml` | Same as currently kubectl-applied, MINUS the per-VS target annotation. external-dns picks up the hostname annotation; the target IPs come from `--default-targets`. |
| `external-dns-release-delta.md` | Patch description for `infrastructure/external-dns/release.yaml` (`extraArgs` block) | Adds 7 worker IPs as `--default-targets`. |
| `wsl-runbook.md` | (runs on WSL, doesn't land in repo) | Step-by-step paste-able commands |

## Pre-flight pause

If `infrastructure/istio-ingress/` already uses a `kustomization.yaml` instead of a flat-directory layout, both YAMLs need a `resources:` line added too. Inspect on WSL **before** the commit:

```bash
ls repos/iaac-talos-flux-platform/infrastructure/istio-ingress/
test -f repos/iaac-talos-flux-platform/infrastructure/istio-ingress/kustomization.yaml \
  && echo "NEED kustomization.yaml update" \
  || echo "flat dir — drop YAMLs directly"
```
