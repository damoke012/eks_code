# PR plan — certificate-health alerts into IaC

Repo `variant-inc/iaac-talos-flux-platform`. **One PR per environment branch**, in the order
`op-dev` → `op-qa` → `op-prod`. Zero-risk: alerting rules only, no behaviour a pod or a
reconcile would notice.

## Files

| File | Action |
|---|---|
| `infrastructure/prometheus/certificate-health.yaml` | NEW |
| `infrastructure/prometheus/kustomization.yaml` | add `- certificate-health.yaml` to `resources` |

⚠️ That directory **enumerates**. A file dropped in without the kustomization line applies to
nothing, reports no error, and the alert simply never exists.

## Gate before any of it — is cert-manager scraped?

Every rule here selects `certmanager_*`. If nothing scrapes cert-manager the rules are valid,
healthy, `inactive` and dead, which looks exactly like "no certificate is expiring". That is
the standing failure mode on these clusters — authoring has never been the problem, ingestion
has ([[onprem-alerts-not-delivered]]).

```bash
export KUBECONFIG=$HOME/.kube/op-usxpress-dev-fresh.yaml     # op-usxpress-dev
kubectl get servicemonitors.monitoring.coreos.com -A | grep -i cert
kubectl -n cert-manager get svc -o custom-columns='NAME:.metadata.name,PORTS:.spec.ports[*].port,LABELS:.metadata.labels'
```

* **A ServiceMonitor selecting cert-manager exists** → ship the rule file alone.
* **None** → the PR needs a ServiceMonitor too (cert-manager's metrics Service, port 9402,
  label `release: prometheus-stack` so Prometheus adopts it). Without it this PR delivers
  five alerts that can never fire.

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
