---
name: office-vlan-blocked-to-onprem
description: FIXED on op-dev (PR #178) and op-qa (PR #179) 2026-10-20, op-prod still open. ROOT-CAUSED 2026-10-20 — office Wi-Fi pings on-prem workers but TCP 443 fails because OUR OWN CiliumNetworkPolicy allow-corp-vpn-to-ingressgateway permits only the VPN pool 10.11.0.0/19; not a corporate firewall
metadata:
  type: project
---

Reported as "only VPN users can open the RisingWave console". Measured end to end on
2026-10-20:

| Hop | Result |
|---|---|
| DNS `risingwave-console.op-dev.usxpress.io` | ✅ all 7 op-dev worker IPs, 10.10.82.x |
| TLS + HTTP from VPN (`curl --resolve`, `.21` and `.180`) | ✅ exit 0 — Istio serving |
| ICMP from office Wi-Fi `10.10.72.227` → `10.10.82.21` | ✅ **PingSucceeded True, RTT 2 ms** |
| TCP 443 from that same office machine | ⛔ **TcpTestSucceeded False** |

**Ping passing at 2 ms kills the routing theory.** The packet reaches the server VLAN and
comes back. A stateful firewall between the office client VLAN and `10.10.82.0/24` permits
ICMP and drops TCP 443. Jeremy Kays' first read ("routing issue in AWS") is wrong twice —
there is no AWS in the data path at all, and it is not routing.

**Nothing in AWS routes these hostnames.** Route 53 (zone in network account 155768531003)
hands back the on-prem worker IPs and the traffic then goes office → on-prem directly.
See [[onprem-ingress-dns-convention]].

## ✅ FIXED ON op-dev — PR #178, confirmed by the reporter

18 AD-registered corporate subnets added; live object now 22 CIDRs. Jenni Ray's office
machine `10.10.72.227` went False → **True** on the same command. op-qa followed the same
evening (PR #179, `4005c6e`). **op-prod is the only cluster left.**

⚠️ **Verifying it nearly went wrong three times, all by reading the sync not the value:**
annotating the Kustomization re-applies the CACHED artifact and reports success (annotate the
GitRepository too); a read during a reconcile shows the previous revision; and on op-qa
`.status.lastAppliedRevision` **disagreed with the Ready condition** in the same object —
field said the old commit, condition said the new one with a 30-second-old timestamp. Trust
the condition, it has `lastTransitionTime`. End every gate on the live value.

## ROOT CAUSE — it is our own policy, not the network team's

`kubectl get cnp -A` on op-dev returns `istio-ingress/allow-corp-vpn-to-ingressgateway`,
**age 140d, VALID=True**. Its allow-list is the corp VPN pool `10.11.0.0/19`, the worker
subnet `10.10.82.0/24`, the pod CIDR and the service CIDR. **No corporate client subnet is
on it** — not the office Wi-Fi `10.10.72.0/24`, not `172.17.13.0/24`.

It fits the symptom exactly: the policy selects the **gateway pods**, so ICMP to the
**node** still answers while TCP 443 is dropped before Envoy. That is why ping passed and
the port did not.

✅ **This also CLOSES the INFRA-1496 open question "does Cilium enforce policy on hostPort
traffic at our version".** It does — the gateway runs hostPort on a DaemonSet and this policy
is dropping office traffic to it today. No throwaway-policy test is needed.

**It is not a defect — it is INFRA-1496 Phase 3 working as designed**, decided 2026-06-01,
source `iaac-talos-flux-platform` `infrastructure/istio-ingress/cnp-allow-corp-vpn.yaml`
on branch `op-<env>`. ⚠️ **Confirmed enforcing on ALL THREE clusters** — op-dev 140d (2026-06-02), op-qa 104d, op-prod 83d.
The design assumed every human reaches the clusters over the VPN; nobody tested from a desk.
It governs **80, 443, 4567 and 5432**, so office staff cannot reach the RisingWave SQL and
postgres passthrough ports either, not just the web UIs.

⚠️ **The answer was already in our own repo.** `wip/onprem-networking/CHANGELOG.md` records
this policy and its exact CIDR list, and `wip/onprem-qa-ingress/pr-1645-review-2026-08-20.md`
cleared a review question by quoting it. The 2026-09-08 "no policy exists" claim contradicted
two of our own documents and nobody noticed. **Search the notes before probing the cluster.**

⚠️ **A 2026-09-08 note stated "there is no CiliumNetworkPolicy in istio-ingress on any
cluster" and it was false** — the policy was 98 days old at the time. The check had been
run against a context that did not resolve and the error was read as absence. The on-prem
clusters are NOT in the default kubeconfig; op-dev is `~/.kube/op-usxpress-dev-fresh.yaml`
serving `https://10.10.82.50:6443`. See [[wsl-kubeconfig-churn]],
[[transport-failure-not-a-verdict]].

**Why:** this is one policy of ours standing between in-office staff and **every** on-prem
URL — Argo CD, Grafana, RisingWave console and dashboard on all three clusters all live on
`10.10.82.0/24`. It reads as "the platform is broken" and it is not ours to fix.

⚠️ **"Only VPN users can reach it" is the wrong generalisation.** It is only the AnyConnect
pool `10.11.0.0/19`. Tim works from home behind a hardware **ASA** teleworker tunnel that puts
him on `172.17.13.0/24` — corporate space, registered in AD as `172.17.0.0/16`, and not on the
allow-list. He has been blocked since 2026-06-02 and was told on 2026-09-08 that nothing was
rejecting him by address. An office desk, a home ASA and the DR site all fail the same way.

**How to apply:** the fix is a PR adding the corporate client subnets to that policy's
`fromCIDR` list, per cluster. **Ask Steve for the full list of office/user subnets** rather
than guessing from one laptop's lease — the ticket (INFRA-1496) says exactly that, and two
different client ranges are already known (`10.10.72.0/24`, `172.17.13.0/24`). All three clusters carry it, so the change is three PRs in dev → QA → prod order.
**Additive only** — a typo that drops `10.11.0.0/19` locks out every VPN user including you.

The discriminator to reuse: `Test-NetConnection <ip> -Port 443` reports Ping and TCP
separately, so one command separates "no route" from "port filtered" — and a pod-selecting
network policy produces exactly that split, because ICMP to the node is not governed by it.
Related: [[proxy-is-not-the-property]], [[transport-failure-not-a-verdict]].
