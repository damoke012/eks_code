---
name: datalake-kafka-s3-monitoring
description: "New workstream — Nathaniel/Anthony's Confluent→S3 data-lake migration wants Kafka Connect + S3 alerting; platform (Steve/Matt) to scope via Grafana; ticket pending"
metadata: 
  node_type: memory
  type: project
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
---

New request to the platform team (call 2026-07-10, Nathaniel + Anthony ↔ Steve + Matt). Not Dare's build; platform is being asked to help with monitoring/alerting.

**Context:** Migrating the analytics data lake from Confluent Cloud Snowflake-sink connectors (Snowflake account bridged Ohio→analytics) to self-hosted **Kafka Connect S3 sink connectors** — S3 as the bridge to Snowflake. Anthony is architecting; currently **hybrid/parallel in prod** (backfilling historical data, then cutting off the Snowflake data share). Uses QA/Stage/Prod only (no dev — they're consumers, not producers).

**The ask:** alerting/monitoring for (a) **failed Kafka Connect connectors**, and (b) **stale data / no new files in S3 past a threshold** ("no file in 24h", "no message in topic in 1h"; event-based metrics like S3 create-file events). Want to avoid custom CloudTrail/CloudWatch (cost). Looked at **Grafana** — no metrics there yet; needs an integration built to create the metrics, then alerts. Matt: "mostly on the Grafana side." Plan: FreshService email integration for alerts.

**Repos/resources:** IX Kafka Topics repo + Snowflake DX/PX repo (Vivint/Vivian created a repo leveraging the DX infra piece to provision Snowflake-specific S3). Bucket: search "Kafka" in the **US Xpress prod** AWS account. JIRA Epic "Confluent Cloud migration to S3 data lake."

**Next:** they file a FreshService ticket + JIRA story link with repos/architecture; platform does discovery. Treated as research/discovery, may prompt broader alerting work.

**Platform framing (2026-07-13 standup):** discovery = platform work (Idris leads), "not on our budget" but owned as platform. Model = platform provides **Grafana (metrics) + step-by-step guidance so app teams create their OWN alerts**; platform doesn't build each app's alerts. Notification/ticketing layer = **FreshService** (admin **Josh Gilliland / "Josh G"**; replaced PagerDuty; group→email routing). Two legs: (1) alerting/Grafana metrics, (2) notification via FreshService. Quick first win = pod crash-loop alerts on cloud + on-prem. Filed **INFRA-1592** (data-lake alerting discovery) + **INFRA-1593** (crashloop alerting), 2026-07-13. NOTE: **Idris created INFRA-1588** "Configure Grafana Alert Integration with Freshservice Alert Management" (the integration/plumbing) — INFRA-1592/1593 relate to it; reconcile 1593 (fold into 1588 or keep as first-alert child). INFRA board = 322 (UI board).

**Side fact:** variant AWS accounts being decommissioned — "we don't put anything in variant anymore"; a ticket was filed to drop `variant data` + `variant data dev` accounts from the org. Related: [[repo-branch-topology-recovery]].
