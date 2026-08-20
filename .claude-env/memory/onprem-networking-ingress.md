---
name: onprem-networking-ingress
description: On-prem ingress/cert plane on op-dev — Phase 1 (INFRA-1494 TCP/SNI) CLOSED 2026-06-01; May 29 networking/CySec call decisions
metadata: 
  node_type: memory
  type: project
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
  modified: 2026-08-20T19:45:00.000Z
---

On-prem ingress + cert plane on `op-usxpress-dev`. NOTE: supersedes the old "Steve message not yet sent" status — the May 13 draft was overtaken by an actual May 29 call, and networking Phase 1 has since closed.

**Status: Phase 1 (INFRA-1494 — TCP/SNI listeners) CLOSED 2026-06-01.** Phase 2 (INFRA-1495 — backend TLS on RW-2 frontend) is unblocked.
- Istio ingressgateway DaemonSet: HTTP live since 2026-05-19, HTTPS plane live, LE PROD wildcard cert `*.op-dev.usxpress.io`, per-team depth-N cert pattern proven (`*.brands.op-dev.usxpress.io`).
- TCP listeners 4567 (rwsql) + 5432 (postgres) via hostPort on all 7 workers. SNI passthrough: `rw2-sql.op-dev.usxpress.io` → `risingwave-frontend.risingwave-2.svc:4567`.
- Repo: `variant-inc/iaac-talos-flux-platform` (op-dev branch), PRs #13 + #14. Gateway `tcp-passthrough` + VS still kubectl-applied, NOT yet in GitOps (follow-up).
- external-dns needs `istio-virtualservice` source explicitly enabled; gateway Service is ClusterIP so VS needs explicit `external-dns.../target` = all 7 worker IPs.

**external-dns topology (verified live on op-qa 2026-08-13)** — deploy `extd-usxpress-io-external-dns`
in ns `external-dns` (NOT named `external-dns`; a bare-name lookup finds nothing). Key args:
`--policy=sync`, `--domain-filter=usxpress.io` (**zone-wide, not env-scoped**),
`--registry=dynamodb --dynamodb-region=us-east-2`,
`--txt-owner-id=iaac-talos/us-east-2/op-usxpress-qa`, `--provider=aws`,
`--aws-assume-role=arn:aws:iam::155768531003:role/iaac-route53-zone`.
⚠️ **Ownership lives in DynamoDB, NOT in TXT records** — `dig TXT <host>` returns empty by design
and proves nothing about who owns a record. Don't use it as the instrument ([[prod-incident-instrument-check]]).
Cross-env safety rests entirely on the per-cluster `txt-owner-id`: sync policy + zone-wide filter
means a duplicated owner ID would let one cluster silently DELETE another's records. Tighten
`--domain-filter` per env when prod's external-dns is built.

**Verifying a route (op-qa, 2026-08-20).** Use `scripts/check-onprem-route.sh <host> --context <ctx>`.
It checks each link separately: VirtualService + target annotation, backend Service + endpoints,
the **authoritative nameserver queried apart from the local resolver**, and HTTP by `--resolve`
against each target IP, plus a diff against a working route on the same gateway.
⚠️ The `external-dns.../target` requirement above was ALREADY written here before INFRA-1622,
and I still shipped a VirtualService without it — copied the `spec`, left the `metadata`. A note
did not prevent it; the script is the thing that goes red. Reach for it when writing the route,
not when debugging it.
⚠️ **A negative DNS answer outlives the defect.** After an hour of querying `argocd.op-qa` while
it did not exist, the WSL workstation returned NXDOMAIN for ~1h after the record was live and the
route served 200. WSL forwards to the **Windows** resolver — no Linux-side flush helps; `ipconfig
/flushdns` or wait. Never conclude "route broken" from workstation `dig`/`curl` alone.
⚠️ `curl` `000` conflates "did not resolve" with "resolved, did not connect". `--resolve
<host>:443:<ip>` separates them.
⚠️ external-dns `Desired change: CREATE` is logged **before** `ChangeResourceRecordSets` returns —
an intention, not a receipt. Confirm against the zone.

**May 29 networking + CySec call** (Steve Duck/Networking, Brendan Buschel/CySec, Steve Vives/Wiz+security, Doke) — decisions:
- Let's Encrypt stays the on-prem CA; rotation automated + Prometheus expiry alerting (manual rotation flagged as #1 ops risk).
- On-prem owns `op-dev.usxpress.io` + `on-prem-dev.usxpress.io` subzones. CAA record to be added at parent zone (pending John Quick Griffin / registrar).
- Wiz replaces Orca on-prem (eBPF sensor, needs egress to wiz.io); Steve Vives is build-out lead. **Dev setup starting week of 2026-07-13** (new-Mark + Steve). LIVE ticket on sprint board = **INFRA-1586** "Wiz sensor deploy to op-usxpress-dev (Steve Vives PR review + Flux wire-up)" (overdue Jul 10). My **INFRA-1590 is a DUPLICATE of INFRA-1586 → close it** (older INFRA-1505 also exists).
- AWS Secrets Manager stays source of truth (NOT Vault) — locked on portability/DR grounds.
- etcd encryption-at-rest = QA-promotion gate, not a dev gate.
- Hybrid AWS + on-prem vision → every on-prem design carries a portability constraint.

Docs (working tree on `main`): `wip/onprem-networking/` — `STATE.md`, `phase1-closure-jun01.md`, `networking-call-review-may29.md`, `steve-meeting-prep-may29.md`, `steve_duck_networking_message_draft_may13.md` (historical). Related: [[risingwave-onprem]].
