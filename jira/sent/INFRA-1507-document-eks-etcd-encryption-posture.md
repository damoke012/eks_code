---
key: INFRA-1507
status: filed
assignee: Doke
reporter: Doke
created: 2026-06-01
filed: 2026-06-01
initiative: onprem-networking
parent_link: INFRA-NEW-etcd-at-rest-research
labels: [qa-readiness, security]
---

# Document EKS cloud-side etcd encryption posture (mirror target for on-prem)

## Context
Per the 2026-05-29 networking/CySec call, the on-prem etcd-at-rest research ticket ("Research + recommend etcd encryption-at-rest pattern") needs a clear picture of what EKS does today — so the on-prem solution either matches or consciously diverges with a documented reason. EKS abstracts the control plane so it's opaque from the cloud team's day-to-day view, but the AWS docs + console expose enough.

Quick doc, sub-task of the research story.

## Scope

**In:**
- Confirm whether the USXpress EKS clusters have **envelope encryption** enabled (per-cluster setting; uses AWS KMS to encrypt etcd Secrets).
- Document which KMS key(s) — alias, ARN, owning AWS account.
- Note any cluster-by-cluster divergence (`usxpress-dev`, `qa-one`, `usxpress-prod`).
- Document key rotation cadence (KMS auto-rotation by default; confirm).
- Surface to the on-prem etcd-at-rest research as the "mirror target."

**Out:**
- Changes to EKS configuration (cloud team's call).
- Application-layer encryption.

## Definition of done
- [ ] Each EKS cluster's envelope encryption status documented (on/off + KMS key)
- [ ] Findings written up in `docs/architecture/eks-etcd-encryption-posture.md` (or appended to the etcd research doc)
- [ ] Referenced from the parent research ticket

## Suggested approach
```bash
# Per cluster
aws eks describe-cluster --name usxpress-dev --profile usx-dev --region us-east-2 \
  --query 'cluster.encryptionConfig'
aws eks describe-cluster --name qa-one        --profile usx-qa  --region us-east-2 \
  --query 'cluster.encryptionConfig'
aws eks describe-cluster --name usxpress-prod --profile ops-controller --region us-east-2 \
  --query 'cluster.encryptionConfig'
```
If the response is empty, envelope encryption is OFF. If present, it lists `provider.keyArn` and the resources covered (typically just `secrets`).

Consult cloud platform team (Vibin / cloud-team Slack channel) if anything is unclear — they own the EKS terraform.

## Constraints
- Read-only. No EKS config changes.
- Coordination only with cloud team (no Octopus involvement needed).

## Links
- Parent: "Research + recommend etcd encryption-at-rest pattern" (sibling ticket)
- 2026-05-29 call review

## Estimate
S — 3 AWS describe calls + write-up. ~1 hour focused.
