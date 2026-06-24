# INFRA-1557 — TF state cross-region replication advisory

| Field | Value |
|---|---|
| Ticket | INFRA-1557 |
| Audience | Cloud-ops team (Matt Hagden + Steve Duck post-Vibin) |
| Bucket | `lazy-tf-state-65v583i6my68y6x9` |
| Bucket account | 700736442855 (USX-Dev) |
| Bucket region | us-east-2 |
| Risk | Single-region S3 dependency for the on-prem cluster's TF state |
| Recommended action | Enable S3 Cross-Region Replication (CRR) to a sibling bucket in us-west-2 |
| This ticket scope | **Advisory only** — cloud-ops owns the implementation. We deliver the analysis + recommendation, then close on their acknowledgement. |

## Why we surface this

The on-prem cluster `op-usxpress-dev` stores its Terraform state in S3 bucket `lazy-tf-state-65v583i6my68y6x9` (us-east-2 / USX-Dev account 700736442855). This state is a critical artifact:

- It's the **only durable source of truth** for the Talos cluster's machine secrets, including the bootstrap certificates needed to talk to the API server.
- During the **2026-06-17 control-plane OOM cascade incident**, our recovery procedure required pulling this state from S3 to reconstruct a working `talosconfig` (see [[incident_2026_06_17_cp_oom_cascade]] and [[onprem-safety]] Rule 6).
- The cluster therefore has a **hard, undocumented runtime dependency on us-east-2 S3 availability** for any disaster-recovery scenario.

Any us-east-2 region-level S3 outage (rare but historically real — most recent significant degradation was December 2024) would leave us-east-2-only state inaccessible during the exact window where on-prem recovery procedures would need to read it.

## What we're recommending

Enable S3 Cross-Region Replication on `lazy-tf-state-65v583i6my68y6x9` to a sibling bucket in us-west-2. Standard pattern; this is a well-trodden AWS feature.

**Suggested target bucket:** `lazy-tf-state-65v583i6my68y6x9-replica` in us-west-2, same account (700736442855 / USX-Dev).

**Suggested CRR configuration:**

- **Replication scope:** entire bucket (no prefix filter)
- **Replica storage class:** Standard (same as source); cost is dominated by the small state files, not the storage tier
- **Replica encryption:** SSE-S3 (match source); CMK not required for state
- **Replica time control (RTC):** optional but recommended for SLA; ~$0.015 per GB makes it cheap given small state size
- **Object ownership on destination:** Bucket Owner Enforced (no ACLs)
- **Versioning:** must be enabled on both source and destination buckets (Terraform best practice anyway; if not already on, this is a Terraform state hygiene fix worth doing regardless)

**IAM:**

- Create a CRR replication role in account 700736442855 with `s3:GetReplicationConfiguration`, `s3:ListBucket`, `s3:GetObjectVersionForReplication`, `s3:GetObjectVersionAcl`, `s3:GetObjectVersionTagging` on source; `s3:ReplicateObject`, `s3:ReplicateDelete`, `s3:ReplicateTags` on destination.
- Standard CRR role pattern; well-documented in AWS S3 user guide.

## Cost estimate

State files are tiny (~50-200 KB per cluster). Even with high churn:

- **Storage replica:** $0.023 per GB-month × ~100 MB = effectively zero per month.
- **Inter-region replication transfer:** $0.02 per GB × low churn = pennies per month.
- **RTC if enabled:** $0.015 per GB replicated = also pennies.

Total: **under $5/month**. Effectively free relative to the disaster-recovery value.

## Why it's a cloud-ops decision (not us)

- The bucket is in a cloud-ops-managed account (USX-Dev 700736442855) under cloud-ops Terraform governance
- Cross-region S3 patterns should be uniform across the org; we don't want a one-off bespoke replication just for this bucket if cloud-ops has a canonical pattern
- IAM role creation requires cloud-ops review

We're not requesting permission to implement — we're flagging the gap so cloud-ops can either implement it under their canonical pattern or explicitly document accepted residual risk.

## How to engage cloud-ops

Two delivery channels:

1. **Teams message** to Matt Hagden + Steve Duck with the summary below
2. **Optional email** to a cloud-ops shared inbox if Teams DM is insufficient

### Teams message (copy-paste)

> Hey Matt / Steve — wanted to flag a single-region S3 risk on the on-prem TF state for visibility:
> 
> Bucket `lazy-tf-state-65v583i6my68y6x9` in us-east-2 (USX-Dev 700736442855) holds the only durable source of truth for the op-usxpress-dev Talos cluster's machine secrets. During the 2026-06-17 CP OOM cascade we had to pull from this bucket to reconstruct a working talosconfig — recovery is gated on us-east-2 S3 being reachable.
> 
> Recommend enabling S3 Cross-Region Replication to a sibling bucket in us-west-2 same account. Storage + transfer cost is effectively free (state files are tiny). Tracking under INFRA-1557; not blocking anything today, but worth landing before the next region-level S3 wobble.
> 
> Full advisory + CRR config details at: <link to this doc when published, or paste content directly>
> 
> Happy to pair on the Terraform change if helpful, but the canonical pattern for cross-region S3 is yours.

## Acceptance criteria for closing INFRA-1557

This ticket closes **on cloud-ops acknowledgement**, not on implementation. Acknowledgement looks like one of:

1. Cloud-ops opens their own ticket to implement (this one cross-references and closes)
2. Cloud-ops accepts residual risk in writing (Teams reply or PR comment) and we capture the rationale in [[onprem-safety]]
3. Cloud-ops asks for help implementing — in which case we re-open under our scope and pair

## Jira close-out comment template (use after cloud-ops acks)

```
2026-MM-DD HH:MM UTC — Advisory delivered + acknowledged.
- Delivered via: <Teams DM / cloud-ops email / cloud-ops Slack channel>
- Recipients: Matt Hagden, Steve Duck
- Cloud-ops response: <link to their ticket OR risk-acceptance note OR pair-up agreement>
- This ticket closes on acknowledgement per its advisory scope.
- Full advisory text preserved at: iaac-drafts/jun24-closeout-prep/INFRA-1557-tf-state-crr-advisory.md (transfer branch on damoke012/eks_code)
```

Transition to Done.

## Related

- [[incident_2026_06_17_cp_oom_cascade]] — proves the S3 dependency is on the recovery path
- [[onprem-safety]] Rule 6 — talosctl admin access independent of Idris depends on S3 state read
- [[feedback-zero-cloud-impact]] — applies; we are advising, not implementing in cloud
- [[onprem-cluster-tf-state-location]] — canonical location reference
