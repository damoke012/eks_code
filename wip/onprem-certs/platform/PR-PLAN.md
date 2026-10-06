# PR plan — certificate-health alerts into IaC

Repo `variant-inc/iaac-talos-flux-platform`. **One PR per environment branch**, in the order
`op-dev` → `op-qa` → `op-prod`. Zero-risk: alerting rules only, no behaviour a pod or a
reconcile would notice.

## Files

| File | Action |
|---|---|
| `infrastructure/prometheus/servicemonitor-cert-manager.yaml` | NEW — **without this the rules are dead** |
| `infrastructure/prometheus/certificate-health.yaml` | NEW |
| `infrastructure/prometheus/kustomization.yaml` | add BOTH filenames to `resources` |

⚠️ That directory **enumerates**. A file dropped in without the kustomization line applies to
nothing, reports no error, and the alert simply never exists.

## ✅ Gate answered 2026-10-06 — nothing scrapes cert-manager

Measured on op-usxpress-dev: **zero ServiceMonitors** select it, while the metrics Service has
been there all along (`cert-manager` in ns `cert-manager`, port **9402**, portName
`tcp-prometheus-servicemonitor`). So every `certmanager_*` series is absent and the five rules
would sit `inactive` forever — identical, from the outside, to a healthy fleet. That is the
standing failure mode on these clusters: authoring has never been the problem, ingestion has
([[onprem-alerts-not-delivered]]).

**The ServiceMonitor is therefore the load-bearing half of this PR.** Rules without it are
worse than no rules, because they look like coverage.

It is a standalone manifest, not `prometheus.servicemonitor.enabled: true` on the cert-manager
HelmRelease. The chart option is tidier, but it re-renders a working release of the component
we spent today recovering — and a cert-manager restart is precisely how the outage began. One
object, nothing restarts, `kubectl delete` to revert.

### One thing still to confirm before merge

Prometheus adopts a ServiceMonitor only if its own selector matches. Check what it requires:

```bash
kubectl -n prometheus get prometheus -o jsonpath='{range .items[*]}serviceMonitorSelector={.spec.serviceMonitorSelector}{"\n"}serviceMonitorNamespaceSelector={.spec.serviceMonitorNamespaceSelector}{"\n"}{end}'
```

Empty `{}` means it adopts everything. If it matches on `release: prometheus-stack`, the label
is already on the manifest. If it matches something else, change the label to match — this is
the single line that decides whether the whole PR does anything.

## Build it from the branch, not from here

`wip/` is a draft. Copy the file onto a branch cut from `op-dev` and read the whole diff
before pushing — a PR assembled by copying files wholesale carries every difference between
the two copies, which is how an ApplicationSet's repoURL was silently reverted in August.

```bash
cd ~/src && git clone -b op-dev <ghe>/variant-inc/iaac-talos-flux-platform ptf && cd ptf
git checkout -b infra-certs-alerts
cp ~/certificate-health.yaml infrastructure/prometheus/certificate-health.yaml
# add the resources line, then:
git diff origin/op-dev        # read ALL of it, including hunks you did not intend
```

## Verify after merge — not that it merged

`Ready` on the Kustomization proves the file applied, not that the rule can fire.

```bash
kubectl -n prometheus get prometheusrule certificate-health          # exists
kubectl -n cert-manager get servicemonitor cert-manager              # exists
# the target is actually UP -- Prometheus UI, Status -> Targets, look for cert-manager
# then, in the Prometheus UI: Status -> Rules -> certificates.health
#   every rule must be listed and EVALUATING. A rule over a metric that is not ingested
#   shows as inactive forever and is indistinguishable from "nothing is wrong".
```

The honest test: `certmanager_certificate_expiration_timestamp_seconds` must return series.
If it returns nothing, the scrape is missing and the PR achieved nothing.

## Promotion

`op-dev` first. Leave it a week — long enough to see whether `CertificateRenewalOverdue`
fires on anything real — then `op-qa`, then `op-prod`. QA carries an extra `prometheus-rules`
Kustomization dev lacks, so confirm which directory QA's rules actually live in before
assuming the dev path.
