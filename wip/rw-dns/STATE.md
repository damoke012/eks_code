# RisingWave on-prem DNS — op-usxpress-dev

**Status 2026-10-06: there is no DNS defect. Both UIs are served and reachable.**
What exists is a naming defect, and it cost Tim weeks of port-forwarding.

## Measured on op-usxpress-dev (10.10.82.50), 2026-10-06

| Hostname | Routes to | Which UI | http | https |
|---|---|---|---|---|
| `risingwave-dashboard.op-dev.usxpress.io` | `risingwave-console:8020` | **console** | 200 | 200 |
| `risingwave-overview.op-dev.usxpress.io` | `risingwave-meta:5691` | **dashboard** | 200 | 200 |

Both resolve to all seven dev workers
(`.21 .22 .26 .27 .28 .178 .180`), both bind `istio-ingress/shared-http`.

`shared-http` servers: `*.op-dev.usxpress.io` on 80; `*.op-dev.usxpress.io` on 443
(`wildcard-op-dev-tls`); `*.brands…`; plus a **redundant** dedicated 443 block for each of
the two RisingWave hosts with its own cert secret. The wildcard already covers them, so a
new `*.op-dev.usxpress.io` hostname needs **no Gateway change and no Certificate** — a
VirtualService alone is enough.

## What was wrong, and whose claim it was

* The call concluded "the console has no DNS entry." **False** — it has had one since Phase 1,
  under the name `risingwave-dashboard`.
* I then repeated it and wrote it into INFRA-1703 as an acceptance criterion. Worse than
  repeating it: I turned a verbal muddle into a work item that would have had someone build a
  route that already exists.
* `risingwave-meta` being headless was raised as a possible blocker. **Not a blocker** — Istio
  routes to headless Services per-pod, and `risingwave-overview` has been doing exactly that.

Nobody checked the URL because the name said it was the other UI. That is the whole failure.

## Change: additive only

`wip/rw-dns/virtualservice-risingwave-console.yaml` adds
`risingwave-console.op-dev.usxpress.io` → `risingwave-console:8020`.

Both names then serve the console. Nothing is taken away, nothing Tim uses moves.

**Deferred, and only after Tim confirms he is off the old name:** repoint
`risingwave-dashboard` → `risingwave-meta:5691` and fold `risingwave-overview` into it.
That step removes a working URL from a user, so it waits for his word, not ours
([[promotion-order-qa2-dev-qa-prod]]).

## Gates

* `risingwave` on op-dev is **Tim's namespace** — his nod before merge, not after.
* `iaac-risingwave-onprem` tracks `branch: main` at 5m on every cluster, so **merging is
  deploying**. Living under `manifests/op-usxpress-dev/` is what keeps this off QA and prod.
* That directory **enumerates** its resources — the new filename must be added to
  `kustomization.yaml` or it applies to nothing, silently.

## Proven / killed / traps

**Proven.** Both RisingWave UIs are served over http and https on op-dev and resolve to all
seven workers. The wildcard 443 server covers any new `*.op-dev.usxpress.io` host.

**Killed.** "The console has no DNS entry." "The dashboard has no name." "A headless meta
Service blocks an Istio route." "This needs a new Certificate and a Gateway edit."

**Traps.**
1. A resolving record is not a served page, and an admitted route is not either. Only the
   `curl` settled it — and it is what turned a three-object change into a one-object change.
2. **A name is an assertion, and nobody re-checks an assertion that is written down.** The
   route was correct and documented; the label on it was wrong, so the correct thing was
   invisible for weeks. See [[proxy-is-not-the-property]].
3. A meeting that reaches the right conclusion by the wrong argument is indistinguishable
   from one that reached the wrong conclusion — until someone measures. I corrected the call
   towards the wrong answer, confidently, from the same unmeasured ground they were on.

---

## ✅ SHIPPED AND VERIFIED 2026-10-06

PR **#163** merged to `op-dev` of `variant-inc/iaac-talos-flux-platform` —
`infrastructure/risingwave-routes/virtualservice-risingwave-console.yaml` plus the
kustomization line. **Note the repo: the platform repo, NOT `iaac-risingwave-onprem`.** That
repo's `manifests/op-usxpress-dev/` holds only the `*-ext.yaml` NodePort Services; every
VirtualService lives in the platform repo's `risingwave-routes` directory. The first attempt
targeted the wrong repo and the file listing caught it.

