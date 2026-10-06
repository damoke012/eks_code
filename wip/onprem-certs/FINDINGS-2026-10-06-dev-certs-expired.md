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

---

## Why the certificates did not reissue the moment credentials were fixed

Restoring IRSA was necessary and not sufficient. Two more things stood between the fix and a
working certificate, and neither is visible from `Ready`:

### 1. A 56-day-old ACME Order is a dead URL

```
order is in "errored" state: Failed to retrieve Order resource:
404 urn:ietf:params:acme:error:malformed: No order for ID 543768975661
```

Let's Encrypt expires orders after about a week. cert-manager had stored the order URL from
the first failed renewal in August and kept polling it, so every reconcile 404'd against an
object that no longer existed at the CA. **It never attempted a new order**, because from its
point of view one was already in flight. The stuck `Order` and `CertificateRequest` objects
had to be deleted for it to start over — restoring credentials alone would have changed
nothing, indefinitely.

### 2. cert-manager backs off for an hour after a failed issuance

```
Failed Issuance Attempts: 1
Last Failure Time:        2026-10-06T20:26:30Z
```

That failure was recorded *moments before* the stale objects were deleted, so the backoff
timer was armed by the old regime and governs the first attempt of the new one. Retry at
21:26:30 — a clean cluster still shows zero Orders and six expired certificates for an hour,
and that is **not** a sign the fix did not work.

**How to apply:** after fixing the cause of a cert-manager failure, read
`status.failedIssuanceAttempts` and `status.lastFailureTime` before concluding anything from
the absence of Orders. An empty `get orders` means "none in flight", which is the same output
for "waiting out a timer", "never attempted" and "finished". Three states, one view.

### Two wrong guesses worth recording

Before reading `describe`, the hypotheses offered were **Let's Encrypt rate limiting** and
**the Route53 role lacking zone permissions**. Both plausible, both wrong, and neither would
have been found by looking harder at the thing they blamed. The Certificate's own `message`
field named the real cause in one line.

### And a check that lied in the same way the system did

The watch loop written to confirm issuance was:

```bash
if ! kubectl get orders.acme.cert-manager.io -A --no-headers | grep -qv valid; then echo "ALL VALID"
```

`No resources found` goes to stderr, so the pipeline saw **empty input**, `grep -qv` matched
nothing, and the negation printed **ALL VALID** for zero orders. It reported success for the
absence of the thing it was counting — written minutes after documenting that exact failure
mode. **A check whose success condition is "nothing matched" must first assert that something
was there to match.**
