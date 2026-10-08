# Baseline before Change B — op-usxpress-dev, 2026-10-08

Captured with `curl --resolve <host>:443:10.10.82.21`, which bypasses DNS entirely, so this
measures the **route**, not the resolver. `verify=0` is a validated TLS chain, not `curl -k`.

| host | http | verify | body sha256 (16) | title | serves |
|---|---|---|---|---|---|
| `risingwave-console.op-dev` | 200 | 0 | `9980ad26c2748234` | | console |
| `risingwave-dashboard.op-dev` | 200 | 0 | `9980ad26c2748234` | | **console — the defect** |
| `risingwave-overview.op-dev` | 200 | 0 | `cc738d9a03a28c9a` | RisingWave Dashboard | meta dashboard |
| `risingwave-web.op-dev` | 200 | 0 | `9980ad26c2748234` | | console |
| `risingwave.op-dev` | 200 | 0 | `9980ad26c2748234` | | console |

    dashboard /dex/auth -> 200
    console   /dex/auth -> 200

**Four hostnames serve byte-identical content. One differs.** Two hashes settle the routing
without parsing a page.

## These hashes are stable across two days

`9980ad26c2748234` and `cc738d9a03a28c9a` are the **same values measured on 2026-10-06**
(`wip/rw-dns/STATE.md`). The page bodies are deterministic — no CSRF token or timestamp
perturbs them — so a hash comparison is a valid pass/fail gate for Change B, not a
coin-flip.

## 🔑 New fact: `/dex/auth` already returns 200 on `risingwave-console.op-dev`

This was not known before. It follows from the routing measured earlier the same day: the
VirtualService `risingwave/risingwave-console` declares **three** hosts
(`risingwave-console`, `risingwave`, `risingwave-web`) against a single catch-all route, so
`/dex/*` and `/auth/*` are served on **all four** console hostnames already.

**What it proves:** the *path* is mounted on the console hostname. No routing change is
needed to put Dex there.

**What it does NOT prove — and this is the whole of PR #166's lesson:** that Dex's
configured `issuer` and the OAuth `redirect_uri` use the console hostname. Those are
**config values**, validated by Dex and by Entra against a registered list. A 200 on
`/dex/auth` means the handler answered, not that an authorization round trip would be
accepted. See [[hostname-is-not-one-application]] and [[config-can-outrun-the-image]] — the
config outlives the assumption it was written under, and a reachable endpoint is not a
working flow.

So Change B step 1 is still required, but it is a **config** edit with the routing already
in place, which is smaller than the five-step sequence assumed.

## Pass criteria for Change B step 5

Re-run the identical command. Pass is **all four**:

1. `risingwave-dashboard` hash == `cc738d9a03a28c9a` (the meta dashboard) — it **moved**
2. `risingwave-dashboard` hash != `9980ad26c2748234` — it is no longer the console
3. `risingwave-console` hash == `9980ad26c2748234` — unchanged
4. `/dex/auth` on **`risingwave-console.op-dev`** → 200, **and a human has signed in there**

Criterion 4 is the one `curl` cannot close. `/dex/auth` returned 200 before any change, so
on its own it would pass while the flow is broken — exactly the adjacent-green-signal family
([[adjacent-step-green-signals]]). A human completing the login is the only valid value.

## Rollback

Revert the one file, as PR #167 did. Do not debug forward on a hostname that carries
someone's login.
