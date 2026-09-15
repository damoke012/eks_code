---
name: masked-secret-reads-as-network-fault
description: "A stale port in a masked CI secret times out exactly like a blocked network path — the log shows *** so the value is the one thing you cannot see"
metadata:
  type: feedback
---

`risingwave-pipeline`'s Postgres step failed with:

    psql: error: connection to server at "***" (10.101.88.195), port *** failed: Connection timed out

The IP was correct — `postgres-postgresql` in the `risingwave` namespace on op-usxpress-dev.
Host, credential and DNS were all right. The cause was a **stale `POSTGRES_PORT`** on the
GitHub `dev` environment, last set three months earlier for the `risingwave-2` era. Setting it
explicitly to 5432 made the run pass on the next attempt; the RisingWave leg passed the same
way with `RISINGWAVE_PORT` pinned to 4567.

**Why it misleads.** A wrong port on a ClusterIP **drops** packets rather than refusing them,
so it produces a timeout — the signature everyone reads as "firewall" or "network policy". And
CI masks the value, so the log shows `port ***`: the single field that is wrong is the one
field you cannot read. I spent two rounds on NetworkPolicy and Istio ambient before this.

Both hypotheses were checkable and both were WRONG, which is worth recording: the
`postgres-postgresql` NetworkPolicy has ingress `ports: [5432]` with **no `from:` clause**, so
it admits every source; and there were no AuthorizationPolicies or PeerAuthentications at all,
so ambient mesh was not enforcing anything either.

**How to apply:** on a CI connection timeout to an address you have verified, re-set the
masked coordinate secrets to known-good values BEFORE investigating the network. It costs one
command and eliminates the only field the log will not show you. Order matters — the network
hypotheses are more interesting and much slower to test, and a stale secret is likelier
whenever the target has recently moved.

Related: [[gha-oidc-needs-environment-claim]], [[transport-failure-not-a-verdict]],
[[proxy-is-not-the-property]], [[eso-secretsynced-not-content-check]].
