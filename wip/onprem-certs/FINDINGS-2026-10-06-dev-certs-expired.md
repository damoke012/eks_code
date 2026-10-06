# op-usxpress-dev has been serving expired TLS for six weeks

Measured 2026-10-06 with `wip/onprem-certs/check-cert-expiry.sh` across all three on-prem
clusters. **Dev only. QA and prod are healthy** — every order `valid`, `argocd.op-qa` and
`argocd.op-prod` both `http=200 verify=0`.

## What is expired on op-usxpress-dev

| Certificate | ns | Expired | Breaks |
|---|---|---|---|
| `wildcard-op-dev` | istio-ingress | **41d ago** (08-26) | `*.op-dev.usxpress.io` — Argo CD, Grafana, everything |
| `brands-op-dev` | istio-ingress | **40d ago** (08-26) | `brands.op-dev` |
| `rw2-sql-tls` | risingwave-2 | **37d ago** (08-30) | `rw2-sql.op-dev` |
| `risingwave-dashboard-usxpress-io` | istio-ingress | **28d ago** (09-08) | the console's URL |
| `risingwave-overview-usxpress-io` | istio-ingress | **28d ago** (09-08) | the dashboard's URL |
| `rw-sql-tls` | risingwave | **28d ago** (09-08) | `rw-sql.op-dev`, `rw-postgres.op-dev` |

Browser verdict, measured: `argocd`, `grafana`, `risingwave-dashboard`, `risingwave-overview`
on op-dev all return `verify=10` — `X509_V_ERR_CERT_HAS_EXPIRED`.

**All six report `Ready: True`.**

## Root cause

cert-manager on dev cannot get AWS credentials for the Route53 DNS-01 solver:

```
error instantiating route53 challenge solver: unable to assume role: operation error STS:
AssumeRole, get identity: get credentials: failed to refresh cached credentials,
no EC2 IMDS role found, operation error ec2imds: GetMetadata, request canceled
```

It is falling back to **EC2 instance metadata** — on bare-metal Talos, where there is none.
Six ACME orders have sat `pending` for 43–67 days.

### The likely mechanism, not yet confirmed

The dev cert-manager pod was created **2026-06-19 with 0 restarts**, and the oldest stuck
order is 67 days — i.e. renewals have failed since the first one came due. IRSA credentials
are injected by the `pod-identity-webhook` **at pod creation**, and that webhook is
`failurePolicy: Ignore` — if it was unavailable at 2026-06-19, the pod started with no AWS
identity and has run that way ever since, reporting healthy. That is exactly
[[irsa-webhook-fails-open-at-pod-creation]], which cost dev RisingWave 54 days of storage.

If so the remedy is a **rollout restart of cert-manager on dev** — no manifest change.
Discriminate before acting: a pod with IRSA carries `AWS_ROLE_ARN` and
`AWS_WEB_IDENTITY_TOKEN_FILE` in its env. Absent + SA annotated = webhook failed open.

## Why nothing caught it

`Ready: True` on a cert-manager Certificate means *a certificate was issued at some point*.
It does **not** flip when the stored certificate expires, and it does not flip when renewal
fails — the failure lands on a `CertificateRequest` and an `Order`, which nothing watches.
`.status.notAfter` is the only field that answers "will a browser trust this".

Three expiries found in one day, none of them alerting: the RisingWave licence (2026-11-01),
these six certificates, and nothing watching either. See [[adjacent-step-green-signals]].

## Also found, separate defects

- `io-curt-io-notifications-handler` (istio-system, dev): `Referenced "ClusterIssuer" not
  found: letsencrypt`. **Never issued** — no `notAfter` at all. Its request has been Pending
  since creation. A different fault from the six above; it names an issuer that does not exist.
- `pod-identity-webhook` on **prod** expires **2026-10-27** (20 days). It renews from an
  internal issuer, not ACME, so it is not affected by this — but if it ever did lapse, the
  webhook fails open and every pod created afterwards runs with no AWS credentials, silently.
  Worth an alert in its own right.
- `istiod` shows `expires in 0d` on all three clusters. That is by design — it renews from
  `istio-ca` (internal, 2036), not ACME, and it is not among the failing requests.

## Proven / killed / traps

**Proven.** Six certificates on op-dev are expired and serving; dev's cert-manager has no AWS
credentials; QA and prod renew correctly and serve trusted certs.

**Killed.** "The RisingWave hostnames need new certificates." They have certificates and
cert-manager has the right config — it cannot complete the challenge. Minting a seventh
certificate into this path would have produced a seventh expired one.

**Traps.**
1. `curl -k` proved the route and hid the only thing a user experiences. The 200 was real and
   meaningless. **`-k` is the flag that makes a TLS check agree with you.**
2. A cert-manager `Ready: True` is not a valid certificate. Check `.status.notAfter`.
3. The screenshot found this, not the command. A browser was the honest instrument and the
   terminal was the flattering one.
