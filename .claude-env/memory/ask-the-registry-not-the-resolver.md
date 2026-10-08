---
name: ask-the-registry-not-the-resolver
description: The usxpress.io zone caches NXDOMAIN for 86400s, so resolving a hostname to check whether its record exists is what makes it unreachable for 24 hours — read the Route 53 API for existence and resolve only confirmed names
metadata:
  type: feedback
---

**Measured on `usxpress.io` (hosted zone `Z0658284PVIFD4Q8I9PO`, network account
155768531003), 2026-10-06, confirmed still true 2026-10-08.**

    dig +short SOA usxpress.io
    ns-1577.awsdns-05.co.uk. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400
                                                                              ^^^^^
                                                              SOA minimum = negative TTL

`external-dns` creates a record within **seconds** of a Kustomization applying. But any
resolver that was asked for the name *before* it existed holds NXDOMAIN for **24 hours** —
and asking is exactly how you check whether it already exists.

**Why:** the check and the mutation are the same act. This is not a measurement that is
merely *adjacent* to the property ([[proxy-is-not-the-property]]) — it is a measurement
that **changes** the property. A polling loop is the worst form: a loop written to confirm
a record queries the name repeatedly while it does not exist, so the instrument built to
verify the fix is what breaks it.

**Measured cost.** On 2026-10-06 `risingwave-console.op-dev.usxpress.io` resolved on
`8.8.8.8` immediately and returned nothing from the corporate resolver for the rest of the
day. Because the name looked broken, **two more hostnames were minted** to work around it.
That is the direct cause of op-dev serving one console UI under four names
([[hostname-is-not-one-application]]). `ipconfig /flushdns` does not help — it clears the
Windows stub cache, never the corporate recursive, which is the one that matters.

**It fires on the careful person.** Checking before creating is the right instinct. On
2026-10-08 I committed it myself while sweeping 37 hostnames, one file away from having
written the warning — 10 absent names went negative-cached for a day.

## How to apply

**Ask the registry, not the resolver.** Route 53 `list-resource-record-sets` answers "does
this record exist" with an API call and no cache:

    bash scripts/onprem-dns-finish.sh dev qa prod

It reads the zone, prints `present` / `ABSENT` / `UNKNOWN` per host, and resolves **only**
the names Route 53 confirms. When the zone read fails it resolves nothing at all, by
design — `UNKNOWN` is reported as NOT MEASURED, never as absence
([[transport-failure-not-a-verdict]]).

For a single name by hand:

* existence → the Route 53 API, or `dig +short <name> @8.8.8.8` (public, not the corporate
  recursive, so a corp negative cache cannot mislead you)
* the route → `curl --resolve <host>:443:<node-ip>`, which needs no DNS at all and also
  returns `%{ssl_verify_result}`
* then ask the local resolver exactly **once**, after the record is confirmed live, and
  never before

**Generalise it.** Before building a loop to verify something, ask whether the query
itself has a side effect. Negative DNS caching, rate-limit counters, auth lockout
thresholds, `--policy=sync` registries and ACME order backoff all punish the probe.

**Open, and worth one field:** lowering the SOA minimum to 300. Drafted with its blast
radius in `wip/rw-dns/route53-soa-negative-ttl.md`. Cloud shares this zone
(`grafana.usxpress.io`, `victoriametrics.usxpress.io`, `*.dpl.usxpress.io`), so the SOA is
the zone owner's call, not a PR of ours. Related:
[[onprem-ingress-dns-convention]], [[adjacent-step-green-signals]].
