---
name: qa-vs-dev-delta
description: Key deliberate differences between op-usxpress-qa and op-usxpress-dev clusters
metadata: 
  node_type: memory
  type: reference
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
---

Deliberate QA-vs-Dev cluster differences (full living doc: `docs/architecture/qa_vs_dev_delta.md`, in the working tree on `main`).

- **AWS accounts:** Dev = USX-Dev `700736442855`; QA = USX-QA `527101283767`. Parent zone `usxpress.io` in account `155768531003`.
- **DNS:** Dev `op-dev.usxpress.io`, QA `op-qa.usxpress.io`. SM secret prefixes `op-usxpress-{dev,qa}/*` (IRSA scoped to prefix for blast-radius isolation).
- **Control plane:** both 3× CP, 4 vCPU. Dev CP RAM 8 GB (bumped from 4 after 2026-06-17 OOM incident), security agents CP-excluded. QA CP RAM **16 GB**, security agents CP-INCLUDED at 256Mi hard cap (keeps kube-apiserver/etcd/kcm visibility).
- **Worker topology:** Dev = flat 7×4GB. QA = 3 tainted/labeled pools: System 2×8GB, Platform 3×16GB (`pool=platform:NoSchedule`), Application 5×32GB (`pool=application:NoSchedule`, runs RisingWave + Rook OSDs). Reason: prevent app-pod OOM cascading a node hosting a critical DaemonSet.
- **Aggregate:** QA ≈ 3.1× Dev — 272 GB RAM, 124 vCPU, 2.6 TB disk.
- **Talos:** Dev v1.32.0; QA latest v1.32.x patch at build time.

Related: [[qa-cluster-standup]].
