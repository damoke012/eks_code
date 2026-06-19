# DNS zone feasibility — `.com` vs `.io` for Tim's RW

**Date:** 2026-06-03
**Question:** Tim asked "is there a reason we don't go with risingwave.usxpress.com?"
**Short answer:** Tim was directionally right (he wants a corporate platform domain, not the dev-cluster subdomain) — but `.com` is the wrong TLD. **`*.usxpress.io` is the corporate platform zone, and we ALREADY own the whole zone for our cluster's external-dns. No IT ticket needed.**

## What I checked + what I found

### 1. `usxpress.com` is the marketing site, not the platform zone

```bash
$ getent hosts usxpress.com
141.193.213.20  usxpress.com
141.193.213.21  usxpress.com
$ getent hosts www.usxpress.com
141.193.213.20  www.usxpress.com
141.193.213.21  www.usxpress.com
```

Those IPs are a corporate web-hosting CDN (looks like Acquia). Zero platform endpoints under `*.usxpress.com`:

```bash
$ getent hosts grafana.usxpress.com
# nothing
$ getent hosts api.usxpress.com
# nothing
```

**Conclusion:** `usxpress.com` is owned by Marketing/IT for the corporate website. Putting platform endpoints there is the wrong move regardless of access — it conflicts with the corporate-comms namespace.

### 2. `usxpress.io` IS the corporate platform zone — across cloud + on-prem

```bash
$ getent hosts grafana.usxpress.io
3.17.225.72     grafana.usxpress.io
3.149.222.0     grafana.usxpress.io
3.149.47.127    grafana.usxpress.io
$ getent hosts victoriametrics.usxpress.io
10.25.11.98     victoriametrics.usxpress.io   # internal AWS VPC
$ getent hosts grafana.dpl.usxpress.io
107.21.147.185  grafana.dpl.usxpress.io       # cloud
$ getent hosts rw2-sql.op-dev.usxpress.io
10.10.82.21     rw2-sql.op-dev.usxpress.io    # on-prem worker IPs
```

Pattern is clear:
- `*.usxpress.io` — platform endpoints (cloud Grafana, VictoriaMetrics, etc.)
- `*.dpl.usxpress.io` — cloud "dpl" env subdomain
- `*.op-dev.usxpress.io` — our on-prem dev cluster (what we manage today)

### 3. Our cluster's external-dns owns the WHOLE `usxpress.io` zone

From `iaac-drafts/onprem-external-dns/infrastructure/external-dns/release.yaml`:

```yaml
domainFilters:
  - usxpress.io       # ← THE WHOLE ZONE, not just op-dev.usxpress.io
extraArgs:
  - --aws-assume-role=arn:aws:iam::155768531003:role/iaac-route53-zone
registry: dynamodb
txtOwnerId: iaac-talos/us-east-2/op-usxpress-dev
```

The `iaac-route53-zone` role in account `155768531003` (Infrastructure-Networking) is where Route 53 lives. Our external-dns assumes that role and is authorized to write *anywhere* under `usxpress.io`. The `txtOwnerId` is what isolates our records from cloud's (cloud has a different `txtOwnerId`) — no collision.

### 4. Cert path — cert-manager can issue for any `*.usxpress.io` hostname

The `iaac-route53-zone` trust policy also accepts `cert-manager-*` roles. cert-manager already has its own role for the wildcard cert (`cert-manager-op-usxpress-dev`) and runs DNS-01 challenges via the same chain. Per-hostname certs (e.g. `risingwave.usxpress.io`) can be issued the same way — same Issuer, same DNS-01 mechanism.

## So can Tim get `risingwave.usxpress.io`?

**Yes, today, without an IT ticket.** Three pieces of work:

1. **cert-manager Certificate** for the exact hostname (`risingwave-dashboard.usxpress.io`, etc.) — DNS-01 challenge via the existing chain
2. **Gateway TLS server block** to bind the new cert (one PR on `iaac-talos-flux-platform`)
3. **VirtualService** + external-dns annotation (already what `platform-app-expose` chart does)

The chart already supports this — turn on `certificate.create: true` per HelmRelease.

## Two paths, both ticket-free

| Path | Hostname pattern | Extra work | Risk |
|---|---|---|---|
| **A. Subdomain `op-dev`** | `risingwave-dashboard.op-dev.usxpress.io` etc. | None — existing wildcard cert + Gateway server block cover it | None |
| **B. Root zone (Tim's instinct)** | `risingwave-dashboard.usxpress.io` etc. OR `dev.risingwave.usxpress.io` | New per-hostname certs + new Gateway TLS server blocks | Low — same zone as cloud Grafana, but `txtOwnerId` isolates us |

Either path Tim picks, I can land it today. Path B takes ~30 min more for the additional cert + Gateway PR.

## Important nuance for Path B

If we use root-zone names like `risingwave-dashboard.usxpress.io`, when prod RW comes up later, what will *its* name be? Tim hinted at `risingwave-prod.usxpress.io` or similar. So:

- Tim's dev RW: `risingwave-dashboard-dev.usxpress.io` (env-suffix)
- Tim's prod RW: `risingwave-dashboard.usxpress.io` (bare)

OR env-prefixed throughout:

- Dev: `dev.risingwave-dashboard.usxpress.io`
- Prod: `prod.risingwave-dashboard.usxpress.io` (or just bare for prod)

Either works. The env-marker prevents confusion when we have both clusters live.

## Recommendation for Tim

Go with **Path B with explicit env marker**:

- `risingwave-dev-dashboard.usxpress.io`
- `risingwave-dev-sql.usxpress.io`
- `risingwave-dev-meta.usxpress.io`

When prod RW lands later, it gets `risingwave-dashboard.usxpress.io` etc. (no env), or `risingwave-prod-*` if we want symmetry. Matches Tim's MSSQL-naming spirit (`usxsqlrisingwavedev` → `risingwave-dev-*`), uses the right TLD (`.io` not `.com`), and uses the corporate platform zone (matching cloud's `grafana.usxpress.io`).

## Verification commands (run on WSL2 if you want to confirm)

```bash
# Confirm external-dns domain filter
kubectl -n external-dns get helmrelease extd-usxpress-io -o yaml | yq '.spec.values.domainFilters'
# expected: [usxpress.io]

# Confirm cert-manager has the iaac-route53-zone chain
kubectl -n cert-manager get clusterissuer letsencrypt-prod -o yaml | yq '.spec.acme.solvers'
# look for dns01.route53.role: arn:aws:iam::155768531003:role/iaac-route53-zone

# Confirm DNS for an existing cloud root-zone hostname works
nslookup grafana.usxpress.io
# expected: AWS IPs (proves the parent zone is live)
```
