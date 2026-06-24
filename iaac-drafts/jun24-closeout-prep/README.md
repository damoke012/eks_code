# jun24-closeout-prep — Tomorrow's three remaining tickets

Index of pre-drafted artifacts so tomorrow's session is pure execution, not drafting.

## The three tickets

| Ticket | Title | Blocker | Artifact | Tomorrow time |
|---|---|---|---|---|
| **INFRA-1555** | Postgres rw-2 local-path → ceph-block migration | Tim courtesy ping (rw-2 is ours, not his namespace) | [Migration runbook](INFRA-1555-postgres-migration-runbook.md) | ~45 min including Velero pre-backup |
| **INFRA-1557** | TF state cross-region replication advisory | Cloud-ops team owns | [CRR advisory](INFRA-1557-tf-state-crr-advisory.md) | ~5 min — paste Teams message, wait for ack, close |
| **INFRA-1558** | Azure AD OAuth app reg for Grafana SSO | IT lead (Application Administrator role) | [IT request](INFRA-1558-azure-ad-oauth-app-request.md) | ~10 min to draft + send; close on completion (their timeline) |

Total Doke-side keyboard time: ~60 min if all three execute back-to-back.

## Execution order suggestion

1. **INFRA-1557 first** (5 min) — paste Teams message, async wait for ack. Can run in parallel with everything else.
2. **INFRA-1558 next** (10 min) — draft and send IT request. Their reply is async; we move on.
3. **INFRA-1555 last** (45 min) — needs focused attention + Tim ack first; do this when you can give it the time.

After all three are sent / executed, the sprint clears completely on Doke's side. Idris's INFRA-1476 (RW user management) is his to own.

## Decision points pre-execution

### INFRA-1555 — Postgres data persistence

The runbook does NOT restore Postgres data files by default — the new ceph-block PVC initialises a fresh DB. Before executing, confirm:

- Is rw-2 Postgres a transient meta-store that RW rebuilds from compute nodes? → no data restore needed
- OR does it hold operator state that must persist? → add Velero file-level restore step before Step 5

Verify by reviewing the rw-2 RisingWave operator chart values and Postgres usage pattern. If unclear, ask Tim (he originally helped scope rw-2's Postgres dependency).

### INFRA-1557 — Delivery channel

Pick one of:
- Teams DM to Matt Hagden + Steve Duck (fastest)
- Email to cloud-ops shared inbox (more durable, slower ack)
- Open a cloud-ops Slack channel post (depends on whether they use Slack)

Default: Teams DM. Falls through to email if no ack within 24h.

### INFRA-1558 — Who is the IT lead

We don't have an explicit IT-lead name in memory. Options:

- USXPress IT helpdesk (Freshservice ticket — formal channel)
- Direct ping to USXPress identity / IAM team via Teams (faster but depends on knowing the right person)

Suggested: file a Freshservice ticket with the full request body from the artifact. This creates an audit trail and the helpdesk routes to the right Application Administrator.

## When all three close

The 2026-06-23 → 2026-06-24 marathon is fully wrapped. Update [[session-state-jun24]] to mark the sprint clear and queue the next focused-session work:

- INFRA-1535 / INFRA-1543 Octopus OnPremise space stand-up (if Doke confirms Octopus admin)
- 5 catalog entries for `variant-inc/iaac-talos/deploy/docs/troubleshooting/` (pair-able with Idris per Idris-PR-#53-close-comment)

## Related

- [[session-state-jun24]] — full session context
- [[observability-phase0-locked-jun24]] — Phase 0 ADR live
- [[feedback-protect-rw-onprem-workload]] — applies to INFRA-1555
- [[feedback-zero-cloud-impact]] — applies to INFRA-1557
- [[feedback-never-accept-pasted-secrets]] — applies to INFRA-1558
