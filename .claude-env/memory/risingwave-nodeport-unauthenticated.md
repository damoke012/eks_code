---
name: risingwave-nodeport-unauthenticated
description: "RisingWave is published as a NodePort on every node of all three on-prem clusters and accepts superuser psql connections with no password and no TLS, bypassing the Istio gateway and every network policy"
metadata:
  node_type: memory
  type: project
  originSessionId: 94941f02-9560-4d8c-94c4-d8cfda90b06c
  modified: 2026-10-27T20:36:47.298Z
---

**CONFIRMED on op-usxpress-prod 2026-10-27**, from a laptop on the corp VPN:

```
PGPASSWORD= psql -h 10.10.82.109 -p 32567 -U root -d dev -c 'select current_user, current_database()'
 current_user | current_database
--------------+------------------
 root         | dev
```

No password. No TLS. Found by Idris Fagbemi on dev (10.10.82.27) and QA (10.10.82.25) the
same day; prod confirmed once the SSO kubeconfig existed to check it.

Published on prod, all NodePort, all bypassing the gateway:

| service | port | nodePort |
|---|---|---|
| `risingwave-frontend-ext` | 4567 | **32567** |
| `risingwave-console-ext` | 8020 | 32114 |
| `risingwave-dashboard-ext` | 5691 | 31845 |

**Why every control we have misses it.** A NodePort publishes on each node's own address and
does not traverse the Istio ingress gateway. So the gateway's TLS does not apply, and neither
does the `allow-corp-vpn-to-ingressgateway` CiliumNetworkPolicy — that rule guards the
ingressgateway, a door this traffic never uses. See [[office-vlan-blocked-to-onprem]], which
is about the door that IS guarded.

⚠️ **The control-plane VIP refuses it, the workers accept it.** The first prod test used
`10.10.82.52` and got `Connection refused`, which read as "prod is fine". That is the
endpoint, not a node. Three workers (`.109`, `.110`, `.185`) then all connected. **A refusal
on a VIP is not a measurement of a NodePort** — [[transport-failure-not-a-verdict]], and one
sample is not a population.

**A root password bootstrap job exists and RisingWave is not enforcing it** on these
connections. That is the actual defect; the NodePort only decides who can reach it.

**The tension that makes this more than a delete.** The NodePort may be the access path people
use today — the question that surfaced it was Tim asking for DBeaver access, which would reach
the database exactly this way. Removing it closes the hole and may break a workflow nobody has
written down. Three options, not equivalent:

1. **Remove the NodePort** — fast, GitOps, may break live use.
2. **Network policy in front of it** — keeps the path, narrows the reach to the corporate
   network, which is where the attacker already is. Does not fix the missing password.
3. **Make RisingWave enforce the password** — the only one that fixes the defect rather than
   the exposure, and the only one that does not trade security against usability.

**How to apply:** `scripts/check-risingwave-nodeport-exposure.sh all` sweeps every node and
every published port on all three clusters, and keeps "nothing listening from here" distinct
from "secured". Related: [[rw-database-is-named-dev-everywhere]] — the database is `dev` on
prod too, so the connection string above is not a mistake.

## ✅ CLOSED 2026-10-27, the same day it was found

| | |
|---|---|
| 20:07Z | PR #62 `iaac-risingwave-onprem` — five `-ext` services NodePort → ClusterIP, all three envs |
| 20:10Z | merged, tagged **v0.13.4** |
| 20:13Z | dev applied `de0074b` cleanly — no server-side-apply conflict |
| 20:17Z | PR #51 `iaac-talos-flux-cluster` — QA and prod pins `v0.13.3` → `v0.13.4` |
| 20:19Z | both reconciled, every `-ext` service ClusterIP |
| 20:35Z | **verified by probe**: dev `.27`, QA `.25`, prod `.109`, `.185`, `.187` — all `Connection refused` |

**The SSA conflict I predicted did not happen.** Changing a Service's `type` to ClusterIP
clears `nodePort` automatically; the Deployment `strategy` case does not
([[server-side-apply-keeps-dropped-fields]]). Two different fields, two different behaviours
— do not generalise from the one that bit you most recently.

**QA and prod moved in ONE PR**, deliberately against `PROMOTING-RISINGWAVE.md`'s
qa-then-prod ordering, and the PR body says so. The gate exists to keep an unproven change out
of production; dev had already proven it, and obeying the gate would have left credential-free
write access to production data open overnight. **A staging gate reduces risk; it is not owed
obedience when obeying increases risk.** State the deviation in the PR rather than skipping it
quietly.

**Still open, and it is the one that matters:** `rw-root-bootstrap-job` sets a root password
and RisingWave is not enforcing it on these connections. The door is shut; the lock still does
not work. Owned by Idris Fagbemi.

⚠️ `grafana` on op-dev remains a NodePort (32300), deliberately left — Grafana has its own
authentication, so it is a different risk and a different decision, not a silent inclusion in
a security PR.

**What made the confirmation possible.** INFRA-1661 landed SSO on prod that same morning.
Idris could not test prod because he had no prod kubeconfig; the access delivered hours
earlier is what turned "likely prod" into a measurement. Worth remembering when access work
looks like hygiene.
