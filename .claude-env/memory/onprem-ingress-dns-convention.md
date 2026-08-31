---
name: onprem-ingress-dns-convention
description: How on-prem Talos clusters expose HTTP and TCP services — A records point at the three PLATFORM worker node IPs, and Istio uses two Gateways, shared-http and tcp-passthrough
metadata:
  type: reference
---

Verified across op-usxpress-qa and op-usxpress-prod, 2026-08-31.

**DNS**: a service hostname gets one A record per **platform worker node**, three in total.
QA's `risingwave-dashboard.op-qa.usxpress.io`, `rw-sql.op-qa…` and `rw-postgres.op-qa…` all
resolve to `10.10.82.23`, `10.10.82.139`, `10.10.82.106` — exactly
`talos-wk-op-qa-platform-3`, `-2`, `-1`. Prod's equivalents are `10.10.82.108`,
`10.10.82.110`, `10.10.82.111` (`talos-wk-op-prod-platform-3`, `-2`, `-1`).

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
nothing, visibly. op-usxpress-prod carries `grafana.op-dev.usxpress.io` today: dev owns that
record (it resolves to dev's nodes), prod silently skips it, and prod's Grafana has no name.

Check both failure modes with `scripts/onprem-dns-claims.sh dev qa prod` — it flags any
hostname belonging to another environment and any target IP that is not a node of the
cluster claiming it.

**How to apply:** a new hostname needs three things, and DNS is only one — the annotation
carrying this cluster's platform IPs, a VirtualService, and a Gateway that binds the port. op-usxpress-prod has `shared-http` but
**no `tcp-passthrough`** as of 2026-08-31, so 4567 and 5432 would resolve, reach a node and
route nowhere. Related: [[rw-prod-blocked-on-manifests-path]], [[onprem-networking-ingress]].
