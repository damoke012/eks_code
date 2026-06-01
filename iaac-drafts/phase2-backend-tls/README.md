# Phase 2 — Backend TLS on RW-2 frontend (INFRA-1495)

**Goal:** Light up TLS termination at `risingwave-frontend.risingwave-2.svc:4567` so the end-to-end SNI route through the istio-ingress gateway hands off to a TLS-speaking backend. After this, `psql 'host=rw2-sql.op-dev.usxpress.io port=4567 sslmode=require ...'` works from corp VPN.

## What lands

| File | Lands at | Purpose |
|---|---|---|
| `certificate.yaml` | `iaac-risingwave-2:main` → `manifests/op-usxpress-dev/certificate.yaml` | cert-manager `Certificate` issued by `letsencrypt-prod` for `rw2-sql.op-dev.usxpress.io`, stored as Secret `rw2-sql-tls` in `risingwave-2` ns |
| `tls-options.md` | (decision doc — not committed) | Compares native RW TLS vs ghostunnel sidecar. Pick on WSL based on operator version |
| `rw-cr-tls-patch-native.yaml` | `iaac-risingwave-2:main` → values block in existing RW CR | Patch enabling native frontend TLS (Option A) |
| `ghostunnel-sidecar.yaml` | `iaac-risingwave-2:main` → `manifests/op-usxpress-dev/ghostunnel-frontend.yaml` | TLS-terminator sidecar in front of port 4567 (Option B fallback) |
| `phase2-wsl-runbook.md` | (runbook — not committed) | Step-by-step paste-able commands |

## Decision point — Option A vs B

WSL command on resume:

```bash
kubectl get risingwave -n risingwave-2 -o yaml | grep -A3 "image:\|version:"
# Find the operator version (e.g. v0.1.36)
```

Then `tls-options.md` table maps the version to A or B.

## Prerequisites that ARE in place

- Phase 0 (INFRA-1493): cert-manager + `letsencrypt-prod` ClusterIssuer + DNS01 IRSA chain
- Phase 1 (INFRA-1494): Gateway + VS in TLS-PASSTHROUGH mode wired (currently kubectl-applied; pending GitOps source PR in `flux-followup-cleanup/`)
- Wildcard cert exists for `*.op-dev.usxpress.io` (used by HTTPS plane); we want a NEW cert specifically for `rw2-sql.op-dev.usxpress.io` so the backend serves the right SAN that psql will validate

## What happens visibly

| Layer | Before Phase 2 | After Phase 2 |
|---|---|---|
| openssl s_client SNI smoke | CONNECTED + `errno=104` (gateway accepted, backend RST) | CONNECTED + full TLS handshake + ServerHello cert chain visible |
| psql `sslmode=require` | hangs / closes | connects and runs queries |
| RW-2 internal traffic | plain TCP within mesh | unchanged (TLS only on external edge) |

## What does NOT change

- Tim's `risingwave` ns — completely untouched. Track-separation rule.
- Phase 1 Gateway + VS — still SNI PASSTHROUGH; we just give the backend something real to terminate.
- existing port 4567 plaintext internal callers (RW internal components, mesh-internal psql clients) — backwards-compat requires us to keep plain port available OR change all internal callers to TLS. **Decision needed (see `tls-options.md`).**
