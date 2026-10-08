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

---

# ✅ MEASURED ON THE CLUSTERS, 2026-10-08 (both halves)

Everything above was the public-DNS half from the codespace. This is the full measurement,
run on WSL: Route 53 zone `Z0658284PVIFD4Q8I9PO` (1145 record sets) cross-referenced against
every Istio VirtualService **and Gateway** on all three clusters.

## The `op-*` scheme reconciles exactly — zero orphans, zero missing records

| Cluster | Records | Declared hosts | Record with no route | Route with no record |
|---|---|---|---|---|
| op-dev | 12 | 12 | none | none |
| op-qa | 6 | 6 | none | none |
| op-prod | 6 | 6 | none | none |

## ✅ Node topology resolved — the earlier "7 workers" count was right

`kubectl get nodes` returns control planes too, which is what made the counts look wrong.

| Cluster | Control planes | Workers | Targeted |
|---|---|---|---|
| op-dev | 3 (`.29 .181 .179`) | 7, **no pool split** (`wk-1..7`) | all 7 |
| op-qa | 3 (`.25 .24 .177`) | 10 — app 5 / **platform 3** / sys 2 | **3, platform only** |
| op-prod | 3 (`.187 .186 .188`) | 10 — app 5 / platform 3 / sys 2 | **all 10** |

## ⚠️ NEW FINDING — prod routes ingress onto application and system nodes

QA and prod have identical worker topology and make opposite choices. QA targets only its
three `platform` nodes; prod targets all ten workers, including
`application-1..5` (`.109 .190 .191 .112 .189`) and `system-1..2` (`.113 .185`).

**It works today** — `istio-ingressgateway` is a DaemonSet on every worker, so all ten
answer. The risk is latent and would present as intermittent: if that DaemonSet is ever
restricted to `platform` nodes — which QA's targeting implies is the intent — **seven of
prod's ten A records become blackholes**, DNS round-robins, and you get a ~70% failure rate
on prod with no Alertmanager to report it.

QA is the Prod-standard mirror, so prod is the deviation. **Not a fix, a decision:**
narrowing prod to three platform nodes cuts its ingress capacity by 70%. Board item.

