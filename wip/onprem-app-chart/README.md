# `usxpress-app` — one chart for every on-prem workload

**Status: drafted 2026-10-06, renders and lints clean, not yet landed in a repo.**

One Helm chart that renders the whole object matrix an application needs on the
on-prem Talos clusters, from a single values file — and refuses to render the
mistakes that have actually cost us outages.

**The values file is the intake form.** If an app team can fill it in, the app
can be deployed. If they cannot answer a required field, that gap is the
onboarding conversation, surfaced before anything is provisioned rather than
three weeks later.

## Why a chart and not more Kustomize

The app templates we have today (`wip/onprem-app-cicd/app-template/`) are
Kustomize: `deploy/base` plus `deploy/overlays/{qa,prod}`, in two fixed shapes,
`job/` and `service/`.

That works for exactly those two shapes. The moment an app needs an HPA but not
a PDB, or a PVC but not an ingress, or a CronJob with a ServiceMonitor, each
combination needs its own base. The matrix is combinatorial and we are already
at the point where it bites — seven object types have no template at all.

Helm's conditionals collapse that into one artefact, and `fail` lets the chart
reject a bad values file at render time instead of at admission, three layers
away from whoever wrote it.

## What it renders

| Object | Rendered when |
|---|---|
| Deployment / StatefulSet / Job / CronJob | `workload.kind` |
| Service | `service.enabled` |
| ServiceAccount (+ IRSA annotation) | `serviceAccount.create` |
| ConfigMap | `config` is non-empty |
| ExternalSecret | `externalSecrets.enabled` |
| PersistentVolumeClaim | `persistence.enabled` (StatefulSet uses a volumeClaimTemplate) |
| HorizontalPodAutoscaler | `autoscaling.enabled` |
| PodDisruptionBudget | `podDisruptionBudget.enabled` |
| VirtualService + Certificate | `expose.enabled` |
| CiliumNetworkPolicy | `networkPolicy.enabled` |
| ServiceMonitor + PrometheusRule | `monitoring.*.enabled` |

That covers every gap in the matrix, and folds in `platform-app-expose`
(INFRA-1527) — the VirtualService/Certificate/CNP chart written in June and
still sitting in `wip/`, which exists because we had solved that problem three
times by hand.

## What it refuses to render

Each of these is a failure we have actually had. The chart fails the render and
says why, rather than producing something that applies cleanly and is wrong.

| Guard | The failure it prevents |
|---|---|
| `image.digest` must be `sha256:` | 515 of 517 ECR repositories accept org-wide push; a tag can be moved under you |
| `clusterName` must be one of the three real clusters | `dpl`, `dpl2`, `jbtest` are decommissioned (INFRA-1686) and still appear in old guides |
| `owner.team` required | whoever owns the repo owns the pager; no owner, no onboarding |
| RWO volume + >1 Deployment replica | the second pod never schedules, and the first looks fine |
| `defaultDeny` with no egress rules | blocks DNS; every outbound call hangs and it reads like a dead dependency |
| `expose.enabled` without a Service | a VirtualService routing to nothing |
| `roleArn` without `serviceAccount.create` | the IRSA annotation lands on no object |
| `autoscaling` on a non-Deployment | an HPA with no scale target |

## What it encodes without being asked

- **`external-dns` owner-id is derived from `clusterName`.** A copied
  VirtualService with the wrong owner-id silently never registers DNS. It
  cannot be copied wrong here.
- **`/tmp` emptyDir** whenever `readOnlyRootFilesystem` is set. A QA ETL job
  could not apply a single file for weeks because every `mktemp` failed.
- **`rollingUpdate: null`** when strategy is `Recreate`. Server-side apply
  cannot put `Recreate` over a live `rollingUpdate` block; Flux's dry run fails
  and the *whole* Kustomization stops for everything in that directory.
- **ConfigMap checksum annotation**, so a config change rolls the pods. Without
  it the new value is applied and never read — the running image keeps what it
  started with.
