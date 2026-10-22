---
name: workflow-that-never-ran
description: A complete-looking workflow can be one nobody has ever dispatched; iaac-talos's two bootstrap workflows fail at step one because the credential they document was never created, and the old code disguised it as a permissions error
metadata:
  type: project
---

2026-09-17, `variant-inc/iaac-talos`. `onprem-account-bootstrap.yaml` and
`onprem-cluster-secrets.yaml` both read `secrets.ONPREM_BOOTSTRAP_ROLE_ARN_<ENV>`, and both
headers document creating it as a prerequisite. **The repo has exactly one secret:
`OCTOPUS_API_KEY`.** Neither workflow has ever been runnable, for dev, QA or prod.

Proved by dispatching, not by reading: runs `35229647746` (lowercase `dev`) and `35229975054`
(uppercase `DEV`) both stop at the first step with an empty role ARN.

**Why it stayed invisible:** the original `case` statement had no `*)` branch. A missing or
unmatched value set `arn=` to empty, passed it to `configure-aws-credentials`, and failed
three steps later — which reads as an AWS permissions problem, not as "this secret was never
created". A fail-closed check at the point of lookup turned a four-step-later mystery into one
line naming the exact secret.

**How to apply:** when a workflow's role in a process matters, **dispatch it before believing
it works.** Two things today looked complete in code and were not: this, and a merged PR that
Flux could never apply. The tell is the same in both — nothing had ever exercised the path.
For a `workflow_dispatch` with a dry-run input, the test is free.

And when writing any lookup over a map of credentials: **no default branch means an empty
value travels onward.** Fail at the lookup, name the key you wanted.

Related: [[adjacent-step-green-signals]], [[server-side-apply-keeps-dropped-fields]],
[[promotion-order-qa2-dev-qa-prod]], [[transport-failure-not-a-verdict]].
