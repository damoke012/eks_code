Grafana on `op-usxpress-qa` has been running healthily for 72 days — `3/3 Running`,
0 restarts, PVC bound. But its HelmRelease has been `Stalled / RetriesExceeded` since
**14 July**, so Flux cannot deliver any change to it. Nothing committed under
`infrastructure/grafana/` has reached the cluster in over two months, and nothing reports
that.

This PR is about restoring Flux's ability to manage Grafana. Grafana itself is not down.

## What went wrong

**1. No `timeout`, so Helm used the 5-minute default.**

```
Last Attempted Release Action Duration: 5m0.528513048s
Message: Helm install failed ... context deadline exceeded
```

Exactly five minutes. The install did not error — it ran out of time waiting for readiness
on a first install that had to provision a ceph-block PVC and pull images. The pod became
ready shortly afterwards, which is why Grafana works while Helm believes the install failed.

**2. `install.remediation` had no `remediateLastFailure`.**

It defaults to `false` for installs (and `true` for upgrades — that asymmetry is the bug).
So all four attempts tried to *upgrade* a release whose only version was a failed install,
which Helm refuses. Retries were exhausted against an error they could never clear, and the
release stalled.

**3. `version: "8.x"` is a floating range.**

Harmless while nothing reconciles, but this change triggers a fresh chart resolve. Pinning
to `8.15.0` — the version currently running — makes the reinstall a like-for-like restore
instead of an unplanned upgrade landing at the same time as the fix.

## Changes

| Change | Why |
|---|---|
| `spec.timeout: 15m` | first install needs more than 5 minutes on this storage class |
| `install.remediation.remediateLastFailure: true` | clears the failed release so the retry is an install, not a doomed upgrade |
| `version: "8.15.0"` | pin to what is running; no surprise upgrade during the repair |

Committing this also bumps `metadata.generation`, which is what clears `Stalled` — Flux
gives up per generation, so the spec change is what restarts it. No manual `flux` command
is needed.

## On merge

Flux uninstalls the failed release and installs again. **Grafana restarts** — roughly a
minute or two of downtime on QA.

`pvc/grafana` has been annotated `helm.sh/resource-policy=keep` so the volume survives the
uninstall. Dashboards arrive from ConfigMaps and are unaffected either way; this preserves
saved UI preferences and alert state.

> That annotation is a live edit and is not in Git. The durable form is
> `persistence.existingClaim: grafana` in the `grafana-values` ConfigMap — a separate
> change, after this one proves out.

## Scope

`op-qa` only. The platform repo uses per-environment branches, so dev and prod cannot be
affected by this commit. `op-dev` carries the same 5-minute default and the same missing
`remediateLastFailure`; its install happened to finish in time. Worth the same patch there
before its next rebuild finds out.

## Verifying

Check the Helm history, not the Ready condition — a `Ready` HelmRelease with a `failed`
history entry is exactly how this hid for 72 days.

```
kubectl --context admin@op-usxpress-qa get helmrelease grafana -n grafana \
  -o jsonpath='{.status.history[0].status}{"\n"}'
```

Want: `deployed`.

If the reinstall fails with `invalid ownership metadata`, that is the kept PVC — Helm adopts
it only when its `meta.helm.sh/release-name` and `release-namespace` annotations still match.
Check those before concluding the timeout was still too short.
