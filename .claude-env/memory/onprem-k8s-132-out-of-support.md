---
name: onprem-k8s-132-out-of-support
description: "MEASURED 2026-10-20: op-usxpress-qa runs Kubernetes v1.32.0 on every node — upstream EOL since 2026-02-28, and never patched past .0 while the line ended at 1.32.13. Self-managed Talos, so no vendor extended support exists"
metadata:
  type: project
---

**Measured on op-usxpress-qa, 2026-10-20.** All 13 nodes report **`v1.32.0`**, built
2024-12-11, OS Talos.

| | |
|---|---|
| Running | **v1.32.0** — the *initial* release of the line |
| Final patch in that line | **1.32.13** |
| Upstream end of life | **2026-02-28** — eight months ago |
| Vendor extended support | **none applies.** EKS extends 1.32 to 2027-03-23, but this is **self-managed Talos**, not EKS |
| Cloud EKS, for contrast | dev/QA/staging **1.36**, prod **1.35** |

So on-prem is **three to four minor versions behind cloud**, past upstream end of life, and
**has never taken a patch release within its own minor version** — thirteen of them shipped
and none was applied.

⚠️ **This invokes the team's own stated upgrade rule and fails it.** The rule
([[dont-chase-the-latest-version]]) is *move when the support window is closing* — not chase
the newest. The window did not close recently; it closed in February.

⚠️ **Prod is not measured.** Near-certain to be the same, since all three clusters are built
from the same Terraform and content-library image, but **near-certain is not measured**. Run
the same command against `op-usxpress-prod.yaml`.

**How to apply.** Any "is on-prem production-ready" conversation has to carry this. It is
larger than the item that prompted it (human sign-on), it needs a Talos upgrade path nobody
has written, and the upgrade is control-plane work on three clusters — so it is sprint-sized
on its own, not a task inside something else.

Sources: Kubernetes release pages give 1.32's EOL as 2026-02-28 with final patch 1.32.13.

Related: [[eks-k8s-upgrade]] (the cloud-side programme), [[flux-version-drift-dev-ahead]].