- **`release: prometheus-stack`** on monitors. Prometheus only adopts monitors
  carrying its own release label; without it the monitor applies and is never
  scraped.
- **Job as an Argo sync hook with `BeforeHookCreation`.** A Job's pod template
  is immutable — without the delete policy, changing the image fails the apply
  with `field is immutable`.
- **`topologySpreadConstraints` on `kubernetes.io/hostname`**, not zone. One
  data centre; a zone constraint is satisfied trivially and buys nothing.
- **`helm.sh/resource-policy: keep`** on PVCs. `ceph-block` reclaims `Delete`,
  so an uninstall otherwise takes the data.

## What it does NOT cover, deliberately

- **Namespace, quota, PSA labels, ambient mesh label.** Platform-owned, created
  in `iaac-talos-flux-platform/infrastructure/app-namespaces/`. An app does not
  create its own namespace.
- **AWS resources.** Terraform in the app's own `iaac-<app>-onprem` repo,
  applied through Octopus. The chart consumes the role ARN; it does not make it.
- **The HelmRelease that installs this chart.** That lives in the platform or
  cluster repo and MUST carry `spec.timeout: 15m` and
  `install.remediation.remediateLastFailure: true` — those two defaults in
  series left QA's Grafana stalled for 66 days while the pod ran 3/3.

## RisingWave

The chart replaces **two** of RisingWave's three pieces:

| Piece | Today | With the chart |
|---|---|---|
| RisingWave operator | its own HelmRelease | unchanged — upstream chart |
| RisingWave **instance** (the CR) | raw YAML patched by a `postRenderer` in a *different* repo, with index-based patches (`nodeGroups/0`, `env/-`) that retarget silently | still the operator's CR, but the postRenderer patches become values, so machine sizes and the operator version stop living in another repository |
| The **SQL pipeline applier** | `app-template/job/` Kustomize | `examples/risingwave-pipeline-qa.yaml` |

The instance half is the valuable one: today RisingWave's compute sizing and
operator version are set by an index-based Kustomize patch in
`iaac-talos-flux-cluster`, so reviewing a RisingWave PR means reading a second
repo, and a list reorder retargets the patch with no error.

## Try it

```bash
helm template orders-api charts/usxpress-app -f examples/service-qa.yaml -n app-orders
helm template etl        charts/usxpress-app -f examples/cronjob-prod.yaml -n app-data
helm template rw-pipeline charts/usxpress-app -f examples/risingwave-pipeline-qa.yaml -n app-risingwave
```

And watch a guard fire:

```bash
helm template x charts/usxpress-app -f examples/service-qa.yaml --set image.digest=v1.2.3
```

## Before this lands

1. **Argo CD's ApplicationSet generates on `deploy/overlays/<env>` paths.** A
   Helm source is a different `source` shape. One-time change, better done
   before app #2 than after.
2. **Confirm whether `platform-app-expose` ever landed** in
   `iaac-talos-flux-platform`. If it did, this chart supersedes it and the old
   one is removed in the same PR, not left beside it.
3. **Add `values.schema.json`** so required fields fail in CI as well as at
   render.
4. **Prove it on QA2 first**, then dev, then QA, then prod — one environment at
   a time. Nothing about this chart is proven until a real workload runs from it.

## Proven

- Renders and lints clean on helm v4.2.2 for all three example values files.
- Every guard fires with its intended message (exercised 2026-10-06).

## Tested and killed

- **"Extend the Kustomize templates instead."** Each optional object doubles
  the base count; seven missing object types makes that untenable.

## Traps

- A rendered manifest is not a deployed one, and a deployed one is not a
  working one. The chart removes a class of authoring mistakes; it does not
  make a HelmRelease succeed, and `Ready` on that HelmRelease still does not
  mean the Helm history says `deployed`.
- `monitoring.prometheusRule` renders rules that **reach nobody** until
  INFRA-1698 lands an Alertmanager. Do not tell an app team their alerts are
  live because the rule rendered.
