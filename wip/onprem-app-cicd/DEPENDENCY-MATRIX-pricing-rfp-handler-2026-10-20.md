# pricing-rfp-handler — dependency matrix

**For review by:** the application team (Matt, Andres, Shrikant) and Idris.
**Measured 2026-10-20**, read-only, from the running production deployment on cloud EKS
`usxpress-prod` (account 937464026810, Kubernetes 1.35), namespace `knx-synergy`. Nothing was
created, patched or executed. Every value below came out of the application's own ConfigMaps;
no secret value was read.

**Workload:** `deployment/pricing-rfp-handler`, 2 replicas,
image `064859874041.dkr.ecr.us-east-2.amazonaws.com/knxsynergy/pricing-rfp-handler:0.1.39`,
digest `sha256:6732ffb9830f2b0327ce5b37bf8e4365024914fc69503fc3d134ce25a2d1f985`,
pushed 2026-10-08.

⚠️ **There is a second workload.** `pricing-rfp-api` (0.1.9) sits in the same namespace and
consumes the same Confluent credentials under different object names. **Whether it moves too
is an open decision**, and it changes the Kafka scope.

## The dependencies

| # | What | Endpoint | Protocol | Auth | On-prem |
|---|---|---|---|---|---|
| 1 | **Knight-Swift pricing tools** | `pricing-tools.swifttrans.com/api/pricingtools` | HTTPS 443 | OAuth2 client credentials | **the reason for the move.** Never tested from on-prem |
| 2 | **Entra token endpoint** | `login.microsoftonline.com/0f298105-68e6-4cbe-844d-69ffc1806495` | HTTPS 443 | — | works anywhere; see the tenant question below |
| 3 | **MongoDB Atlas** | `mongodb-pl-0.1cr18.mongodb.net` | `mongodb+srv` **1024-1026** | **X.509 client certificate** | ⚠️ **one firewall rule away** — see below |
| 4 | **SQL Server (Bmd)** | `USXSQLA1DBP.usxpress.com` | TDS, port assumed 1433 | SQL login + password | corporate network: needs a route and a firewall rule |
| 5 | **SQL Server (Psa)** | `USXSQLPSAPRD.usxpress.com` | TDS, port assumed 1433 | SQL login + password | same |
| 6 | **Tariff API** | `legacyapps.usxpress.com:83` | HTTPS on **port 83** | ClientId | non-standard port; confirm egress policy allows it |
| 7 | **Confluent Cloud** | bootstrap server held in a Secret | SASL_SSL | API key + secret | needs topic **and consumer-group** ACLs |
| 8 | **Pyroscope** | `pyroscope.usxpress.io` | HTTPS 443 | unknown | **not deployed on-prem** |
| 9 | **OTEL collector** | `otel-collector-collector.otel:4317` | gRPC, **in-cluster** | none | an equivalent must exist in the on-prem cluster at a resolvable name |

Nine, against the seven Idris mapped. The two most likely to be the difference are #9, which
is in-cluster rather than egress, and #8, which nobody has mentioned.

## The blocker, in order of severity

### 1. MongoDB Atlas is reached over AWS PrivateLink — RESOLVED to one firewall rule

**Confirmed 2026-10-20**, by resolving the name through public DNS and then tracing the
network in AWS. The hostname points at an **AWS interface endpoint** — `vpce-06e6cad5b697c515a`
in us-east-2 — answering on **10.16.6.113 / 10.16.11.221 / 10.16.8.87**, ports **1024-1026**.
On-prem is 10.10.82.x, a different network.

**But the path already exists.** Traced end to end:

| Hop | Status |
|---|---|
| Mongo VPC (10.16.0.0/20) routes 10.0.0.0/8 to `tgw-09c7b37043d31e43a` | ✅ |
| That TGW's route table for this VPC carries 10.0.0.0/8 | ✅ all 8 tables do |
| The route is propagated from the **vpn** attachment `tgw-attach-02049e22560f04685` | ✅ |
| The VPN's own table (`tgw-rtb-056c87f242ae7a6bc`) carries 10.16.0.0/20 | ✅ |
| **The endpoint's security group `sg-0c8f8db29b16a1477` admits only 10.16.0.0/20** | ❌ |

**So the fix is one inbound rule: TCP 1024-1026 from the on-prem worker range.** Not a new
network, not a credential change, and not a reason to pause the rest of the onboarding.

⚠️ **A request naming port 27017 would be approved and would not work.** 1024-1026 is the
private-endpoint port range.

⚠️ **Still to confirm:** the datacenter must be *receiving* AWS's 10.16.0.0/20 route and
preferring it — it advertises 10.0.0.0/8, so it believes it owns that range itself. Not
readable from AWS; the connection test after the rule lands is what settles it.

Plain-language version for the app and network teams:
`EXPLAINER-mongo-onprem-blocker-2026-10-20.md`.

