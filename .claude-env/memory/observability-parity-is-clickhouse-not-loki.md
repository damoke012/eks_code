---
name: observability-parity-is-clickhouse-not-loki
description: "USX log aggregation is OTEL into otel_logs_custom (ClickHouse) read from the Application Monitoring Grafana dashboard — there is NO Loki data source. Argo CD's per-pod log view is not parity, and Octopus injects the OTEL endpoint vars"
metadata:
  type: project
---

**2026-10-20, pricing-app onboarding call.** Doke proposed Loki as the on-prem log store.
Andres then shared his screen: every log query in the **Application Monitoring** dashboard
reads **`otel_logs_custom`**, and **no Loki data source exists** in the USX Grafana. Shrikant:
*"I believe Loki was replaced by ClickHouse."* Killed by reading the live dashboard, in under
a minute, after it had been asserted twice.

**What the app teams actually do**, and therefore what parity means:

* **aggregated search across every pod** from one Grafana dashboard — Andres: *"we very rarely
  go to the pods because then you have to click on each one"*;
* P90/P95 latency per upstream dependency, for pinpointing which API got slow.

**Argo CD gives you one pod at a time. That is not parity**, and parity became a stated
requirement on the call — Shrikant: *"what I don't want to do is lose what we already got in
cloud."* Doke's commitment: observability does not change, we replicate it.

⚠️ **Octopus injects the OTEL endpoint variables** that make this work — *"it injects certain
variables to help it know where all the otel endpoints are."* They sit on the **non-sensitive**
side of the split, so they belong in the on-prem values file. **If they are missing the app
runs perfectly, Argo CD is green, and not one log line reaches the dashboard.** Nothing reports
it. Same shape as gate 5 of the delivery relay.

**How to apply.** Never propose a log backend for an app before reading the query the team
already uses. And when porting an app, port the **telemetry endpoint variables** with the same
seriousness as the credentials.

⚠️ **Unowned:** nobody on the call knew the USX log retention policy. Pod logs are ~24h; the
real answer is whatever the store is configured for, and that is unconfirmed.

Related: [[onprem-alerts-not-delivered]], [[delivery-is-a-relay-of-nine-gates]],
[[config-can-outrun-the-image]].
