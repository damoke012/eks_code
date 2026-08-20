# PROD — Orders ↔ MongoDB Atlas: pool paused (2026-07-30)

**Cluster:** `usxpress-prod` (EKS, acct 937464026810, us-east-2)
**Symptom:** `orders/order-api` — `MongoDB.Driver`:
`The connection pool is in paused state for server pl-0-us-east-2.1cr18.mongodb.net:1025`
from `OrdersRepository.FindManyByOrderIdsAsync`.

> ## ⚠️ RETRACTION — the network diagnosis in the first version of this note was WRONG
>
> An earlier revision concluded the Atlas PrivateLink endpoint was blackholing and told the reader to
> escalate to MongoDB. **That was a measurement error, not a finding.** The probe used was
> `cat < /dev/tcp/HOST/PORT`, which opens the socket and then *blocks reading*. TLS/443 and MongoDB both wait
> for the client to speak first, so `cat` hangs on a perfectly healthy connection and `timeout` reports exit
> 124. Every "blackhole" reading came from that.
>
> The tell was ignored for too long: `connect-connect-0` "failed" to reach `1.1.1.1:443` while that same pod
> was demonstrably connected to Confluent Cloud over the internet. Two things that cannot both be true.
>
> Re-tested with `exec 3<>/dev/tcp/HOST/PORT`, which returns on TCP handshake and reads nothing:
>
> | from | `1.1.1.1:443` | `89.194.134.107:27017` (Atlas public) | `10.16.6.113:1025` (PrivateLink) |
> |---|---|---|---|
> | `kafka/connect-connect-0` | OPEN | OPEN | **OPEN** |
> | `orders/order-api` | OPEN | OPEN | **OPEN** |
>
> **The network is healthy end to end. Do not raise a MongoDB case on this basis.**

---

## Where the problem actually is

Network, DNS and AWS config are all verified good, so a paused pool must originate at the driver/server
layer. In the .NET driver a pool is *paused* when SDAM marks that server Unknown after a failure during
connection establishment or heartbeat — so the useful question is **what the original failure was**, which
appears in the logs *before* the "paused state" messages start repeating.

Candidates, in the order I would check them:

1. **Auth failure** on connection creation — pauses the pool exactly like a network fault. Would follow a
   credential rotation on the Atlas user.
2. **TLS handshake failure** — Atlas CA rotation, or the app's trust store.
3. **A genuinely unhealthy replica-set member.** The connection string sets `readPreference=secondary`, so
   reads only ever target secondaries. One sick secondary breaks reads while the cluster looks healthy.
4. **Pool saturation** — `maxPoolSize=300` per pod; under load, waits queue and time out.
5. Atlas-side cluster event (election, maintenance, resync).

## Verified facts (these stand)

- DNS: `_mongodb._tcp.mongodb.1cr18.mongodb.net` → `mongodb-shard-00-0{0,1,2}:27017`;
  TXT `authSource=admin&replicaSet=atlas-qy8w3t-shard-0`. Shard hosts resolve public
  (`89.194.134.107`); `pl-0-us-east-2` → the VPC endpoint. Same answers inside and outside the cluster.
- VPC endpoint `vpce-06e6cad5b697c515a` available, 3 ENIs in-use, SG allows all TCP from `10.16.0.0/20`,
  node SG egress `0.0.0.0/0`, no NACL denies. No Cilium network policies exist.
- **Members advertise `pl-0-…:1024/1025/1026`** — the driver connects to a public seed, runs `hello`, and is
  handed private-endpoint hostnames. That part is by design and works, since the endpoint is reachable.
- Connection strings live in **Helm chart secrets**, not ExternalSecrets → not an ESO sync problem.
- Atlas status page: no incidents affecting us-east-2, PrivateLink, or private endpoints.

## Estates

- **Atlas `mongodb.1cr18.mongodb.net`** — `orders/order-api` *and* the 27 `kafka` Mongo connectors
  (`connect-secrets:Mongo_Enterprise_Connection_Uri`). Note "Enterprise" in that key name refers to the
  database, not the self-hosted estate.
- **Self-hosted on-prem** `USXMONGODB1/2/3.usxpress.com:27000` (`replicaSet=prod1`) —
  `enterprise/ingestor-chart` only.

## Next steps

1. Find the **original** exception in the Orders app log, before the repeating "paused state" lines — it
   names the real cause (auth / TLS / timeout).
2. Establish whether it is constant or intermittent, and when it started.
3. Only then decide whether this is an app-side fix (pool sizing, read preference, retry policy) or an Atlas
   cluster-health question.

## Unrelated issues found while triaging

- `kafka/connect-connect-1` — CrashLoop, 109 restarts / 10h on `ip-10-16-10-66`; exits code 2 after ~87s with
  `UnknownHostException` on Confluent brokers. Workers 0 and 2 healthy. Its node also timed out serving
  kubelet logs.
- `geoservices/data-address-api` — 70 restarts, and `mcleod-data-sync/mosh` 1–13, all on that same node,
  which reports `Ready` with clean conditions.
- `rabbitmq-system` — 4 pods `ImagePullBackOff`. `wiz/wiz-sensor` — stuck `Terminating` 11h.
- **No VPC flow logs on `vpc-089f99053feed0cad`** — packet-level evidence was unavailable. Worth enabling.

## Method notes — five wrong turns, and the fix for each

1. **CoreDNS `i/o timeout` to corp forwarders** — historical lines surfaced by `--tail`, read as current.
   Zero in the last 30 min. *Check timestamps before treating a log line as live.*
2. **Connect rebalance churn** — disproved; `connect-connect-0` logged zero rebalances.
3. **Pod CIDR vs endpoint SG** — wrong; `172.24.0.0/16` is a Cilium overlay, not a VPC CIDR.
4. **"Connect proves Atlas is up"** — wrong; Connect uses the same cluster, and `RUNNING` connectors prove
   nothing about live connectivity.
5. **The `cat < /dev/tcp` probe** — the big one. *Validate an instrument against a known-good AND a
   known-bad target before trusting it. A result that contradicts a known fact means the instrument is
   wrong, not the fact.*

Triage started from cluster symptoms rather than the reported error. The app stack trace, once supplied, was
worth more than everything before it.
