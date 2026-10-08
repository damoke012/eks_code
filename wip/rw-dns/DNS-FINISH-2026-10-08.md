# Finishing the on-prem DNS work — measured state, 2026-10-08

**Status: the DNS layer is healthier than our notes said. Two believed gaps are
already closed. What remains is one naming change gated on Entra, one tidy-up
gated on Tim, and one zone setting that is not ours to change alone.**

Measured from the codespace by resolving every on-prem hostname written anywhere in
this repo (37 names, de-duplicated). The codespace cannot reach a cluster or the
Route 53 API, so this is the **public-DNS half only** — the cluster half needs
`scripts/onprem-dns-finish.sh` on WSL.

## What resolves, and whether it points at the right cluster

Node sets used for the check: dev 7 (`.21 .22 .26 .27 .28 .178 .180`),
QA 3 (`.23 .106 .139`), prod 10 (`.108–.113 .185 .189 .190 .191`).

**25 of 25 live names point at their own cluster's full node set. Zero wrong-cluster
records. Zero non-node targets.**

| Cluster | Names resolving correctly |
|---|---|
| op-dev | `argocd` `grafana` `api.brands` `risingwave` `risingwave-web` `risingwave-console` `risingwave-dashboard` `risingwave-overview` `rw-sql` `rw-postgres` `rw2-sql` `rw2-dashboard` |
| op-qa | `argocd` `grafana` `risingwave-dashboard` `risingwave-overview` `rw-sql` `rw-postgres` |
| op-prod | `argocd` `grafana` `risingwave-dashboard` `risingwave-overview` `rw-sql` `rw-postgres` |

## ✅ Two gaps we were still carrying are closed

**1. `grafana.op-prod.usxpress.io` has a name.**
`.claude-env/memory/onprem-ingress-dns-convention.md` said prod carried
`grafana.op-dev.usxpress.io`, that dev owned the record, that prod silently skipped
it, and that **"prod's Grafana has no name"**. Measured today:
`grafana.op-prod.usxpress.io` → all **10** prod nodes. Corrected in the note.

**2. Prod's `tcp-passthrough` Gateway exists.**
Two notes still said prod had `shared-http` but not `tcp-passthrough`, so
`rw-sql.op-prod` and `rw-postgres.op-prod` would "resolve, reach a node and route
nowhere". `wip/rw-etl-promotion/STATE.md:16` records the fix:
`iaac-talos-flux-platform` **#143**, merged into `op-prod`, reconciled at `7f0d3b7`
— prod routes corrected (they were dev copies), `tcp-passthrough` added, Velero
metastore Schedule added. Both names now resolve to prod's own 10 nodes, which is
consistent with the corrected routes. Corrected in the note.

⚠️ The **port 4567/5432 listener** is the half DNS cannot see. A resolving name and a
bound Gateway are two different facts — confirm with the Gateway line in
`scripts/onprem-dns-finish.sh`, not with a successful lookup.

## What is actually left

### Gap A — op-dev serves two UIs under five hostnames

| Hostname | Serves |
|---|---|
| `risingwave-console.op-dev` | console ← **the correct name** |
| `risingwave-dashboard.op-dev` | console — **load-bearing: Dex is mounted here** |
| `risingwave-web.op-dev` | console |
| `risingwave.op-dev` | console |
| `risingwave-overview.op-dev` | meta dashboard |

Three of the four console names exist only because each was queried a second or two
before Route 53 had its record, and the zone's 86400s negative TTL then hid it for a
day — so we minted another, twice.

**Unblocked today:** `risingwave-console.op-dev` resolves from outside the cluster
(7/7 dev nodes), so the cache that forced the extra names has expired.

**Still gated on Tim:** deleting `risingwave-web` and `risingwave` removes URLs
someone may have bookmarked. `risingwave` on op-dev is Tim's namespace — his nod
before the merge, not after.

### Gap B — the rename ends at Entra, not at a VirtualService

`risingwave-dashboard.op-dev` must keep serving the console until the console's **Dex
issuer** and **SSO callback** move. PR #166 repointed the host and took `/dex/*` and
`/auth/*` with it; #167 reverted within the hour. A single-route VirtualService carries
every path.

The five-step sequence is in `STATE.md`. **Step 2 — add the new redirect URI to the
shared Entra app registration (clientID `e112d6ce`) — is the long pole, and it is
now known to be self-service:** `onprem-human-access-model.md` records that the
"no Azure access" belief was corrected on 2026-08-25 and an app-registration update
is proven. **Add, never replace** — the same app reg serves dev, QA and prod
([[rw-dex-entra-shared-app-registration]]).

### Gap C — the zone's negative TTL is 86400

```
dig +short SOA usxpress.io
ns-1577.awsdns-05.co.uk. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400
                                                                          ^^^^^
```

300–900 is typical. 86400 is what turned a seconds-long external-dns create into a
day-long outage, twice, and it is what produced three of the five hostnames above.

**This is not ours to change alone.** The zone lives in network account
`155768531003` and cloud shares it (`grafana.usxpress.io`, `victoriametrics.usxpress.io`,
`*.dpl.usxpress.io`). Lowering the SOA minimum raises negative-query volume for every
consumer of the zone. Drafted in `wip/rw-dns/route53-soa-negative-ttl.md`; **not run**
from this repo.

## Proven

* 25 on-prem hostnames resolve, and every one points at its own cluster's **full**
  node set. 2026-10-08, public resolver, from the codespace.
* `grafana.op-prod.usxpress.io` resolves to prod's 10 nodes — prod's Grafana has a name.
* `risingwave-console.op-dev.usxpress.io` resolves to dev's 7 nodes — the negative cache
  that forced the duplicate names has expired.
* Zero wrong-cluster records and zero non-node targets across all three clusters.

## Tested and killed

* **"Prod's Grafana has no name."** It has one.
* **"Prod has no `tcp-passthrough`."** #143 added it.
* **"There is a DNS defect on op-dev."** There never was. There is a naming defect and
  a cache defect, which is why nobody found it by looking at DNS.
* **Resolving a name to find out whether it exists.** That is the instrument that
  created this problem. Ask Route 53.

## Traps

1. **Asking DNS whether a record exists is how you make it not exist.** 86400s negative
   TTL. `scripts/onprem-dns-finish.sh` reads the Route 53 API for existence and resolves
   only confirmed names, on purpose.
2. **A resolving hostname proves a record, not a listener.** `rw-sql.op-prod` resolved
   for weeks with no Gateway bound to 4567. Check the Gateway separately.
3. **A hostname is not one application.** Dex lives under `/dex` on the dashboard host.
   Enumerate paths *and* consumers — an OIDC issuer URL lives in the app's config, not
   in the routing ([[hostname-is-not-one-application]]).
4. **I ran into trap 1 while writing this.** Measuring the 37-name list resolved 10 names
   that have no record (`alertmanager.op-dev`, `prometheus.op-dev`, `ceph.op-dev`,
   `brands.op-dev`, `orders.op-qa`, `rw-2`, `rw-console`, `rw-dashboard`, `rw-ingress`,
   `rw2-pg`). Those negatives are now cached until **2026-10-09** on the resolver this
   codespace uses — Azure's, not the corporate one Doke's laptop uses, so the blast
   radius is this session. It is still the documented trap, committed by the person who
   documented it, one file away from the warning. **The script is the fix: it cannot do
   this.**
