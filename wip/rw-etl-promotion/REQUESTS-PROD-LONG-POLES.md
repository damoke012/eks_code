# INFRA-1674 — what actually needs someone else

Revised 2026-08-31 after the confirmation run. **Two of the original three poles were
not real.** Only DNS goes to another team; the licence gates the console alone.

| Was | Now |
|---|---|
| DNS — networking | still networking, but now with exact targets |
| Prod Entra app registration — identity, multi-day | **not needed.** dev and QA share registration `e112d6ce-cc60-4884-9898-8fcc5b78b0b1`; prod is a third redirect URI on it, and the client secret is the same value QA already holds |
| RisingWave licence — Steve → Zach | unchanged, but console-only — it does not gate the stack |

---

## DNS — ours, and automatic. NOT a request.

Corrected 2026-08-31: an earlier version of this file asked networking for three A records.
That was wrong. `external-dns` creates them from VirtualService annotations, using the
`usxpress.io` zone in the network account (155768531003) via
`arn:aws:iam::155768531003:role/iaac-route53-zone`. We ran it for dev and QA the same way.

Prod's records appear on their own once its VirtualServices carry:

    external-dns.alpha.kubernetes.io/target: 10.10.82.108,10.10.82.110,10.10.82.111

which are `talos-wk-op-prod-platform-3/-2/-1`. Prod's external-dns is already running with
the correct `--txt-owner-id=iaac-talos/us-east-2/op-usxpress-prod`, so there is no
ownership collision with dev or QA.

Verify with `bash scripts/onprem-dns-claims.sh dev qa prod`.

---

## The licence — Steve, for Zach

> The RisingWave console licence has lapsed and we need a valid key for the prod
> stand-up on op-usxpress-prod.
>
> Terraform creates the secret regardless — at
> `op-usxpress-prod/risingwave/console_license_key` — but it writes a literal
> placeholder (`PLACEHOLDER_INJECT_REAL_LICENSE`) and, because the resource carries
> `ignore_changes`, never touches it again. So the secret existing proves nothing; the
> real key goes in by hand afterwards.
>
> This does not block the platform stack, only the console. If it is going to be weeks,
> I will land the stack without the console and add it after. Ticket INFRA-1674.

---

## Entra — ours, not a request

Prod needs `https://risingwave-dashboard.op-prod.usxpress.io/dex/callback` added as a
redirect URI on the **existing** registration `e112d6ce-cc60-4884-9898-8fcc5b78b0b1`
(tenant `bbb5a66d-5c9f-482a-969a-a40304b6bc8d`). Dev and QA already share it; only the
redirect URI differs per cluster.

Prod's `dex_entra_client_secret` is then a **copy of QA's value**, since a client secret
belongs to the registration, not the environment.

Two things worth raising separately, neither blocking:
- one registration across all three environments means one compromised secret reaches prod
- if that registration is ever DX-managed, a DX deploy recreates it with a new client ID
  and breaks all three clusters at once. Not verified either way.

---

## Found while confirming — two prod defects that are ours

**1. Prod has no `tcp-passthrough` Gateway.**

    op-usxpress-qa    istio-ingress/shared-http       80,443
    op-usxpress-qa    istio-ingress/tcp-passthrough   4567,5432
    op-usxpress-prod  istio-ingress/shared-http       80,443
    op-usxpress-prod  (tcp-passthrough absent)

The prod `istio-ingressgateway` Service already exposes 4567 and 5432. Only the Gateway
resource is missing, so once DNS lands, `rw-sql` and `rw-postgres` would resolve, reach
the node, and find nothing routing them. Lives in `iaac-talos-flux-platform`, `op-prod`
branch, under `infrastructure/`.

**2. Prod's Grafana VirtualService carries a dev hostname.**

    grafana  virtualservice/grafana  ["istio-ingress/shared-http"]  ["grafana.op-dev.usxpress.io"]

Live on the prod cluster. Argo CD's is correct (`argocd.op-prod.usxpress.io`), so this is
one copied file rather than a systemic problem — but it is the dev-copy pattern showing up
on the cluster and not just in the repo. Unrelated to RisingWave; worth its own ticket.
