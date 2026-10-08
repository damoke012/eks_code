# `risingwave-etl` — the applier as a chart

Renders exactly the object set the kustomize overlay rendered: the sync-hook
Job, the endpoints ConfigMap, the tracked `etl-pipeline-image` ConfigMap, and
the ExternalSecret. Validated with `helm template` on 2026-10-08: four objects,
same names as the overlay, four guards proven to refuse a bad values file.

Sourced by Argo CD from a **git path**, so it needs no OCI registry credential.

## Why not `dx-cron`

Measured against `variant-inc/helm-charts` on 2026-10-08:

| | |
|---|---|
| `cronJob.schedule` is required and it renders a **CronJob** | cannot carry `argocd.argoproj.io/hook: Sync`; a deploy would not apply the SQL |
| `library.external-secret.tpl` builds its ExternalSecret only from `awsSecrets`, via `dataFrom: extract` | `extract` emits each property under its OWN name, so `op-usxpress-dev/risingwave/root` yields a key called `password`, not `RW_PASSWORD`. No per-key mapping exists except a hardcoded `postgres-secret-*` branch reading `{{ $cluster }}-rds-creds` |
| `global.cluster_name` enumerates cloud clusters only | no `op-usxpress-*` value exists |
| `library` comes from `oci://064859874041.dkr.ecr.us-east-2.amazonaws.com/helm-charts` | the cluster has no Helm-level ECR auth, and ECR tokens expire every 12h with no refresher for an Argo repository secret |

Making `dx-cron` usable means editing `charts/library/templates/secrets/_external-secret.tpl`
— the template `dx-api`, `dx-cron`, `dx-handler` and `dx-ui` all render. That is
a deliberate change with its own review, not a prerequisite for wiring dev.

## What it fixes relative to the overlay

- **The ExternalSecret is keyed by name, not list position.** The overlay used
  `/spec/data/0/remoteRef/key`; prod's overlay patched indices 0 and 1 but not
  2, so `PG_USER` kept `PLACEHOLDER`, the ExternalSecret could never sync, and
  the Job could never start. A missing key here is a missing *name*, which
  fails loudly.
- **`/tmp` is an emptyDir whenever `readOnlyRootFilesystem` is true.** Its
  absence broke every `mktemp` and the QA applier applied nothing for weeks.
- **Four render-time guards**: `environment`, `image.digest`, a non-empty
  `config`, and no-values-at-all all refuse rather than deploying something
  half-configured.

## It does not change

The Job's spec, the image, the env sources, or the trigger. A promotion is
still a digest bump in a values file, and the `etl-pipeline-image` ConfigMap is
still what makes the sync hook fire.

## Flipping an environment onto it

One line in the ApplicationSet element: replace `path: deploy/overlays/<env>`
with `path: deploy/chart` plus `helm.valueFiles: [../values-<env>.yaml]`.
Before flipping, diff the rendered objects against the live ones — the point is
a change of mechanism with no change of behaviour.
