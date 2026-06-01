---
key: INFRA-1503
status: filed
assignee: Doke
reporter: Doke
created: 2026-06-01
filed: 2026-06-01
initiative: onprem-networking
parent_link: INFRA-1492
---

# Prometheus cert-expiry alerting for op-dev wildcard + per-team certs

## Context
Per the 2026-05-29 networking/CySec call, Doke committed to wiring Prometheus expiry alerts as a safety net beneath the (planned) automated LE rotation. cert-manager already exposes Prometheus metrics (`certmanager_certificate_expiration_timestamp_seconds`) — this ticket adds the Alertmanager rules that fire on `<14d` to expiry, so the team is notified well before a cert would actually fail.

Lightweight + additive. Pair with the "Automate LE cert rotation" ticket.

## Scope

**In:**
- Confirm cert-manager Prometheus metrics endpoint is scraped (it should be — verify on the live cluster).
- Add a `PrometheusRule` (Kustomize, in `iaac-talos-flux-platform` op-dev branch) with two alerts:
  - `CertExpiringSoon` — fires at 14 days remaining
  - `CertExpiringCritical` — fires at 7 days remaining
- Route the alerts to the team's existing Alertmanager destination (Teams / Slack / wherever).
- Test by issuing a short-lived cert (or temporarily tweaking the alert threshold).

**Out:**
- New monitoring stack — reuse what's there.
- Auto-rotation itself (separate ticket).
- Renewal success notification (covered in the rotation ticket).

## Definition of done
- [ ] `PrometheusRule` resource exists on op-usxpress-dev with two thresholds (14d warn, 7d critical).
- [ ] Test alert verified firing path end-to-end (artificial threshold drop OR sacrificial cert with short duration).
- [ ] Routing destination configured (Teams channel / Slack / Alertmanager receiver).
- [ ] Documented in `wip/onprem-networking/` runbook.

## Suggested approach
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cert-manager-expiry-alerts
  namespace: cert-manager
spec:
  groups:
  - name: cert-expiry
    rules:
    - alert: CertExpiringSoon
      expr: (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 14
      for: 1h
      labels: {severity: warning}
      annotations:
        summary: "Cert {{ $labels.namespace }}/{{ $labels.name }} expires in <14d"
    - alert: CertExpiringCritical
      expr: (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 7
      for: 1h
      labels: {severity: critical}
      annotations:
        summary: "Cert {{ $labels.namespace }}/{{ $labels.name }} expires in <7d"
```

## Constraints
- No Octopus access required.
- Lives in `iaac-talos-flux-platform` op-dev (PR base).

## Links
- Parent umbrella: [INFRA-1492](https://usxpress.atlassian.net/browse/INFRA-1492)
- 2026-05-29 call review

## Estimate
S — single Kustomize manifest + verification. ~2 hours.
