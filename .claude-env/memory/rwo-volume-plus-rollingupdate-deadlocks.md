---
name: rwo-volume-plus-rollingupdate-deadlocks
description: A Deployment with a ReadWriteOnce PVC and the default RollingUpdate strategy deadlocks permanently on any multi-node cluster, while reporting Available=True
metadata:
  type: project
---

**Measured on op-usxpress-prod 2026-10-27.** `risingwave-console` had been stuck mid-rollout
since **2026-10-13** — fourteen days — and every dashboard read healthy.

```
strategy: RollingUpdate (maxSurge 25%, maxUnavailable 25%)
volume:   PVC risingwave-console-data, ReadWriteOnce, ceph-block
old pod:  ...-5b678c59c4-lbzps  talos-wk-op-prod-platform-2  Running since 2026-09-01
new pod:  ...-6ffc5644d9-x4bmp  talos-wk-op-prod-platform-3  Pending since 2026-10-13
```

A ReadWriteOnce volume attaches to **one node**. RollingUpdate starts the replacement before
stopping the original, the scheduler puts it on a different node, and it waits for a volume
that is only released when the rollout completes — which it never can. Both ReplicaSets
carried the **same image** (`v0.7.4`), so this was not an upgrade; a pin bump merely triggered
a rollout.

**Why:** `Available=True MinimumReplicasAvailable` the whole time, because the old pod kept
serving. The only outward sign was the `risingwave-onprem` Kustomization sitting
`Ready=False` for 55 days, and nothing alerts on that ([[onprem-alerts-not-delivered]]).

**How to apply:**
* **Any Deployment mounting a ReadWriteOnce PVC needs `strategy: {type: Recreate}}`.** Not a
  tuning preference — RollingUpdate is a guaranteed deadlock there on more than one node.
  Kubernetes defaults to RollingUpdate, so omitting `strategy:` IS choosing the broken one.
* **All five init containers showing `started=false` means the pod never began.** Even a
  busybox `mkdir` had not run. That is a volume or scheduling problem, never a script
  problem — do not read the init scripts. Related: [[transport-failure-not-a-verdict]].
* Events expire. After two weeks `describe pod` shows `Events: <none>`, so the pod's own
  history is gone and the spec is all you have.
* The fix was **already in QA's manifest** with a comment explaining it, and had never been
  propagated to dev or prod. Check the sibling environments' files before diagnosing from
  scratch: [[manifests-copied-across-branches]], [[edited-copy-is-not-the-shipped-copy]].
* Fixed by PR #61 on `iaac-risingwave-onprem`, tagged `v0.13.3`.
