# Round 1 — RW-2 NodePort cleanup + dashboard routing

## What lands

| PR | Repo | Files | Purpose |
|---|---|---|---|
| A1 | iaac-risingwave-2 | `manifests/op-usxpress-dev/frontend-ext.yaml` (modify) + `dashboard-ext.yaml` (modify) + `ghostunnel-rw2-sql.yaml` (modify) | NodePort → ClusterIP on both -ext services; ghostunnel probes → httpGet :9090; ghostunnel reloader annotation |
| A2 | iaac-talos-flux-platform | `infrastructure/istio-ingress/virtualservice-rw2-dashboard.yaml` (NEW) + (optional) `release.yaml` (drop default-targets) | HTTP VS for `rw2-dashboard.op-dev.usxpress.io` on shared-http Gateway; route to `risingwave-meta.risingwave-2.svc:5691` |

## Why NodePort removal is safe

- `risingwave-frontend-ext` (NodePort:4567:30674) — duplicate of operator-managed `risingwave-frontend` ClusterIP. Phase 2 already routes through `ghostunnel-rw2-sql.risingwave-2.svc` → `risingwave-frontend.risingwave-2.svc:4567`. NodePort was a TLS bypass.
- `risingwave-dashboard-ext` (NodePort:5691:30371) — was the only path to the dashboard. After A2 lands, dashboard accessible via `https://rw2-dashboard.op-dev.usxpress.io` (TLS terminated at shared-http Gateway with the `*.op-dev.usxpress.io` wildcard cert).

Both services are converted to ClusterIP (not deleted) — preserves the Service name; just removes the NodePort allocation. Anyone hitting NodePort gets connection refused (intentional); anyone hitting the Service DNS continues working.

## Risk

- Tim's `risingwave` ns is unaffected (different namespace; track-separation rule).
- If someone outside the platform team has bookmarked `<worker-ip>:30371` for the dashboard, their bookmark dies. We log this in the PR description.
- `risingwave-frontend-ext` NodePort 30674 was a parallel TLS bypass for psql — anyone using it was bypassing the cert we issued. Closing it is the right thing.
