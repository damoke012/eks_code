# Cross-check: Idris's Stage 1 plan against the production cluster

**For:** Idris, before the app team reviews INFRA-1715.
**2026-10-20.** His plan is built from **Octopus project variables** (the dev scope). This is
built from **the running production deployment**, read read-only from cloud EKS
`usxpress-prod`. Two views of the same application from opposite ends.

**Most differences below are legitimate dev-vs-prod differences and are marked as such.**
Three are not, and one of those would deploy the wrong thing.

The plan is good. It is more specific than ours on the pipeline, the Octopus identifiers and
the dev-scope values, and it found a dependency we could not see. What follows is the delta.

---

## 1. Three things to change before the app team reads it

### 1a. ⛔ The production version in §2 is wrong, and it drives Question 1

The plan's table says production runs **0.1.38, deployed Sep 29 2025**. The production
cluster is running:

```
064859874041.dkr.ecr.us-east-2.amazonaws.com/knxsynergy/pricing-rfp-handler:0.1.39
digest sha256:6732ffb9830f2b0327ce5b37bf8e4365024914fc69503fc3d134ce25a2d1f985
image pushed 2026-10-08, deployment 11 days old
```

Matt said the same thing on the onboarding call: *"our current version is 0.1.39, that was
recently deployed to production."* **Two sources agree against the table.**

This matters because Question 1's stated default is *"use 0.1.38 (stable)"* — which would
put a **year-old build** on-prem that production is not running. The default should be
0.1.39, and the question becomes much easier to answer.

### 1b. ⛔ MongoDB is not port 27017 and is not an external host

§5 line 9 asks for a firewall rule to "MongoDB Atlas endpoint, 27017, external". In
production the application reaches Atlas through an **AWS PrivateLink interface endpoint**:

```
mongodb-pl-0.1cr18.mongodb.net  ->  pl-0-us-east-2.1cr18.mongodb.net
                                ->  10.16.6.113 / 10.16.11.221 / 10.16.8.87
                                    ports 1024-1026
```

Three consequences:

* **A firewall request naming 27017 will be approved and will not work.**
* It is not an external host; it is a private address inside the AWS VPC.
* The actual blocker is a **security group**, `sg-0c8f8db29b16a1477`, which admits
  `10.16.0.0/20` only. The network between the datacenter and that VPC already exists and is
  routed — traced hop by hop. **The fix is one inbound rule: TCP 1024-1026 from
  10.10.82.0/24.**

The security group is owned by an Octopus project tagged `octopus/project = mongodb`, space
`USXpress`, group `enterprise`. Full write-up, with diagrams for the app and network teams:
`EXPLAINER-mongo-onprem-blocker-2026-10-20.md`.

⚠️ Dev may use a different Atlas endpoint, so check dev's own hostname — but the **shape**
will be the same, and so will the port range.

### 1c. ⛔ §4a lists Octopus variable names; the application reads different names

This is the one most likely to produce a pod that starts, reports healthy and behaves wrongly.

| §4a says | The container actually receives |
|---|---|
| `usx_db_bmd_server` | `UsXpressSqlConfiguration__Bmd__Server` |
| `usx_db_bmd_userid` | `UsXpressSqlConfiguration__Bmd__UserId` |
| `knxapi_baseaddress` | `KnightSwiftClientConfig__BaseAddress` |
| `knxapi_auth_clientid` | `KnightSwiftClientConfig__AuthClientId` |
| `tariffapi_baseaddress` | `TariffApiConfig__BaseAddress` |
| `feature_flag_is_response_capturing_enabled` | `FeatureFlags__IsResponseCapturingEnabled` |

The left column is what Octopus holds. The right column is what the DX Helm chart renders
into the ConfigMap, and it is what .NET configuration binds to. **A values file that emits
the left-hand names produces an application running entirely on its defaults**, with no error
anywhere.

The same applies to the SQL password keys: the chart renders them as
`UsXpressSqlConfiguration__Bmd__Password` and `...__Psa__Password`, so the ExternalSecret has
to produce those key names, not `bmd-db-password`.

---

## 2. Question 6 answered: yes, and there are about 25 of them

Question 6 asks *"Are there env vars injected by the DX Helm chart not in Octopus project
variables?"* **Yes.** These are present in the production ConfigMap and absent from §4a:

| Group | Keys |
|---|---|
| **Application identity** | `APPLICATION__ENVIRONMENT`, `APPLICATION__GROUP`, `APPLICATION__PROJECT`, `REVISION` |
| **Health checks** | `HealthChecks__Enabled`, `__Server__HostName` (`*`), `__Server__Path` (`/health`), `__Server__Port` (**13372**), `__Server__Protocol` (`http`) |
| **Prometheus** | `Prometheus__Server__Enabled` (`true`), `__HostName` (`*`), `__Port` (**12342**), `__Url` (`metrics/`), `__UseHttps` (`false`) |
| **Pyroscope** | `PYROSCOPE_SERVER_ADDRESS`, `PYROSCOPE_APPLICATION_NAME`, `PYROSCOPE_LABELS` |
| **OTEL** | `OTEL_SERVICE_NAME` (alongside the endpoint) |
| **Mongo** | `MONGODB__CLUSTER__CONNECTION_STRING`, `MONGODB__CLUSTER__SERVER`, `MONGODB__CLUSTER__TLS_CRT_KEY_FILE` |
| **Kafka** | `KAFKA__client_id`, `KAFKA__consumer_group`, `KAFKA__t_bid_lane_request` |
| **Other** | `API_BASE_PATH` |

Two of those close gaps in the plan directly:

* **The health check port and path** — §1 success criteria require passing readiness probes
  but no port is named. It is `http://*:13372/health`.
* **Pyroscope is missing from the plan entirely.** Three variables, continuous profiling,
  pointing at `https://pyroscope.usxpress.io` in production. On-prem it is neither deployed
  nor in the egress list.

There is also a **Prometheus scrape endpoint on 12342** that the plan does not mention. For a
background worker with no inbound Service, that is the only metrics surface it has.

---

## 3. OTEL: production uses an in-cluster collector, not a URL

§3h and §5 line 8 give `https://otel.usxpress.io` over gRPC, and list it as an egress host
that is "likely already open". In production the running pod has:

```
OTEL_EXPORTER_OTLP_ENDPOINT = http://otel-collector-collector.otel:4317
```

That is a **Kubernetes Service in the `otel` namespace** — plain HTTP, inside the cluster, no
egress at all.

If dev genuinely differs then both are right for their environment, and that is worth stating
in the plan. But it changes the on-prem work: **on-prem needs a collector running in the
cluster**, or the endpoint has to be re-pointed. A firewall rule to `otel.usxpress.io` does
not substitute for either, and if the variable is missing the application runs perfectly while
every log and trace goes nowhere.

---

## 4. Question 4 answered: where the Kafka credentials come from

They are **created by DX**, not held in Octopus. On the sibling workload they still carry
DX's own naming, which is the giveaway:

```
pricing-rfp-api-dx--pricing-kafka-creds           7 keys
pricing-rfp-api-dx--ccloud-schema-registry-master 3 keys
```

and on the handler the same keys arrive as `pricing-rfp-handler-kafka-creds` and
`pricing-rfp-handler-kafka-reg-creds`.

⚠️ **§4b plans to seed two Kafka keys. The application receives ten.**

| Secret | Keys |
|---|---|
| kafka creds | `KAFKA__api_key`, `KAFKA__api_secret`, `KAFKA__bootstrap_server`, `KAFKA__rest_endpoint`, `KAFKA__resource_id`, `KAFKA__service_account`, `KAFKA__misc_rotation` |
| schema registry | `KAFKA__schema_registry_api_key`, `KAFKA__schema_registry_api_secret`, `KAFKA__schema_registry_endpoint` |

**The schema-registry credentials are absent from the plan altogether.** Seeding a partial set
is the worst case: External Secrets writes the keys it can resolve, reports a green sync, and
the pod fails at container creation with **zero restarts** — invisible to restart alerts.

Note also that four of those are not secrets at all — `bootstrap_server`, `rest_endpoint`,
`resource_id`, `service_account` are addresses and identifiers. They are in a credential store
only because DX created them beside real credentials. On-prem they belong in the values file,
which means **the Confluent bundle is split, not copied**.

⚠️ The schema-registry credential is **one secret per AWS account that every consumer copies**.
Its blast radius is every consumer in the account, not this app.

---

## 5. Question 3 answered, and Questions 2, 5, 8 narrowed

| Q | Answer from production |
|---|---|
| **3** — EKS Secret holding the Mongo X.509 cert | **`pricing-rfp-handler-m-u`**. The guess in the plan is right. It holds `ca.crt`, `tls.crt`, `tls.key`, `tls-combined.pem`, and a ConfigMap of the same name holds `MONGODB__CLUSTER__CONNECTION_STRING` and `MONGODB__CLUSTER__SERVER`. `TLS_CRT_KEY_FILE` points at the combined PEM |
| **2** — full ECR image URI | For production: `064859874041.dkr.ecr.us-east-2.amazonaws.com/knxsynergy/pricing-rfp-handler:0.1.39`. **Note the account: 064859874041 (Infrastructure-Common), not 700736442855.** Check dev's own image before assuming a per-environment account |
| **5** — resource usage | The production **spec** is `requests cpu 100m / memory 384Mi`, `limits memory 768Mi`, **and no CPU limit at all**. The plan proposes a 1-CPU limit, which is a deliberate change rather than a copy — fine, but say so, because a throttled worker is hard to diagnose |
| **8** — is `knxapi_domain` needed separately? | **Production has no such key.** Only `KnightSwiftClientConfig__BaseAddress`. If dev has one, it is dev-only or unused |