### 2. Two corporate SQL Servers

`USXSQLA1DBP` and `USXSQLPSAPRD`, both `usxpress.com`. These are internal names, so the test
is routing and firewall from the on-prem site, not credentials. `TrustServerCertificate` is
`false` on both, so the on-prem pods must also trust the issuing CA — that is what the
`custom-ca-bundle` volume does today, and it has to be reproduced.

### 3. Kafka needs a grant, not just a credential

```
client id        knx-synergy_pricing_rfp_handler
consumer group   dx__pricing_pricing_rfp_handler_knx_pricing
topic            pricing_knxs_bid_lane_request_json
```

The consumer group carries the **`dx__` prefix** that `ix-kafka-topics-users` adds, so the
literal strings above are what an on-prem ACL must name — do not re-derive them from a
`prefix:` field. **Reading a topic without a consumer-group grant produces a healthy pod, a
green sync and zero messages.** That is the failure that cost RisingWave weeks.

### 4. Pyroscope has no on-prem equivalent

Three variables, continuous profiling, pointing at `pyroscope.usxpress.io`. Either the app
reaches it from on-prem, or profiling is dropped for the on-prem instance and the app team
agrees to that in writing.

## Good news, measured

**The image can already be pulled.** The ECR repository policy on
`knxsynergy/pricing-rfp-handler` is:

```
Effect Allow, Principal "*", Condition aws:PrincipalOrgID = o-yza5l1xhrc
Actions: BatchGetImage, GetDownloadUrlForLayer, BatchCheckLayerAvailability,
         ListImages, PutImage, InitiateLayerUpload, UploadLayerPart, CompleteLayerUpload
```

Any principal in the AWS Organization may pull **and push**. So the usual first blocker — a
new repository with no policy, giving a 403 at the manifest HEAD — does not apply here, and no
pull grant has to be built. One work item removed.

⚠️ The same policy grants **push** org-wide. That is the standing registry posture issue
(515 of 517 repositories), not something this engagement introduced, and the on-prem defence
is digest pinning rather than trusting the tag.

**The pod needs no AWS identity.** The ServiceAccount `pricing-rfp-handler` carries only Helm
metadata — **no IRSA role annotation** — so there is no AWS permission set to reproduce
on-prem. Its volumes are `awssecrets-kafka-creds`, `awssecrets-kafka-reg-creds`,
`custom-ca-bundle` and `mongo-atlas-certs`, all materialised as Kubernetes objects before the
pod starts.

**Mongo carries no password.** The connection string is
`authSource=$external&authMechanism=MONGODB-X509` with no `user:pass@` segment — authentication
is entirely by client certificate. Checked without printing the credential.

## Still unknown

| # | Question | Who answers |
|---|---|---|
| 1 | **Whose Entra tenant is `0f298105-68e6-4cbe-844d-69ffc1806495`** — USX's or Knight-Swift's? | one command: `az account show --query tenantId`. If it is **not** ours, the client registration lives in a partner tenant and rotation is entirely theirs |
| 2 | Does `pricing-rfp-api` move with the handler? | the application team |
| 3 | The SQL ports — 1433 assumed, not read | the application team or a connection test |
| 4 | Whether Pyroscope is required or droppable on-prem | the application team |
| 5 | What `KAFKA__misc_rotation` is for (268 b64 characters, unexplained) | Confluent owner |
| 6 | The Octopus side: 58+ project variables and 10 library variable sets | **Idris already has this** |

## Proven

* Nine dependencies, six of them outside the cluster, measured from the application's own
  configuration rather than asked for.
* The ECR pull path is **already open** org-wide; no repository policy work is needed.
* The pod uses **no IRSA role**.
* Mongo authenticates by **X.509 client certificate**, not a password.
* The Kafka consumer group is `dx__pricing_pricing_rfp_handler_knx_pricing` — the literal an
  ACL must name.
* The deployed artefact is digest `sha256:6732ffb9…`, pushed 2026-10-08.

## Tested and killed

* **"A new ECR repository will 403 the on-prem pull."** Does not apply: this is an existing
  repository with an org-wide policy.
* **"The Mongo connection string may hide a password."** It does not; X.509 only.
* **"The pod may need an IRSA role on-prem."** No annotation on the ServiceAccount.

## Traps

* **`mongodb-pl-0` is PrivateLink by naming convention, which is an inference.** Treat it as
  the highest-priority thing to measure, not as a finding, until a pod has tried it.
* **`getent` returning nothing for an SRV-only name is expected** and is not evidence the host
  is unreachable.
* **The consumer group's literal value is what matters**, not the `prefix:` that generated it.
* **Port 83 for the Tariff API** is easy to drop when copying a hostname.
* **`TrustServerCertificate=false`** means the CA bundle is load-bearing; a pod without it
  fails at TLS and the error reads as a credential problem.
