---
name: onprem-ingress-dns-convention
description: How on-prem Talos clusters expose HTTP and TCP services — A records point at THIS cluster's own worker IPs (the count differs per cluster: dev 7, QA 3, prod 10), and Istio uses two Gateways, shared-http and tcp-passthrough
metadata:
  type: reference
---

Verified across op-usxpress-qa and op-usxpress-prod, 2026-08-31.

**DNS targets vary per cluster — there is no single convention.** Corrected 2026-08-31 after
generalising from QA alone:

| Cluster | Targets |
|---|---|
| op-dev | 7 IPs — every dev worker |
| op-qa | 3 IPs — platform nodes only (`.23`, `.139`, `.106`) |
| op-prod | 10 IPs — every prod worker, per its working `argocd.op-prod` route |

`istio-ingressgateway` runs as a DaemonSet on every worker on all three, so any worker is a
valid target; QA restricts to platform nodes, dev and prod do not. **Mirror the cluster's own
existing working route, not another cluster's.** For a new prod route, copy what
`argocd.op-prod.usxpress.io` targets.

Derive the targets from the node list, never from another cluster's records:

    kubectl --context admin@op-usxpress-prod get nodes \
      -o custom-columns='NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address' \
      | grep platform

**Istio**: `istio-ingressgateway` is a **ClusterIP** Service on every cluster — that is the
pattern, not a defect, and it is not `hostNetwork`. The gateway runs as a DaemonSet on every
worker. Two Gateway resources in `istio-ingress`:

| Gateway | Ports | For |
|---|---|---|
| `shared-http` | 80, 443 | dashboards, consoles, Argo, Grafana |
| `tcp-passthrough` | 4567, 5432 | RisingWave SQL and postgres |

**Why:** `kubectl get gateway` resolves to the **Gateway API** CRD and returns zero rows while
Istio Gateways exist. Always query `gateways.networking.istio.io`. An empty result from the
wrong kind is not absence — see [[proxy-is-not-the-property]].

## DNS is ours, and it is automatic — there is no networking request

`external-dns` (`extd-usxpress-io-external-dns`, namespace `external-dns`) creates every
record. Identical config on QA and prod except the owner ID:

    --source=istio-gateway --source=istio-virtualservice
    --policy=sync --registry=dynamodb --domain-filter=usxpress.io
    --provider=aws --aws-assume-role=arn:aws:iam::155768531003:role/iaac-route53-zone
    --txt-owner-id=iaac-talos/us-east-2/op-usxpress-<env>

The `usxpress.io` zone lives in the **network account 155768531003**, not in the cluster's
own account. The zones visible in the QA and prod accounts (`usxpress-qa.com`,
`usxpress-prod.com`) are different domains and are **not** where these records go.

Records come from annotations on the VirtualService (or Gateway):

    external-dns.alpha.kubernetes.io/target: 10.10.82.23,10.10.82.106,10.10.82.139
    external-dns.alpha.kubernetes.io/hostname: rw-postgres.op-qa.usxpress.io   # passthrough only

So a new environment's records appear **on their own** once its VirtualServices land with
its own platform node IPs. Nothing to request, nothing to create by hand.

**The failure mode is silent.** `--policy=sync` deletes records, but ownership is keyed on
`--txt-owner-id` in the DynamoDB registry, so a cluster skips records another cluster owns —
no error, no event, no working hostname. A copied VirtualService therefore produces exactly
nothing, visibly. ~~op-usxpress-prod carries `grafana.op-dev.usxpress.io` today: dev owns that
record, prod silently skips it, and prod's Grafana has no name.~~

✅ **CORRECTED 2026-10-08 — prod's Grafana has a name.** `grafana.op-prod.usxpress.io`
resolves to all **10** prod nodes; `grafana.op-qa` to QA's 3; `grafana.op-dev` to dev's 7.
A sweep of all 25 live on-prem hostnames found **zero** wrong-cluster records and zero
non-node targets. The silent-skip mechanism above is real and is still the thing to check —
the example of it is not. Measured in `wip/rw-dns/DNS-FINISH-2026-10-08.md`.

Check both failure modes with `scripts/onprem-dns-claims.sh dev qa prod` — it flags any
hostname belonging to another environment and any target IP that is not a node of the
cluster claiming it.

**How to apply:** a new hostname needs three things, and DNS is only one — the annotation
carrying this cluster's platform IPs, a VirtualService, and a Gateway that binds the port. op-usxpress-prod has `shared-http` but
**no `tcp-passthrough`** as of 2026-08-31, so 4567 and 5432 would resolve, reach a node and
route nowhere. Related: [[rw-prod-blocked-on-manifests-path]], [[onprem-networking-ingress]].

