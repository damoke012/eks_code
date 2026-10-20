---
name: envfrom-hides-the-inventory
description: "A DX-deployed app's variables are NOT in its Deployment spec — pricing-rfp-handler declares 1 env var and 8 envFrom objects, so the names are keys inside those ConfigMaps/Secrets. The `dx--` infix in an object name is DX's fingerprint"
metadata:
  type: project
---

**Measured 2026-10-20** on cloud EKS `usxpress-prod` (937464026810, k8s 1.35), namespace
`knx-synergy`:

| Workload | named `env` | `envFrom` objects |
|---|---|---|
| `pricing-rfp-handler` (0.1.39) | **1** (`API_BASE_PATH`) | **8** (one listed twice) |
| `pricing-rfp-api` (0.1.9) | 5, one duplicated | 4 |

So **enumerating `.env` finds almost nothing and reads like a clean answer.** The inventory is
the **keys inside each `envFrom` object**, and the only way to it is `get secret|cm <name>`
per reference. A variable count taken from the spec is wrong by an order of magnitude.

**Object names are the provenance**, and they are all we have here:
`managedFields` came back **0 entries on both** (counted, not assumed), so nothing in the
object says what last wrote it.

* **`<app>-dx--<thing>`** — the `dx--` infix is DX's naming. `pricing-rfp-api-dx--pricing-kafka-creds`
  and `pricing-rfp-api-dx--ccloud-schema-registry-master` are DX-created.
* **`<app>-chart`** — chart-generated, and it appeared **twice** in one container's `envFrom`.
* The handler's objects carry **no `dx--` infix** while the api's do: two naming generations in
  one namespace, so the fingerprint identifies *some* DX objects, never all of them.

⚠️ **What the names reveal about the workload matters more than the count.** The handler's
references are `-kafka-creds`, `-kafka-reg-creds`, `-kafka-t-bid-lane-request` (a topic) and
`-kafka-group` (a consumer group). **It is a Kafka consumer, not an HTTP API** — so on-prem it
needs topic *and* consumer-group ACLs, which are a separate deployment in
`ix-kafka-topics-users`, prefixed `dx__<env>_`, and often gated by someone else's approval.
That is the relay gate that produces a green deploy and an empty table
([[rw-kafka-sa-lacks-group-binding]], [[declared-grant-is-not-the-literal-acl]]).

**How to apply.** For a DX app, read `envFrom` first and the key names second; treat `.env`
as the exception list. And read the object names before their contents — they say who built
them when `managedFields` does not.

Related: [[app-config-source-is-octopus-not-compose]],
[[ccloud-registry-master-per-account]], [[secret-and-owner-are-two-axes]].
