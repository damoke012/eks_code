# Phase-1 blocker — SSM validation fails a healthy cluster

**Found 2026-07-28, before the first prod apply. Blocks phase 1 outright.**

## What happens

`deploy/deploy.ps1`, inside `if ($TfApply -eq "true")`, runs a post-apply block that
asserts three SSM parameters exist and are non-empty, and `exit 1`s if any is missing:

```
/clusters/<cluster>/endpoint
/clusters/<cluster>/certificate_authority
/clusters/<cluster>/oidc_issuer
```

In `deploy/terraform/main.tf`, **all four** `aws_ssm_parameter` resources are gated:

| line | resource | gate |
|---|---|---|
| 263 | `cluster_endpoint` | `count = var.enable_irsa ? 1 : 0` |
| 278 | `cluster_certificate_authority` | `count = var.enable_irsa ? 1 : 0` |
| 293 | `cluster_oidc_issuer` | `count = var.enable_irsa ? 1 : 0` |
| 356 | `cluster_token` | `count = var.enable_irsa ? 1 : 0` |

Phase 1 runs `enable_irsa=false`. So none of the parameters are created, and the
validation fails on the FIRST one — `endpoint`, before `oidc_issuer` is even reached.

**Sequence:** terraform apply succeeds → cluster builds correctly → SSM-validate
fails → Octopus marks the deployment FAILED. The cluster is fine; the deploy is red.
This is the inverse of the INFRA-1623 trap: not a green deploy that did nothing, but
a red deploy that did everything.

## Why it was never hit

`envs/dev.tfvars` and `envs/qa.tfvars` both set `enable_irsa = true`. Prod phase 1 is
the first cluster ever to run this path with IRSA off — the teardown→rebuild path
failing exactly where the runbook said to expect it.

## It will NOT show up in the plan-only run

The whole block lives inside `if ($TfApply -eq "true")`. The plan-only prod deploy
passes clean. This bites the moment TfApply is armed, mid-provision on a fresh cluster
— the messiest state to recover from.

## Fix — gate the validation on the same variable

The validation exists to protect MageRunner's eks-data fallback, which reads SSM when
`use_eks_api=false`. A cluster with no IRSA publishes no SSM parameters and has no
MageRunner integration, so there is no contract to assert. Gating it is correct, not
a workaround.

In `deploy/deploy.ps1`, wrap the block that begins:

```powershell
Write-Host "`n[STEP] Post-apply: Validating SSM parameters for eks-data fallback"
```

...through the closing:

```powershell
Write-Host "[SSM-VALIDATE] All 3 SSM parameters validated successfully"
```

with:

```powershell
if ($env:TF_VAR_enable_irsa -eq "true") {
    # ... existing block unchanged ...
}
else {
    Write-Host "[SSM-VALIDATE] SKIPPED - enable_irsa=false, so no aws_ssm_parameter"
    Write-Host "[SSM-VALIDATE] resources are created (main.tf:263/278/293/356 are all"
    Write-Host "[SSM-VALIDATE] count-gated). Nothing to validate on a phase-1 cluster."
}
```

Lands on `refactor/multi-env-parameterization` — the branch prod deploys from. It is a
no-op for dev and QA, which both set `enable_irsa = true`.

## Second issue in the same block

`$irsaRoleArn = $env:TF_VAR_irsa_role_arn` is not among prod's 29 Octopus variables,
and `--diff-qa` was clean, so QA does not scope it either (`qa.tfvars:85` sets
`irsa_role_arn = ""`). With it empty no assume-role happens and the `aws ssm
get-parameter` calls run as the Octopus worker's own identity. The block's comment says
*"SSM params live in the USX-Dev account"*. When prod eventually runs with IRSA on,
confirm the worker can read SSM in `937464026810` — otherwise the same `exit 1` returns
in phase 2, for a different reason.

## Knock-on: the cloud IRSA ask may be smaller than assumed

`modules/irsa/main.tf` CREATES its own OIDC infrastructure — `aws_s3_bucket.oidc`,
the CloudFront distribution, and `aws_iam_openid_connect_provider`. The bucket is not
a pre-existing input. So the remaining external dependency may be only whether the
Octopus worker can authenticate into the prod account, not a cloud-built OIDC provider.
**Verify before sending CLOUD-IRSA-ASK.md** — the ask may be one line instead of a
project. See [CLOUD-IRSA-ASK.md](CLOUD-IRSA-ASK.md).