Our note had recorded this as benign per-cluster variance ("dev 7, QA 3, prod 10 — mirror the
cluster's own working route"). The counts were right; the framing hid that prod has a pool
split and ignores it, while QA has the same split and observes it.

## ✅ `--policy=sync` confirmed, so Change A's reap will happen

    --source=istio-gateway  --source=istio-virtualservice
    --policy=sync  --registry=dynamodb  --dynamodb-region=us-east-2
    --txt-owner-id=iaac-talos/us-east-2/op-usxpress-dev
    --domain-filter=usxpress.io
    --aws-assume-role=arn:aws:iam::155768531003:role/iaac-route53-zone

This mattered: if the policy had been `upsert-only`, removing the two hosts from Istio would
have left their A records alive pointing at workers with no route for them, and the names
would have started **404ing instead of disappearing** — worse than the sprawl.

## ⛔ The orphan I reported did not exist — the probe was incomplete

I reported `api.brands.op-dev.usxpress.io` as a record no routing declared, and reasoned from
it that `--policy=sync` might not be reaping. **It is declared — by a Gateway**,
`enterprise/brands-api-opdev`, carrying the seven dev worker IPs.

external-dns reads **both** `--source=istio-gateway` and `--source=istio-virtualservice`. My
hand-rolled cross-reference enumerated only VirtualServices for hosts and printed Gateways as
names and ports alone, so a Gateway-declared hostname read as unclaimed.

`scripts/lib/onprem-dns-classify.py` reads `spec.servers[].hosts` and does not have this
defect. **The probe that was tested was replaced, under time pressure, by one that was not**,
because the file transfer to WSL failed twice. The fallback carried no fixtures and no
self-test, and it produced a false finding within one step. See
[[proxy-is-not-the-property]] — this is the measurement being taken against one of two
sources and reported as a property of the system.

## Open: a second naming scheme, `*.dev.usxpress.io`

Surfaced only by enumerating Gateways. No `op-` segment, and **three of four carry no
external-dns target**, so they cannot be creating records:

| Gateway | Host | Target |
|---|---|---|
| `enterprise/brands-api` | `api.brands.dev.usxpress.io` | 7 dev workers |
| `attrition/attrition-api` | `api.driver.attrition.dev.usxpress.io` | none |
| `io-curt/io-notifications-handler` | `io-curt.io-notifications-handler.dev.usxpress.io` | none |
| `octopus/octopusworker` | `octopusworker-0.dev.usxpress.io` | none |

Also on `shared-http`: `brands.op-dev.usxpress.io` (bare) is a declared server host with no
record — consistent with the Gateway carrying no target, and with the bare name measuring
NXDOMAIN earlier. Likely there for TLS SNI completeness rather than as a reachable name,
but unconfirmed.

Every count above excluded this scheme, because the Route 53 filter was `.op-`. **The
`op-*` conclusion is sound and this is a separate, unmeasured population** — one sample is
not a population, and neither is one naming convention.

## Proven, 2026-10-08, both halves, all three clusters

* 24 `op-*` records, 24 declared hosts, **no orphans and no nameless routes**.
* Every record points only at its own cluster's workers. No wrong-cluster record exists.
* `tcp-passthrough` (4567, 5432) is bound on **all three** clusters, prod included.
* `--policy=sync` with the `dynamodb` registry on op-dev.
* Dev: 3 control planes + 7 workers, all 7 targeted.
* SOA negative TTL is **86400**, confirmed from the zone, not inferred from `dig`.

## Tested and killed

* **"`api.brands.op-dev` is an orphan record."** A Gateway declares it.
* **"`--policy=sync` may not be reaping."** It is `sync`; there was nothing to reap.
* **"Dev gained three untargeted nodes."** They are the three control planes.
* **"Prod's Grafana has no name."** / **"Prod has no `tcp-passthrough`."** Both closed.

## Traps added tonight

5. **A hostname can be declared by a Gateway, not only a VirtualService**, because
   external-dns reads both sources. Enumerate `spec.servers[].hosts` as well as `spec.hosts`,
   or a Gateway-declared name reads as an orphan.
6. **A tested probe replaced by an untested one is an untested probe.** The fallback was
   written because a file transfer failed twice, and it produced a false finding immediately.
   When the instrument cannot be delivered, that is a delivery problem — do not quietly
   downgrade the instrument to solve it.
7. **`exit 1` in a command pasted at an interactive prompt closes the shell.** It logged the
   operator out mid-measurement. Guards belong in an `if/else` **inside** a `( … )` subshell.
8. **A 1500-character line does not survive the paste path into WSL.** It truncated
   mid-quote and hung the shell on a continuation prompt. Short lines; many of them.

---

# QA and prod baseline, 2026-10-08 — the identical defect, measured

Taken after dev was fixed, via each cluster's own platform node
(`curl --resolve`, so DNS plays no part).

| Host | op-qa (`.23`) | op-prod (`.108`) | op-dev (fixed) |
|---|---|---|---|
| `risingwave-dashboard` | `9980ad26…` **Console** | `9980ad26…` **Console** | `cc738d9a…` Dashboard ✅ |
| `risingwave-overview` | `cc738d9a…` Dashboard | `cc738d9a…` Dashboard | `cc738d9a…` Dashboard |
| `risingwave-console` | **404** `e3b0c442…` | **404** `e3b0c442…` | `9980ad26…` Console ✅ |

The hashes are **byte-identical to dev's**, so this is one defect in three places, not three
variants. Same images, same wrong label.

## Two readings worth keeping

**`e3b0c44298fc1c14` is the sha256 of the empty string.** The 404 carries no body — Istio
rejecting an unmatched host, not an application error page. A hash tells you *which* 404 you
got.

**`verify=0` on a 404 is the useful signal.** TLS terminated and the chain validated for a
hostname with **no route at all**, which proves the `*.op-qa` / `*.op-prod` wildcard
certificate already covers a brand-new console hostname. **QA and prod need a VirtualService
only — no Certificate and no Gateway edit.** Dev demonstrated this on 2026-10-06 when
`risingwave-console.op-dev` came up `verify=0` on first contact; it is now confirmed on both
other clusters, before doing the work rather than after.

## What each of QA and prod needs, in order

Dev had a free ride on step 1 — its console VirtualService already declared three hosts, so
`/dex/*` was live on the new name before anything moved. **QA and prod do not**, so the
hostname must exist and serve `/dex` *before* the issuer moves, or there is a real window
with no working login.

1. `risingwave-console.op-<env>` VirtualService → `risingwave-console:8020`, with this
   cluster's own platform-node target IPs — `iaac-talos-flux-platform`, branch `op-<env>`.
   **Confirm it serves the console by hash (`9980ad26…`) before step 2.**
2. **Add** `https://risingwave-console.op-<env>.usxpress.io/dex/callback` to Entra app reg
   `e112d6ce`. Additive; the list reaches 6 before the old three come out.
3. The three config values in `manifests/op-usxpress-<env>/risingwave-console.yaml` —
   `issuer`, connector `redirectURI`, `RCONSOLE_SSO_DEX_ISSUERURL`. Scope the diff to that
   directory; a merge to `main` reaches every cluster.
4. Read the console's startup log for `SSO self-registered OIDC client … redirect_uri` —
   **before** a browser. Then a human signs in.
5. Repoint `virtualservice-dashboard.yaml` → `risingwave-meta.risingwave.svc.cluster.local:5691`.
6. Pass: dashboard hash flips to `cc738d9a…`, console stays `9980ad26…`, human signs in again.

**Promotion order: QA next, prod last** ([[promotion-order-qa2-dev-qa-prod]]). Prod has real
users on those URLs, and `iaac-risingwave-onprem` has no gate — merging is deploying.
