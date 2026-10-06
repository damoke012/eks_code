---
name: cert-manager-ready-is-not-valid
description: "A cert-manager Certificate reports Ready:True while serving an expired certificate — op-dev served expired TLS on every hostname for 41 days; status.notAfter is the only field that answers it, and three separate things sit between a fixed cause and a working cert"
metadata:
  type: reference
---

Found 2026-10-06 on **op-usxpress-dev**. QA and prod were healthy throughout.
✅ **Fixed the same day**: all six reissued, expiry 2027-01-04, `verify=0` on every hostname.

## Ready:True does not mean valid

`Ready: True` means *a certificate was issued at some point*. It does **not** flip when the
stored certificate expires, and it does **not** flip when renewal fails — the failure lands on
a `CertificateRequest` and an `Order`, which nothing watches. Six certificates on op-dev were
expired 28–41 days (`wildcard-op-dev` = `*.op-dev.usxpress.io`, so Argo CD, Grafana and both
RisingWave UIs) and every one reported Ready.

**`.status.notAfter` is the only field that answers "will a browser trust this".**
`scripts/`-side checker: `wip/onprem-certs/check-cert-expiry.sh` — all three clusters, days to
expiry, failing requests, pending orders, and a real `ssl_verify_result` per hostname.

⚠️ **`curl -k` makes a TLS check agree with you.** `-k` disables verification, so a 200 proves
the route and says nothing about trust. The expiry was found by a *browser* showing "Not
secure" on a URL `curl -sk` had just called 200. Use `-w '%{ssl_verify_result}'`: 0 trusted,
**10 expired**, 18/19 self-signed, 20 no issuer cert.

## Root cause on dev, and the two things behind it

1. **No AWS credentials.** cert-manager fell back to EC2 IMDS for the Route53 DNS-01 solver —
   on bare-metal Talos. The SA *was* annotated with the IRSA role, identical to QA; the **pod**
   carried no `AWS_ROLE_ARN`. `pod-identity-webhook` is `failurePolicy: Ignore` and was
   unavailable when the pod was created, so it started credential-less and ran 109 days
   reporting healthy. Same mechanism as [[irsa-webhook-fails-open-at-pod-creation]], now twice.
   Fix: `rollout restart` — but **only after proving the webhook has a ready pod and endpoints**,
   or the restart silently reproduces it.
2. **A stale ACME Order is a dead URL.** LE expires orders after ~a week; cert-manager kept
   polling 56-day-old orders and got `404 … No order for ID`. It never opened a new one,
   because one looked in flight. The stuck Orders and CertificateRequests must be **deleted**.
3. **A one-hour backoff after a failed issuance.** Clear it without touching any Secret:
   `kubectl -n <ns> patch certificate <name> --subresource=status --type=merge -p '{"status":{"lastFailureTime":null,"failedIssuanceAttempts":null}}'`
   Orders appeared in seconds and were valid in three minutes. `status.failedIssuanceAttempts` and
   `status.lastFailureTime` govern it, and the timer is armed by the *old* failure — so a
   correctly-fixed cluster still shows zero Orders and expired certs for an hour.

**How to apply:** fixing the cause is step one of three. Before concluding a fix failed, read
`failedIssuanceAttempts` and `lastFailureTime`. An empty `get orders` is the same output for
"none in flight", "waiting out a timer", "never attempted" and "finished" — see
[[adjacent-step-green-signals]].

## Nothing alerts on any of this

Two expiries found the same day with nothing watching either: these six certificates and the
RisingWave licence (expires 2026-11-01). One rule — `notAfter` under 14 days on any Certificate,
all three clusters — catches both classes. Related: [[onprem-alerts-not-delivered]].

Separate defect on dev: `io-curt-io-notifications-handler` (istio-system) references a
ClusterIssuer named `letsencrypt` that does not exist, and has **never** been issued.

Full write-up: `wip/onprem-certs/FINDINGS-2026-10-06-dev-certs-expired.md`.
