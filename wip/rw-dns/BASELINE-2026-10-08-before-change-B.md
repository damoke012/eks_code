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

---

# ✅ CHANGE B COMPLETE — 2026-10-08, the names now tell the truth

Verified by body hash against the baseline above, `curl --resolve` so DNS plays no part:

```
risingwave-console    200 verify=0  9980ad26c2748234                        console
risingwave-dashboard  200 verify=0  cc738d9a03a28c9a  RisingWave Dashboard  <- MOVED
risingwave-overview   200 verify=0  cc738d9a03a28c9a  RisingWave Dashboard  <- matches
console /dex/auth -> 200
```

Both Kustomizations carry the applied revision, not just a Ready condition:

```
risingwave-routes   True   op-dev@sha1:8abe1f40…   (platform #168)
risingwave-onprem   True   main@sha1:0bd5e9c2…     (onprem #40)
```

## What PR #166 got wrong, and what made this one work

#166 was a one-line routing change, reverted within the hour. The hostname was never pinned
in the routing — it was pinned in **three config values**, found only by reading the live
cluster:

| Where | Moved to |
|---|---|
| `cm/risingwave-console-dex` → `issuer` | `risingwave-console.op-dev.usxpress.io/dex` |
| same → connector `entra-dev` → `redirectURI` | `…/dex/callback` |
| `deploy/risingwave-console` env `RCONSOLE_SSO_DEX_ISSUERURL` | `…/dex` |

Plus a fourth that is not in any manifest: the **Entra app registration** `e112d6ce`, which
serves dev, QA and prod. One URI **added**, never replaced — 4 after, the three originals
intact.

## The ordering that made it safe

`/dex/*` was **already served** on `risingwave-console.op-dev`, because the
`risingwave/risingwave-console` VirtualService declares three hosts against one catch-all
route. So the config change landed first and the route change last, and in between a user
starting at the dashboard hostname was simply bounced to the console hostname. The migration
carried itself; there was never a window with no working login.

## The risk that did not materialise, and how we knew

Dex storage is sqlite3 on PVC `risingwave-console-data` (bound 129 days) and the console
self-registers its OAuth client, so the old callback was a **row in a database, not a
manifest**. If the console had treated it as already existing, login would have failed
`redirect_uri did not match` and no config change would have fixed it.

Settled by reading the console's startup log **before** anyone opened a browser:

```
16:30:59  config issuer  https://risingwave-console.op-dev.usxpress.io/dex
16:31:00  keys expired, rotating -> keys rotated
16:31:01  SSO self-registered OIDC client "risingwave-console" with Dex
          (redirect_uri https://risingwave-console.op-dev.usxpress.io/auth/sso/callback)
16:38:17  login successful  connector_id=entra-dev  doke@usxpress.com
```

It re-registers. The two `Unregistered redirect_uri` errors from 2026-10-06 22:31 were the
#166 window, not a standing break.

## Proven

* `risingwave-dashboard.op-dev` serves the meta dashboard; `risingwave-console.op-dev` serves
  the console; a human signed in on the console hostname at 16:38 UTC.
* The console **re-registers** its OIDC client on restart, with the issuer-derived callback.
  The PVC holds no blocking state.
* Both Kustomizations applied their merge commits — checked at `lastAppliedRevision`, not at
  `Ready`.

## Tested and killed

* **"Repointing the hostname is the change."** It is three config values and an Entra entry;
  the route is the last line, not the first.
* **"A stale client row in the PVC will block this."** It re-registers.
* **"`/dex/auth` returning 200 means SSO works."** It returned 200 before, during and after
  the broken window. Only `login successful` and a human in a browser settle it.

## Traps

9. **Two hostnames can serve byte-identical content and still be one bug.** Four names shared
   `9980ad26c2748234`; the hash is what made "has it moved" a yes/no instead of an opinion.
10. **A missing tool is not a failed build.** `kustomize build … || echo "ABORT - build
    broken"` printed ABORT because `kustomize` is not installed on WSL. The `||` branch could
    not tell "command not found" from "render failed" — a transport failure reported as a
    finding about the system under test, in a check written to prevent exactly that
    ([[transport-failure-not-a-verdict]]). Discriminate on exit code 127, or test for the
    binary first.