Verified by **content**, not by name:

```
risingwave-console     http=200 verify=0 9980ad26c2748234
risingwave-dashboard   http=200 verify=0 9980ad26c2748234   <- identical: both the console
risingwave-overview    http=200 verify=0 cc738d9a03a28c9a   <- differs: the meta dashboard
```

Comparing response hashes proves the routing without parsing a single page. Two hostnames
that must serve the same thing, one that must not — three numbers settle it.

**`verify=0` on the new host confirms the untested assumption**: `shared-http`'s
`*.op-dev.usxpress.io` 443 server with `wildcard-op-dev-tls` covers a brand-new hostname, so
no Certificate and no Gateway edit were needed. The per-host certs for dashboard and overview
are redundant with it.

### Trap: the local resolver cached NXDOMAIN

external-dns created the record **seconds** after the Kustomization applied
(`CREATE risingwave-console.op-dev.usxpress.io A`, zone `Z0658284PVIFD4Q8I9PO`), and
`dig @8.8.8.8` returned all seven worker IPs immediately. But `getent hosts` kept saying no
for five minutes, because the name had been queried repeatedly earlier in the day while it
genuinely did not exist, and the negative answer was cached locally.

**A new DNS record looks identical to a broken one from a machine that asked too early.**
Query an authoritative or public resolver (`dig +short <name> @8.8.8.8`) before concluding
external-dns failed, and test the route itself with
`curl --resolve <host>:443:<node-ip>`, which bypasses DNS entirely. From WSL the flush is
`cmd.exe /c ipconfig /flushdns`.

### Still open

Repointing `risingwave-dashboard` at the meta dashboard and retiring `risingwave-overview`.
That removes a URL in use, so it waits until Tim has moved to `risingwave-console`.

### ⚠️ The usxpress.io zone caches NXDOMAIN for 24 HOURS

```
dig +short SOA usxpress.io
ns-1577.awsdns-05.co.uk. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400
                                                                          ^^^^^ negative TTL
```

Measured 2026-10-06, an hour after `risingwave-console.op-dev.usxpress.io` was created:

| Resolver | risingwave-console | risingwave-dashboard |
|---|---|---|
| corporate (default) | **empty** | 7 IPs |
| public (`@8.8.8.8`) | 7 IPs | 7 IPs |

external-dns created the record within **seconds** of the Kustomization applying. The name was
nevertheless unreachable from every corporate client, because it had been queried several
times earlier that day *while it did not yet exist*, and the SOA minimum pins that negative
answer for **86400 seconds**.

**Probing a hostname before you create it costs a day on this zone** — and probing first is
exactly what you do to check whether something already exists. Check with
`dig +short <name> @8.8.8.8` (public, uncached by corp) rather than the default resolver, and
prove the route with `curl --resolve <host>:443:<node-ip>`, which needs no DNS at all.

`cmd.exe /c ipconfig /flushdns` clears the Windows cache; it does **not** touch the corporate
resolver, which is the one that matters.

**Follow-up worth raising:** 86400 is very long for a negative TTL — 300–900 is typical. The
zone lives in network account 155768531003. One field, and it would have cost minutes instead
of a day.

### Consequence for step 2

Repointing `risingwave-dashboard` at `risingwave-meta:5691` **must wait** until
`risingwave-console` resolves corporately. Doing it sooner leaves every browser with no route
to the console at all for 24 hours.

---

## ✅ STEP 2 DONE 2026-10-06 — the names now tell the truth

PR **#166**: `virtualservice-dashboard.yaml` repointed from `risingwave-console:8020` to
`risingwave-meta:5691`. Verified by response hash immediately after reconcile:

```
risingwave-dashboard   http=200 cc738d9a03a28c9a   <- meta dashboard
risingwave-overview    http=200 cc738d9a03a28c9a   <- meta dashboard (same)
risingwave-web         http=200 9980ad26c2748234   <- console
```

### Final state on op-dev

| Hostname | Serves | Note |
|---|---|---|
| `risingwave-web.op-dev` | console | the one that resolves everywhere today |
| `risingwave-console.op-dev` | console | correct name; negative-cached on one laptop until 2026-10-07 |
| `risingwave.op-dev` | console | same |
| `risingwave-dashboard.op-dev` | meta dashboard | was the console since Phase 1 |
| `risingwave-overview.op-dev` | meta dashboard | |

