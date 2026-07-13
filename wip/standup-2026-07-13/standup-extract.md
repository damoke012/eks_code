# Standup extract — 2026-07-13 (Mon) "Platform Secrets Cleanup And Deployment Planning"

**Attendees:** Rohit, Parul ("Peru"), the standup lead/Host (org-admin/access — likely **Steve**), Idris, and the platform architect (speaks as on-prem Talos owner — this is **Dare/you**; diarization labels vary "Mark"/"Dean" across transcripts). NOTE: there is ALSO a genuinely-new team member named **Mark** being onboarded ("we'll be assigning stuff to you by end of week") — distinct from the architect voice the transcript mislabels. Attribute by role, verify names.

---

## Status changes (move these)

| Item | Change | Notes |
|---|---|---|
| **MAN-242** | → **DONE** | GH service identity ADO→on-prem Manhattan VM; token via CI/CD, no personal info (Marvel + Idris). SAPS account set up, AWS sink into CICD, tested. **Only a PR left to push.** |
| **QA cluster creation** (INFRA-15xx under 1585/1560) | → **DONE** | "creating the QA cluster is already done." Tickets not yet updated in Jira. Split the lessons-learned automation into a NEW follow-up (T1) rather than holding this open. |
| Secret rotation — DPL | ✅ tested today, worked (rerun job after cleaning secret) | Proves the runbook method. |
| `xpm-classic-auth-dx` (7/17) | **negated** — no longer urgent | Confirms XPM stale/handled; buys time on the others. |
| Parul Azure access | ✅ **now has it** (tested this morning, works) | Corrects prior "not yet." Access adjustments landed Fri; Idris/you should also have better Azure access today. |

## In progress (no new ticket — status)
- **2 stage secrets** to clean up + **2 apps** to redeploy in stage — Parul, today, after a ~1hr dev-team announcement window (Rohit posted the announcement; Parul isn't a moderator on the DevEx Teams announce channel → **Steve to add her**).
- **Deployment-failures fix** on dev cluster: Rohit confirms all nodes ready, no orphan node claims, no issues → ready to promote to prod. Gate: Rohit to report **how many deployments bounced against it (through ~Thu)** before promoting. Timebox the prod promotion.
- Failure-list triage: recent failures are AD-access / McLeod-weekend-update / unrelated — NOT node or our changes. Parul+Rohit to keep validating; **pull new-Mark in to learn**.

---

## NEW TICKETS — FILED 2026-07-13 (INFRA-1589..1594)

| Draft (T#) | Filed key |
|---|---|
| T1 QA flux-automation + rebuild | **INFRA-1589** |
| T2 Wiz eBPF dev | **INFRA-1590** ⚠️ probable dup of INFRA-1505 — reconcile |
| T3 Platform SSO (Entra) | **INFRA-1591** |
| T4 Data-lake alerting discovery | **INFRA-1592** |
| T5 Pod crashloop alerting | **INFRA-1593** |
| T6 EKS K8s upgrade | **INFRA-1594** |

Draft bodies moved to `jira/sent/INFRA-159x-*`.

## NEW TICKETS — original drafts

### T1 — Automate QA platform-stack Flux reconciliation params + rebuild QA to validate
- **Epic:** INFRA-1560 (QA/prod readiness). **Type:** Story. **Owner:** platform lead (you).
- **Why:** lessons learned standing up QA — several Flux-reconciliation parameters for the platform stack were manual. Automate them, then **rebuild the QA cluster from scratch** to prove near-zero manual steps. This is the gate before spinning up **prod**. Not retrofitted to dev.
- **AC:** manual steps identified + parameterized in IaC; QA rebuilt clean from code; runbook updated; sign-off to proceed to prod cluster.

### T2 — Deploy Wiz (eBPF sensor) on dev cluster
- **Epic:** INFRA-1560 / security. **Owner:** new-Mark + Steve Vives. **This week.**
- **Why:** Wiz replaces Orca on-prem (per 2026-05-29 CySec call). Onboard sensor to dev (top crown-jewel hosts), egress to wiz.io.
- **AC:** Wiz sensor running on dev cluster; visibility confirmed; docs.

### T3 — Platform SSO via Entra ID (discovery + design)
- **Epic:** INFRA-1559 (AAD identity strategy). **Owner:** Idris. **First consumer:** RisingWave SSO.
- **Why:** RW SSO needs Entra client credentials/secret + tenant ID. Do it as a **reusable dev service-account pattern (platform solution), NOT one-off per app.** Discovery first (Confluence/JIRA design page) since it's the first time — align before implementing.
- **AC:** design page; dev service-account Entra app reg pattern; RW SSO wired as first consumer; repeatable for other apps.
- **Blocked-by:** Azure access (now granted) — Idris to confirm what's possible before requesting a meeting.

### T4 — Data-lake alerting discovery (Kafka Connect + S3)
- **Epic:** platform / observability. **Owner:** Idris (discovery). Relates to Nathaniel/Anthony FreshService ticket + JIRA Epic "Confluent Cloud migration to S3 data lake."
- **Why:** alert on Kafka Connect connector failures + stale S3 data (no file in 24h / no topic msg in 1h). Discovery = documentation + plan + **step-by-step guidance so app teams create their OWN alerts** (platform provides Grafana + guidance, not the alerts themselves). "Not on our budget" → framed as platform discovery, all hands by bandwidth.
- **AC:** discovery doc; metric/integration approach in Grafana; app-team self-serve alert guide; FreshService notification wiring plan.

### T5 — Pod crash-loop alerting (cloud + on-prem) via Grafana → FreshService
- **Epic:** observability. **Owner:** platform. **Quick first win.**
- **Why:** low-hanging alert both clusters; wire notification through FreshService (group→email). Second leg of the alerting model (notification/ticketing).
- **AC:** crashloop alert firing in cloud + on-prem; routed via FreshService group; documented.

### T6 — AWS EKS Kubernetes version upgrade (assess + automate)
- **Epic:** cloud platform. **Owner:** new-Mark (ramp/drive), Parul + Rohit guide.
- **Why:** confirm current EKS version (~1.34/1.35) vs AWS-supported latest; plan an **automated (fleet-style) upgrade**, flowing dev → QA/staging → prod. Parul has end-to-end upgrade docs to build on.
- **AC:** current-vs-supported version report; automated upgrade approach; upgrade runbook; scheduled per-env rollout.

### (informational, likely no ticket)
- Idris created a **MongoDB secret for Tim** + notified him re: RisingWave. Done.

---

## Actions (non-ticket)
- **Board cleanup:** Parul + Rohit (+you) review the old Jira board before **Wed 2026-07-15** — mark done/still-needed; clean up Wed.
- **Access:** Steve to (a) add Parul as moderator to DevEx Teams announce channel, (b) add Parul/Rohit/Idris to the **9:30 FreshService call today** (admin: **Josh Gilliland / "Josh G"** — FreshService replaced PagerDuty).
- **Onboarding new-Mark:** copy him on threads (failure reviews, Wiz, EKS upgrade); assignments by end of week.

## Sprint
Mid-sprint; QA sprint started last week, likely ends this week. Tickets not yet updated — do so alongside the moves above.
