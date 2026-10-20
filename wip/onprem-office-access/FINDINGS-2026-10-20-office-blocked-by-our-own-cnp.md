# Office staff cannot reach any on-prem URL — it is our own CiliumNetworkPolicy

## ✅ FIXED ON op-dev 2026-10-20 — confirmed by the original reporter

PR #178 (`1f70fda`) added the 18 AD-registered corporate subnets to
`allow-corp-vpn-to-ingressgateway`. The live object now carries **22 CIDRs** with all four
originals intact. Jenni Ray, same office Wi-Fi machine, same source `10.10.72.227`, same
command:

| | Before | After |
|---|---|---|
| `Test-NetConnection 10.10.82.21 -Port 443` | TcpTestSucceeded **False** | TcpTestSucceeded **True** |

✅ **op-qa done the same evening** — PR #179 (`4005c6e`), 22 CIDRs live, all Kustomizations
Ready. **op-prod is the only one left.**

⚠️ **The verification nearly produced a false negative.** The first two reads of the live
object after the merge returned the OLD four CIDRs: annotating the Kustomization re-applies
the cached artifact and reports success without refetching Git. A third read, after
annotating the **GitRepository** too, showed `lastAppliedRevision` had advanced and the
value had changed. Read the value, not the sync — [[gitops-has-four-stale-layers]].

**Reported:** 2026-10-20, Steve Duck relaying Jeremy Kays. "Folks in the office and Tim on
his ASA can't access this link" (`risingwave-console.op-dev.usxpress.io`). VPN users fine.

**Root cause:** `CiliumNetworkPolicy istio-ingress/allow-corp-vpn-to-ingressgateway`
permits only the corp VPN pool and the cluster's own ranges. No corporate client subnet is
on the list. **Present and enforcing on all three clusters.**

| Cluster | Endpoint | Age | Applied |
|---|---|---|---|
| op-dev | `10.10.82.50:6443` | 140d | 2026-06-02 |
| op-qa | `10.10.82.51:6443` | 104d | ~2026-07-08 |
| op-prod | `10.10.82.52:6443` | 83d | ~2026-07-29 |

Allow-list, read live from op-dev:

| CIDR | What |
|---|---|
| `10.11.0.0/19` | corp VPN (Cisco AnyConnect) |
| `10.10.82.0/24` | worker nodes |
| `10.244.0.0/16` | pod CIDR |
| `10.96.0.0/12` | service CIDR |

Ports governed: **80, 443, 4567, 5432**. So the office is also cut off from the RisingWave
SQL and postgres passthrough ports, not only the web UIs.

Source: `iaac-talos-flux-platform`, `infrastructure/istio-ingress/cnp-allow-corp-vpn.yaml`,
branch `op-<env>`. INFRA-1496 Phase 3, CIDR list decided 2026-06-01.

## Proven

* DNS is correct — `risingwave-console.op-dev` returns all 7 op-dev worker IPs.
* The service is healthy — TLS + HTTP from the VPN to `.21` and `.180`, curl exit 0.
* From the office (`10.10.72.227`, Wi-Fi): **ping to `10.10.82.21` succeeds at 2 ms**,
  TCP 443 to the same address fails.
* **Confirmed from a SECOND excluded subnet, 2026-10-20.** Tim Preble, from home behind his
  ASA teleworker tunnel, source `172.17.13.101`:

  | Test | Result |
  |---|---|
  | Windows `Test-NetConnection 10.10.82.21 -Port 443` | PingSucceeded **True, 26 ms**, TcpTestSucceeded **False** |
  | macOS `Test-Connection 10.10.82.21` | 4/4 success, 39-44 ms |
  | macOS `Test-Connection -TcpPort 443` and `-TcpPort 80` | **False** on both |
  | Firefox / Chrome on `risingwave-console.op-dev` | connection timed out / site can't be reached |

  Same signature as the office desk, from a different site, a different subnet and two
  operating systems. Ping passes, TCP dies, on both 80 and 443 — exactly the ports the policy
  governs. Two independent locations now, both in AD-registered corporate space, both absent
  from the allow-list.

  **The Cilium drop capture was planned to rule out ASA NAT and is no longer needed:** the
  proposed change admits every AD-registered corporate subnet, so any address the tunnel
  could present and still route back is covered.

