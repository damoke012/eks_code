# PROD — Orders ↔ MongoDB Atlas PrivateLink blackhole (2026-07-30)

**Cluster:** `usxpress-prod` (EKS, acct 937464026810, us-east-2)
**Symptom:** `orders` API — `MongoDB.Driver` throws
`The connection pool is in paused state for server pl-0-us-east-2.1cr18.mongodb.net:1025`
from `OrdersRepository.FindManyByOrderIdsAsync`.

**Conclusion: the Atlas PrivateLink path is dead. Every AWS-side component is healthy.**
Escalate to MongoDB Atlas — there is no cluster-side fix.

---

## Evidence chain (all verified, not inferred)

| Layer | Result |
|---|---|
| DNS | ✅ `pl-0-us-east-2.1cr18.mongodb.net` → `10.16.6.113`, `10.16.8.87`, `10.16.11.221` |
| VPC endpoint `vpce-06e6cad5b697c515a` | ✅ `State: available`, created 2024-07-16 (worked for a year) |
| Endpoint ENIs | ✅ all three `in-use`, one per subnet |
| Endpoint SG `sg-0c8f8db29b16a1477` | ✅ all TCP from `10.16.0.0/20` — covers every node |
| Subnet NACLs | ✅ allow all, both directions |
| Cilium network policy | ✅ none exist in the cluster |
| Istio | ✅ test ran as UID 1337 (excluded from redirection) — still fails |
| **TCP from pod netns** | ❌ timeout on all 3 ENIs, port 1025 |
| **TCP from node/host netns** | ❌ timeout — so not pod networking, policy, or masquerade |
| **TCP ports 1024 / 1025 / 1026 / 27017** | ❌ all timeout — endpoint blackholes entirely |

**Atlas itself is UP.** All 27 Kafka Connect Mongo connectors report `READY=True`, and there is only one
Atlas VPC endpoint in the account — so Connect reaches Atlas over the public path via NAT. Mongo is serving;
only the private path is broken.

`10.16.6.113` is in the same `/20` as the node that tested it (`10.16.6.218`), so this isn't even a routing
question — SG open, ENI present, nothing answering.

## The mechanism (why there is no client-side workaround)

Orders' connection string is the **standard SRV**, not a private-endpoint one:

```
mongodb+srv://***@mongodb.1cr18.mongodb.net/enterprise?maxPoolSize=300&readPreference=secondary&appName=orders-api-poc
```

DNS resolves correctly and publicly:

```
_mongodb._tcp.mongodb.1cr18.mongodb.net → mongodb-shard-00-0{0,1,2}.1cr18.mongodb.net:27017
TXT                                     → authSource=admin&replicaSet=atlas-qy8w3t-shard-0
mongodb-shard-00-00.1cr18.mongodb.net   → 89.194.134.107  (PUBLIC — same answer from inside the cluster)
pl-0-us-east-2.1cr18.mongodb.net        → 10.16.6.113 / 10.16.8.87 / 10.16.11.221  (the VPC endpoint)
```

So the driver reaches a **public** seed, runs `hello`, and the replica-set members **advertise themselves as
`pl-0-us-east-2.1cr18.mongodb.net:1024/1025/1026`**. The driver then abandons the public names for the
advertised private ones — which blackhole. The pool for `:1025` pauses, and no client configuration can
route around it, because the member list comes from Atlas, not from us.

`readPreference=secondary` makes it worse: reads only ever target secondaries, so losing those members
breaks reads outright.

Note `PrivateDnsEnabled: false` on the VPC endpoint — Atlas is advertising the private hostnames from the
replica-set config, not via a DNS override on our side.

## Blast radius — CONFIRMED narrow

Two separate Mongo estates:

- **Atlas** (`*.1cr18.mongodb.net`) — `orders/order-api`. **Affected.**
- **Self-hosted on-prem** (`USXMONGODB1/2/3.usxpress.com:27000`, `replicaSet=prod1`) —
  `enterprise/ingestor-chart`. **Not affected** — different estate entirely, reached over corporate DNS.

The Mongo connection strings come from the Helm chart secrets, **not** from ExternalSecrets (the only ESO
objects in `orders` are Kafka and Azure AD, all `SecretSynced`). So credential rotation is ruled out as a
cause.

## What to give MongoDB support

- VPC endpoint: `vpce-06e6cad5b697c515a`
- Endpoint service: `com.amazonaws.vpce.us-east-2.vpce-svc-07a355fc8047ca10d`
- Atlas project/cluster hash from the hostname: `1cr18`, region `us-east-2`
- AWS shows the endpoint `available`; AWS only reports its own half of the connection, so an endpoint dead on
  the provider side still shows healthy here.

Check first in the Atlas UI: **Network Access → Private Endpoint** status for that project, and the cluster's
own state (paused / resized / maintenance all produce this).

## Blast radius — confirm before declaring

Orders is confirmed affected. **Anything else connecting via a `pl-0-*` host is equally affected** and should
be enumerated rather than assumed. Apps reaching Atlas by the standard SRV hostname are unaffected.

## Workaround — do NOT apply unilaterally

Orders could be pointed at the standard Atlas SRV endpoint, which we know works (Kafka Connect uses it). That
moves the traffic out of the VPC and over NAT — a security-posture change that needs the owner of the Atlas
/ network design to agree. Raise as an option; don't ship it during triage.

## Separate issues found while triaging (not this incident)

- **`kafka/connect-connect-1`** — CrashLoop, 109 restarts / 10h, on `ip-10-16-10-66`. Exits code 2 after ~87s
  with `UnknownHostException` on Confluent brokers → `Failed to connect to and describe Kafka cluster`. Not
  OOM (limit 4Gi, `Reason: Error`). Workers 0 and 2 are healthy and the connectors are unaffected, so it is
  contained — but that node's kubelet also timed out serving logs (`10.16.10.66:10250`).
- **`geoservices/data-address-api`** — 70 restarts, and `mcleod-data-sync/mosh` 1–13 restarts, all on that
  same node. The node reports `Ready` with clean conditions, so this needs looking at on its own.
- **`rabbitmq-system`** — 4 pods in `ImagePullBackOff`.
- **`wiz/wiz-sensor`** — stuck `Terminating` 11h.

## Method note

Two dead ends were chased before the real error text arrived: CoreDNS `i/o timeout` lines to the corp
resolvers (**historical** — `--tail` surfaced old entries; zero in the last 30 min, and the forwarders answer
fine), and a Connect rebalance theory (**disproved** — worker-0 logged zero rebalances). Both cost time
because triage started from cluster symptoms rather than the reported error. **Get the exact error text
first.**