**Counts, confirmed 2026-09-03 by `scripts/onprem-dns-claims.sh prod`:** dev 7, QA 3,
**prod 10** (`10.10.82.108,.109,.110,.111,.112,.113,.185,.189,.190,.191`). All five of prod's
correct routes — argocd, both passthroughs, both RisingWave dashboards — carry that identical
list, and the checker confirmed every one is a node of op-prod.

⚠️ This file's own description and its MEMORY.md index line used to say "the three PLATFORM
node IPs". That was QA's count stated as a rule, and it contradicted line 19 of this note.
The index is what loads into context, so the wrong version is the one that got believed: on
2026-09-03 it produced a false alarm on a correct 10-target prod route. **When an index line
and a note body disagree, the body is the note — but fix the index, because the index is what
is read.** See [[proxy-is-not-the-property]].

## 2026-10-08 — the counts were right, the framing hid a prod deviation

Measured both halves on all three clusters (Route 53 zone read + every VirtualService **and
Gateway**). `kubectl get nodes` returns control planes too, which is what made the counts
look inconsistent:

| Cluster | Control planes | Workers | Targeted |
|---|---|---|---|
| op-dev | 3 (`.29 .181 .179`) | 7, **no pool split** | all 7 |
| op-qa | 3 (`.25 .24 .177`) | 10 — app 5 / **platform 3** / sys 2 | **3, platform only** |
| op-prod | 3 (`.187 .186 .188`) | 10 — app 5 / platform 3 / sys 2 | **all 10** |

⚠️ **QA and prod have identical worker topology and make opposite choices.** Prod targets
`application-1..5` and `system-1..2` as well as its platform nodes; QA targets platform only.
Dev has no pool split, so "all workers" is its only option.

It works today because `istio-ingressgateway` is a DaemonSet on every worker. The risk is
latent: restrict that DaemonSet to `platform` nodes — which QA's targeting implies is the
intent — and **7 of prod's 10 A records become blackholes**, round-robined, presenting as a
~70% intermittent failure on prod with no Alertmanager to say so.

"Mirror the cluster's own working route" (above) is still the right instruction, but it read
as benign variance. It is not: QA is the Prod-standard mirror, so prod is the deviation.
Narrowing prod costs 70% of its ingress capacity, so this is a decision, not a fix.

**Both sources count.** external-dns runs `--source=istio-gateway` *and*
`--source=istio-virtualservice`, so a hostname may be declared on a **Gateway's**
`spec.servers[].hosts` rather than a VirtualService's `spec.hosts`. On 2026-10-08 a
cross-reference that enumerated only VirtualServices reported `api.brands.op-dev.usxpress.io`
as an orphan record; it is declared by the Gateway `enterprise/brands-api-opdev`. Enumerate
both, which `scripts/onprem-dns-finish.sh` does.

**A second naming scheme exists and is NOT covered by the counts above:**
`*.dev.usxpress.io`, with no `op-` segment — `api.brands.dev`, `api.driver.attrition.dev`,
`io-curt.io-notifications-handler.dev`, `octopusworker-0.dev`. Three of those four Gateways
carry **no external-dns target**, so they create no record. Unmeasured as of 2026-10-08.
Full detail: `wip/rw-dns/DNS-FINISH-2026-10-08.md`.

## 2026-10-08 — the console-hostname rollout, and two measured rules

**Dev is DONE.** `risingwave-dashboard.op-dev` serves the meta dashboard,
`risingwave-console.op-dev` serves the console with SSO. **QA step 1 is done**
(`risingwave-console.op-qa` live, record at its three platform nodes). **Prod untouched.**

**A new hostname on these clusters needs ONE object.** Proven on all three: the
`*.op-<env>.usxpress.io` 443 server on `shared-http` covers any new host, so no Certificate
and no Gateway edit. The tell is cheap and can be taken *before* doing the work —
`curl --resolve <host>:443:<node-ip>` against a hostname with **no route** returns 404 with
`ssl_verify_result=0`. TLS terminated and the chain validated for a host Istio does not know,
which is the wildcard answering. The per-host Certificates on dev and QA
(`certificate-dashboard.yaml`, `certificate-overview.yaml`) are redundant with it.

**Branch names matter here.** `refs/heads/dev`, `qa` and `prod` exist as bare branches
alongside `op-dev`/`op-qa`/`op-prod`, so a branch called `qa/...` is rejected at push —
[[platform-repo-branch-refs-collide]].

⚠️ **op-qa's `risingwave-routes` Kustomization is `Ready=False`** with `lastAppliedRevision`
two commits stale, while the routes it owns serve correctly. Fix before changing anything
else in that directory — [[gitops-has-four-stale-layers]]. Live detail:
`wip/rw-dns/QA-PROD-ROLLOUT.md`.

