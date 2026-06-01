---
key: INFRA-1506
status: filed
assignee: Doke
reporter: Doke
created: 2026-06-01
filed: 2026-06-01
initiative: onprem-networking
parent_link: INFRA-472
labels: [qa-readiness, security]
---

# Research + recommend etcd encryption-at-rest pattern for on-prem Talos (QA gate)

## Context
Today on op-usxpress-dev (Talos), k8s Secrets are stored in etcd **base64-encoded but NOT encrypted at rest**. AWS Secrets Manager is the source of truth, but once ExternalSecrets writes a value into a k8s Secret object, it sits in etcd as base64 — anyone with access to the etcd DB file (or a snapshot) can decode them. AWS EKS abstracts this away (cloud team doesn't see the control plane), but on-prem owns the control plane so it's our problem.

Per the 2026-05-29 networking/CySec call, Doke explicitly scoped this as a **QA-promotion gate, NOT a dev gate**: "doesn't have to be solved in dev. Definitely not. But as we go into QA and we want to move into stages, we do have to have encryption" [23:30]. This ticket produces the recommendation doc; implementation is a separate ticket once the pattern is picked.

## Scope

**In:**
- Document the threat model: who can read etcd today, what gets exposed, what attack chain.
- Evaluate 4 options head-to-head:
  1. **k8s `EncryptionConfiguration`** (native, AESCBC or secretbox) — Talos exposes via machine-config field `apiServer.encryptionConfig`. Lowest operational lift.
  2. **KMS provider plugin** (AWS KMS / Vault transit) — k8s offloads encryption to external KMS. Strong key management; needs working KMS endpoint reachable from CP.
  3. **Vault-as-KMS** — Vault transit secret engine as the KMS provider. Steve Vives loves Vault technically; hates ops uplift. No in-house Vault expertise.
  4. **Disk-level (SELinux/LUKS/Talos disk encryption)** — encrypt the whole CP node disk via LUKS or Talos's `systemDiskEncryption`. Brendan flagged SELinux on the call but SELinux is access control NOT encryption; Talos doesn't use SELinux the way RHEL does. Real disk-level = LUKS or Talos disk encryption.
- For each option: setup cost, operational cost, key rotation story, recovery story (chicken-and-egg if KMS is unavailable at bootstrap), DR portability, compatibility with the AWS-SM-as-source-of-truth pattern, blast radius if compromised.
- Recommend ONE for QA + a path to PROD; circulate to Brendan + Vives + Duck for review.

**Out:**
- Implementation (separate ticket once pattern chosen).
- Application-level secret encryption (RW built-in secret manager is separate).
- Vault deployment itself (out of scope unless picked as the answer).

## Definition of done
- [ ] Threat model section + which classes of attack each option mitigates
- [ ] Side-by-side options table (4 columns × ~8 criteria)
- [ ] Recommendation for QA + reasoning
- [ ] Migration story from current (no encryption) to chosen pattern
- [ ] DR story: what happens if the KMS is down at CP bootstrap
- [ ] Doc committed to `docs/designs/etcd-encryption-at-rest.md`
- [ ] Brendan + Vives + Duck reviewed (PR comment or Teams ✅)

## Suggested approach
Skim Talos docs first to scope which options are even available:
- https://www.talos.dev/v1.7/talos-guides/configuration/disk-encryption/
- https://www.talos.dev/v1.7/reference/configuration/v1alpha1/#config.apiserver.extraargs (encryption-config)

Then write up the comparison. Reference EKS posture (separate sub-ticket — INFRA-NEW "Document EKS cloud-side etcd encryption posture") so we know what we're matching.

## Constraints
- Output is a doc, not an implementation. Implementation is gated on this recommendation + Brendan sign-off.
- QA cluster buildout is the deadline this gates — coordinate with phase 2 of on-prem expansion (~3-4 weeks out).

## Links
- Parent initiative: [INFRA-472](https://usxpress.otlassian.net/browse/INFRA-472)
- 2026-05-29 call review: `wip/onprem-networking/networking-call-review-may29.md`
- Talos disk-encryption docs (URL above)
- Related: "Document EKS cloud-side etcd encryption posture" (sub-task — feeds this)

## Estimate
L — research + design doc + 3-person review cycle. ~2 days focused, calendar week including reviews.