**Also measured and worth adding:** the pod's ServiceAccount carries **no IRSA annotation** —
only Helm metadata. §7's "Image Pull: ECR via IRSA" is not what the workload does; the image
pull is the kubelet's, and on-prem it is handled by the `ecr-credentials-sync` component.
There is no AWS role for this application to reproduce, which is one less thing to build.

**And the ECR policy is already open:** the repository grants pull to any principal in the AWS
Organization, so **no pull grant has to be created** for on-prem. That removes a work item.

---

## 6. Question 10 is a functional decision, not a configuration preference

*"Is the consumer group shared with EKS, or should on-prem use a different group?"*

The two answers have opposite behaviour, and the app team should choose knowing which:

* **Same group** — Kafka splits the partitions between the EKS pods and the on-prem pods.
  Each message is processed **once, by one of the two clusters**. During parallel running,
  half the work silently moves on-prem.
* **New group** — the on-prem instance gets **its own copy of every message**, so both
  clusters process everything. Whether that is safe depends entirely on what the handler
  does; if it writes to Mongo or calls Knight-Swift, it would do so twice.

A new group also starts at whatever `auto.offset.reset` says — either the beginning of
retention or only new messages. Neither is obviously right.

⚠️ In production the consumer group's literal value is **`dx__pricing_pricing_rfp_handler_knx_pricing`**
and the topic is **`pricing_knxs_bid_lane_request_json`** — both carry prefixes that
`ix-kafka-topics-users` adds. The plan's dev values (`pricing-rfp-handler`,
`knxs_bid_lane_request`) look like the **Octopus variable** rather than the rendered value.
**Read the rendered ConfigMap in dev EKS before writing an ACL**: a grant written from the
un-prefixed name will not match the group the application actually joins, and the symptom is a
healthy pod that reads nothing.

---

## 7. What the plan has that we did not

Credit where it is due — these came from Idris and we could not have measured them:

* The **DX-Apply chain**: `spec.yaml` → mage-runner → Terraform → EKS, and the packages it
  pulls.
* **Octopus identifiers**: space `Spaces-245`, project `Projects-4881`.
* **Dev-scope values** throughout, which is the environment Stage 1 targets.
* **`geoservices.usxpress.com`** — read from `appsettings.json`, so it appears in no ConfigMap
  and no Octopus variable. It is exactly the category we flagged as unfindable from the
  cluster, and he found it. **Question 7 — "is it actually called, or dormant?" — is a good
  question and only the app team can answer it.**
* The **base image, non-root UID 1007 and entrypoint**, which matter for PodSecurity
  `restricted`.
* **Connectivity already tested** to both Knight-Swift hosts from a workstation, with latency.

## 8. Suggested additions

1. **An on-prem resolution check for every hostname**, not just reachability. Several of these
   are internal names and one is a PrivateLink address; a name that resolves in cloud can
   resolve to nothing, or to an unroutable address, from the datacenter.
2. **A row for the Prometheus and health-check ports** in the resource section, since nothing
   else records that the worker listens on 12342 and 13372.
3. **State the parallel-running posture.** While both the EKS and on-prem copies exist, which
   one is authoritative? Section 11 says decommissioning EKS is out of scope, so they coexist
   — and Question 10 is really a consequence of that.
4. **One line on config drift.** Settings will live in Octopus for the cloud copy and in a
   values file for the on-prem copy. A change made in one will not reach the other, and the
   symptom surfaces as an on-prem fault after a cloud fix.

## Proven

* Production runs **0.1.39**, pushed 2026-10-08 — not 0.1.38 from 2025.
* Mongo is reached over **PrivateLink on ports 1024-1026**, blocked only by a security group.
* The container receives **rendered** variable names (`UsXpressSqlConfiguration__Bmd__Server`),
  not Octopus names (`usx_db_bmd_server`).
* About **25 variables are injected by the DX chart** and appear in no Octopus project.
* The application receives **10 Kafka-related secret keys**, not 2.
* The Mongo cert Secret is **`pricing-rfp-handler-m-u`**.
* The ServiceAccount has **no IRSA annotation**; ECR already grants org-wide pull.
* In production, OTEL points at an **in-cluster collector**, not a public URL.

## Traps

* **A firewall request for 27017 will be approved and will not work.**
* **A values file using Octopus variable names produces an app running on defaults, silently.**
* **A partial secret syncs green and kills the pod at container creation with 0 restarts.**
* **An ACL written from an un-prefixed consumer group name will not match the group the app
  joins**, and the pod will look healthy while reading nothing.
* **Most of the above is measured in production; dev may legitimately differ.** Check dev's own
  rendered ConfigMap rather than assuming either document is right for it.