* **The policy IS enforced on hostPort traffic.** INFRA-1496 flagged this as unverified and
  told us to stage a throwaway policy to find out. The office outage is the proof: the
  gateway runs hostPort on a DaemonSet and the policy is dropping that traffic today.

## Tested and killed

* **"Routing issue in AWS."** No AWS routing exists in this path. Route 53 returns the
  on-prem worker IPs and the traffic goes office to on-prem directly.
* **"The hosts need a default gateway of 10.10.82.254."** A ping round trip from a client
  in a different subnet is only possible through a working default gateway. The reply came
  back in 2 ms.
* **"The load balancer pointing at those hosts."** There is no load balancer. Seven A
  records point at the machines and each terminates TLS itself.
* **"A corporate firewall rule, network team to fix."** My own first verdict, wrong. The
  block is ours.

## Traps around VERIFYING this change — three near-misses on one commit

Each of these would have produced a confident wrong answer, and all three were about
reading the sync instead of the value:

1. **Annotating the Kustomization does not refetch Git.** It re-applies the cached artifact
   and reports success. Two reads after the merge returned the OLD four CIDRs. The
   GitRepository must be annotated too — that is what `flux reconcile --with-source` does,
   and `flux` is not installed on the WSL box.
2. **A read taken during a reconcile shows the previous revision.** Dev and QA both did
   this. The cure is a second read, not a diagnosis.
3. ⚠️ **`.status.lastAppliedRevision` and the Ready condition DISAGREED on op-qa.** The
   field said `625b1cc`, the condition in the same object said
   `Applied revision: op-qa@sha1:4005c6e` with a timestamp 30 seconds old. **Trust the
   condition — it carries `lastTransitionTime`; the field does not.** QA runs Flux v2.7.5
   against dev's v2.8.8, so this may be version-specific.

**The only reliable gate is reading the value itself**, which is why every block here ends
with the live `fromCIDR` list rather than a Ready column.

## Traps

1. **A pod-selecting network policy passes ICMP to the node.** Ping succeeds, the port
   dies. That split reads as a firewall and was the thing that misled the diagnosis.
2. **The answer was already written down.** `wip/onprem-networking/CHANGELOG.md` records
   this policy and its exact CIDR list, and `wip/onprem-qa-ingress/pr-1645-review-2026-08-20.md`
   cleared a review question by quoting it. A 2026-09-08 note nevertheless told Idris no such
   policy existed on any cluster. **Search the notes before probing the cluster.**
3. **The on-prem clusters are not in the default kubeconfig.** `kubectl --context
   admin@op-usxpress-dev` returns "context was not found", which is a transport failure and
   not evidence of absence. That is probably how the 2026-09-08 claim was produced.
   Files: `op-usxpress-dev-fresh.yaml`, `op-usxpress-qa-sso.yaml`, `op-usxpress-prod.yaml`.

## Open

* ✅ **ANSWERED 2026-10-20 — Tim is the same fault and he is not in the office.** He works
  from home behind a hardware **ASA** teleworker tunnel, which puts his machine on corporate
  space (`172.17.13.100/24`, gateway `172.17.13.254`) rather than the AnyConnect pool. AD
  registers that space as `172.17.0.0/16`, which is **not** on the allow-list. He has been
  blocked by this policy since 2026-06-02, including on 2026-09-08 when he was told nothing
  was rejecting him by address.

  **"Only VPN users can reach it" was the wrong generalisation.** It is only the AnyConnect
  pool `10.11.0.0/19`. Anyone reaching corporate space by any other route — an office desk, a
  home ASA, the DR site — is blocked. Tim is therefore the tester: blocked, technical,
  reachable, and not dependent on anyone being at a desk.
* **The subnet list.** Needed from Steve. Two client ranges are known from incidents
  (`10.10.72.0/24`, `172.17.13.0/24`); building the list from two laptops locks out the third.
