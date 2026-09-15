---
name: two-gha-roles-one-pipeline-repo
description: "risingwave-pipeline has TWO GHA OIDC roles per cluster split by secret path; secret.yaml must assume the poc one"
metadata:
  type: project
---

`variant-inc/risingwave-pipeline` has **two** GHA OIDC roles in every on-prem account, split
deliberately by Secrets Manager path so CI and Tim's credentials rotate independently:

- `gha-op-usxpress-<env>-risingwave-poc-secrets` -> `<cluster>/risingwave/*` (Tim's path),
  trust = `repo:variant-inc/risingwave-pipeline:environment:{dev,qa,prod}`
- `gha-op-usxpress-<env>-risingwave-pipeline-secrets` -> `<cluster>/risingwave-2/*`,
  which **exists only on dev** — see [[risingwave-onprem]]

**Why:** `.github/workflows/secret.yaml` reads `<cluster>/risingwave/root` and `…/kafka`, so it
must assume the **poc** role. On 2026-09-01 an INFRA-1675 refactor switched it to the pipeline
role; every run since dies at `Configure AWS via OIDC`, because QA has no `risingwave-2` path
and the pipeline role grants nothing it needs.

**How to apply:** when a `risingwave-pipeline` workflow gets an OIDC or AccessDenied failure,
check **which role it names** before touching any trust policy — widening the wrong role's
trust looks like progress and changes nothing. Both roles are Terraform-managed in
`iaac-talos` `deploy/terraform/modules/irsa/`, tagged `Project: irsa`, so fixes are a PR plus
an Octopus release, never `aws iam put-role-policy`.
Related: [[manifests-copied-across-branches]], [[onprem-deploy-via-octopus]].