**Five hostnames for two UIs.** Three console names exist only because each was queried a
second or two before Route53 had its record, and the zone's 86400s negative TTL then hid it
for a day — so we minted another, twice. **Consolidate to `risingwave-console` and
`risingwave-dashboard` once the caches expire (2026-10-07), and delete the rest.**

Also noted for the tidy-up: `virtualservice-dashboard.yaml` is `networking.istio.io/v1`
while `virtualservice-risingwave-console.yaml` is `v1beta1`.

### The rule that would have avoided all of it

**Never query a hostname before you create it.** Check with `dig +short <name> @8.8.8.8` —
a public resolver — and prove the route with `curl --resolve <host>:443:<node-ip>`, which
needs no DNS. One local query, after the record is confirmed live, and never before.

A polling loop is the trap: it queries the name repeatedly *while it does not exist*, so the
loop written to confirm the record is what makes it unreachable. Poll the public resolver,
then ask the local one exactly once.

---

## ⛔ STEP 2 WAS REVERTED, SAME DAY — Dex is mounted on the dashboard hostname

PR **#167** reverted #166. `virtualservice-dashboard.yaml` points at
`risingwave-console.risingwave.svc.cluster.local:8020` again.

**What #166 broke.** The console's SSO flow issues to

```
https://risingwave-dashboard.op-dev.usxpress.io/dex/auth?client_id=risingwave-console
   &redirect_uri=https%3A%2F%2Frisingwave-dashboard.op-dev.usxpress.io%2Fauth%2Fsso%2Fcallback
```

Both the **Dex issuer** and the **SSO callback** are pinned to
`risingwave-dashboard.op-dev.usxpress.io`. The VirtualService has a single catch-all route,
so repointing the host moved `/dex/*` and `/auth/*` to `risingwave-meta:5691` along with
`/`. The meta dashboard has no such paths: "Sign in with SSO" returned **Not Found**.

Verified after the revert: `/dex/auth` on `risingwave-dashboard.op-dev` → **200**.

### The trap

**A hostname is not one application.** I checked that `risingwave-dashboard.op-dev` served
the console UI, and it did. I did not check what *else* was mounted under it. A
single-route VirtualService carries every path, so repointing a host silently relocates
every API, callback and auth endpoint that any client has hardcoded — and the client that
breaks is an OIDC redirect chain, which no reconcile and no probe of `/` will show.

**Before repointing a hostname, enumerate its paths and its consumers.** Minimum:

```
kubectl -n <ns> get vs -o yaml | grep -A5 'match:\|uri:'      # declared paths (none here = all)
kubectl -n <ns> get deploy <app> -o yaml | grep -iE 'issuer|redirect|callback|_url'
```

An OIDC issuer URL is a consumer of the hostname and lives in the application's config,
not in the routing. Related: [[config-can-outrun-the-image]] — the config outlives the
assumption it was written under.

### What the rename actually requires (not a routing change)

Sequenced, because the identity provider has to agree:

1. Move the console's **Dex issuer** and **SSO callback** to `risingwave-console.op-dev`
   (`variant-inc/iaac-risingwave-onprem`, `manifests/op-usxpress-dev/`).
2. **Add** the new redirect URI to the shared Entra app registration (clientID `e112d6ce`).
   Add, do not replace — the same app reg serves QA and prod, see
   [[rw-dex-entra-shared-app-registration]].
3. Confirm login works on `risingwave-console.op-dev` end to end.
4. *Then* repoint `risingwave-dashboard.op-dev` at `risingwave-meta:5691`.
5. Remove the old redirect URI from Entra once no client uses it.

Step 2 is the long pole: it is an Entra change, so it is not self-service from this repo.

### Proven / killed / traps

- **Proven:** the revert restores SSO (`/dex/auth` → 200). Dex is served by
  `risingwave-console:8020`, under `/dex` on the dashboard hostname.
- **Killed:** repointing the hostname alone. Also killed as a shortcut — adding a `/dex`
  path-prefix match back to `risingwave-console:8020` while `/` goes to meta. It would
  restore the issuer, but the callback `/auth/sso/callback` and the session cookie are on
  the same host as the console UI, so the flow would land the user on the meta dashboard.
  Splitting one app's auth across two backends by path is a worse defect than the name.
- **Trap:** `risingwave-dashboard.op-dev` serving the console is *load-bearing* today. The
  name is wrong and fixing it is a four-step change ending at Entra, not a one-line diff.
