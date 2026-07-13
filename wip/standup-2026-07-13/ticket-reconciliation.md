# Ticket reconciliation — 2026-07-13 (after viewing INFRA board 322)

My 6 tickets (INFRA-1589..1594) were created via API into the INFRA project **backlog** — they are NOT on the active sprint board (which shows 1583, 1584, 1585(IP), 1586). Reconcile against what already exists.

## Board 322 active-sprint contents (pre-existing, not mine)
- INFRA-1583 (TO DO) — Manhattan QA SSPI/Kerberos SQL auth failure — RCA + fix (Linux .NET SqlClient)
- INFRA-1584 (TO DO) — MAN-242 support: federated identity for Manhattan Sender/Handler pipeline
- INFRA-1585 (IN PROGRESS, ⚠️) — QA cluster stand-up (op-usxpress-qa) — sprint coordination + kickoff
- INFRA-1586 (TO DO, overdue Jul 10) — **Wiz sensor deploy to op-usxpress-dev (Steve Vives PR review + Flux wire-up)**
- INFRA-1588 — **Idris's** "Configure Grafana Alert Integration with Freshservice Alert Management" (+ freshservice-grafana-alerting doc attached)

## Collisions / actions on MY tickets
| Mine | Verdict | Action |
|---|---|---|
| INFRA-1589 QA flux-automation + rebuild | KEEP — unique; it's the concrete follow-on to INFRA-1585 | Link to INFRA-1585; add to active QA sprint |
| INFRA-1590 Wiz eBPF dev | **DUPLICATE of INFRA-1586** (live). Also older INFRA-1505 exists. | **Close 1590 as dup of 1586** |
| INFRA-1591 Platform SSO (Entra) | KEEP — unique (Idris's Entra "register an application" exploration feeds this) | Link to INFRA-1559; backlog/next sprint |
| INFRA-1592 Data-lake alerting discovery | KEEP but OVERLAPS INFRA-1588 | Link "relates to" INFRA-1588 |
| INFRA-1593 Pod crashloop → FreshService | OVERLAPS INFRA-1588 (Idris's integration ticket) | DECISION: fold into 1588 (close) OR keep as first-alert child of 1588 |
| INFRA-1594 EKS K8s upgrade | KEEP — unique | backlog |

## Decisions needed from Dare
1. INFRA-1593 vs INFRA-1588: fold (close 1593) or keep-and-link?
2. Which of my backlog tickets to pull into the ACTIVE sprint now (default: just 1589; rest stay backlog).

## Note
1589–1594 not on sprint = expected (API create → backlog). Sprint add needs the sprint id (board 322 active sprint) or drag on the board.
