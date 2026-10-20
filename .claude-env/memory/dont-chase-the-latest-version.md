---
name: dont-chase-the-latest-version
description: "Fleet upgrade policy stated 2026-10-20: stay N-1 of the latest AND move when the support window is closing. A newer version existing is not a reason — EKS is on 1.36 with 1.37 available, deliberately"
metadata:
  type: feedback
---

**Stated by Doke at the 2026-10-20 platform review**, when Rohit offered to take EKS to the
latest: *"we shouldn't be chasing the latest version. We should be making sure that the
version we are on is not about to lose support. So it's the other way around."* And: *"if we
go to 1.37, we'll be doing a test for them."* Mark added the second half: *"we want to stay
N minus 1 to the current latest."*

**Measured that day:** dev, QA and staging on **EKS 1.36**; ops and prod to follow. Latest
available **1.37**, skipped on purpose. **1.35** is the version losing support — that, not
1.37's existence, is what justified the move.

**Why:** being first on a release means doing the vendor's testing with production
infrastructure. The support window is the real deadline, and it is knowable months ahead.

**How to apply.** When asked whether to upgrade, answer with two facts, not one: *how far
from the latest are we* and *when does our version lose support*. "A newer version is out"
is not an answer. Applies to Kubernetes, Flux, Terraform providers and the RisingWave engine
alike — and note the exception that proves it: a provider taken on release day is exactly how
[[aws-provider-6691-breaks-lambda-read]] happened.

Related: [[eks-k8s-upgrade]], [[flux-version-drift-dev-ahead]], [[rw-version-uniform-but-eos]]
(where the version *is* end-of-support, so the rule says move).
