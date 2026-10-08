---
name: eso-does-not-reach-a-laptop
description: "The External Secrets Operator is a Kubernetes controller with no interface outside a cluster, so a developer cannot 'call it' from docker-compose; the local equivalent is a script reading Secrets Manager over AWS SSO"
metadata:
  type: reference
---

**2026-10-08, on a call.** Tim asked whether he could use our External Secrets Operator to
seed his local Docker stack, and the answer given in the room was "absolutely". It is not
possible. **ESO is a Kubernetes controller**: its only inputs are CRDs
(`ExternalSecret`, `ClusterSecretStore`) and its only output is a Kubernetes `Secret`. There
is no CLI, no endpoint, nothing to invoke from docker-compose.

**What to offer instead.** A short script that reads AWS Secrets Manager directly and either
renders the developer's local `.env` or runs `CREATE SECRET` against their local RisingWave.
Same values, same source of truth, no cluster.

**And not with an access key.** The instinct in the room was "he needs an AWS access key".
He does not — on-prem human access is **AWS SSO** (`aws sso login`), already live. Minting a
static key for a laptop is a new long-lived credential to rotate, for a problem SSO already
solves.

**How to apply.** When a developer asks to reuse a platform component locally, check what its
*interface* is before agreeing. A controller that reconciles cluster objects has no local
mode, and "absolutely" costs them an afternoon of building toward something that cannot work.
The honest answer names the mechanism's shape, then offers the equivalent that does exist.

Related: [[onprem-human-access-model]], [[eso-writes-partial-secrets]],
[[secret-and-owner-are-two-axes]].
