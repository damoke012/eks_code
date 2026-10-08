# Change request — lower the `usxpress.io` negative TTL from 86400s

**Drafted 2026-10-08. NOT APPLIED. This is a shared zone in another account; it is not
ours to change alone.**

## The ask

One field, in one record, in one zone.

| | |
|---|---|
| Zone | `usxpress.io`, hosted zone `Z0658284PVIFD4Q8I9PO` |
| Account | `155768531003` (Infrastructure-Networking) |
| Record | `usxpress.io.` SOA |
| Field | the **last** value — SOA minimum, a.k.a. negative-cache TTL |
| Now | `86400` (24 hours) |
| Ask | `300` |

```
ns-1577.awsdns-05.co.uk. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400
                                                                          ^^^^^
```

## Why

`external-dns` creates a record within **seconds** of a Kustomization applying. But any
client that asked for the name *before* it existed holds NXDOMAIN for 24 hours, and
asking is exactly how you check whether it already exists.

Measured cost on this zone, twice in one day (2026-10-06):

* `risingwave-console.op-dev.usxpress.io` was created in seconds and resolved on
  `8.8.8.8` immediately, while the corporate resolver returned nothing for the rest of
  the day.
* Because the name looked broken, **two more hostnames were minted** to work around it.
  That is the direct cause of op-dev serving one console UI under four names today.

`ipconfig /flushdns` does not help — it clears the Windows stub cache, not the corporate
recursive resolver, which is the one that matters.

## Why this needs the networking owner, not just us

Our external-dns holds `--domain-filter=usxpress.io` for the **whole** zone, isolated
from cloud's records only by `--txt-owner-id`. We can write records. **The SOA is not a
record we own** — it is zone-level, and the zone has other consumers:

```
grafana.usxpress.io          3.17.225.72, 3.149.222.0, 3.149.47.127   (cloud)
victoriametrics.usxpress.io  10.25.11.98                              (cloud, internal)
grafana.dpl.usxpress.io      107.21.147.185                           (cloud dpl env)
```

Lowering the SOA minimum raises negative-query volume against the zone's four NS for
**every** consumer, not just us. 300s is standard and the volume increase is small, but
the decision is the zone owner's.

## The change, for whoever runs it

Account `155768531003`. **Do not run this from `eks_code`.**

```bash
# 1. Read the current SOA (dev-safe, read-only)
aws route53 list-resource-record-sets \
  --profile infra-networking \
  --hosted-zone-id Z0658284PVIFD4Q8I9PO \
  --query "ResourceRecordSets[?Type=='SOA']" --output json

# 2. Apply, substituting the four leading fields EXACTLY as step 1 printed them.
#    Only the final 86400 changes. Everything else must be copied, not retyped.
cat > /tmp/soa-negative-ttl.json <<'JSON'
{
  "Comment": "lower negative-cache TTL 86400 -> 300; a 24h NXDOMAIN cache cost us two outages and three duplicate hostnames",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "usxpress.io.",
      "Type": "SOA",
      "TTL": 900,
      "ResourceRecords": [{
        "Value": "ns-1577.awsdns-05.co.uk. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 300"
      }]
    }
  }]
}
JSON

aws route53 change-resource-record-sets \
  --profile infra-networking \
  --hosted-zone-id Z0658284PVIFD4Q8I9PO \
  --change-batch file:///tmp/soa-negative-ttl.json
```

## Verification

```bash
dig +short SOA usxpress.io @8.8.8.8     # last field should read 300
```

Then, and only then, is the "probe before you create" hazard reduced from a day to five
minutes. It is **not** removed — `scripts/onprem-dns-finish.sh` still reads Route 53 for
existence rather than resolving, because five minutes of a dead hostname during a release
is still five minutes nobody can explain.

## Blast radius if it goes wrong

| Failure | Cause | Effect | Recovery |
|---|---|---|---|
| Zone stops answering | a mistyped NS or email field in the copied SOA value | **every** `usxpress.io` name fails, cloud included | re-UPSERT the original value from step 1's output; keep it in the ticket |
| Negative queries rise | intended | more load on four AWS NS | none needed; raise toward 900 if observed |

The first row is why step 1 is mandatory and why the four leading fields are copied from
its output rather than from this document.
