# deploy.ps1 — Octopus runs this to apply the RisingWave Terraform.
#
# Goes in variant-inc/iaac-risingwave-onprem: deploy/deploy.ps1
# The Octopus deployment step already runs `deploy.ps1` from the packaged
# deploy/ directory — this file is what has been missing (the repo only had
# deploy.sh, which the step never calls).
#
# Deliberately a SLIM version of iaac-talos/deploy/deploy.ps1. That script's
# core Terraform flow is generic and copied here verbatim, but its pre-destroy
# cluster drain (flux uninstall, namespace force-finalize) and its post-apply
# SSM validation (/clusters/<name>/endpoint ...) are Talos-cluster specific.
# RisingWave provisions an S3 bucket, an IAM role, and SecretsManager secrets —
# no cluster, no SSM params — so those blocks are omitted. Copied verbatim they
# would FAIL every RisingWave apply on the post-apply SSM assertion.
#
# Variable model = platform standard (same as iaac-talos):
#   * every TF_VAR_* Octopus variable becomes an env var; Terraform auto-reads
#     them, so there is NO -var-file and NO committed tfvars.
#   * backend comes from S3_BUCKET / TF_STATE_KEY / AWS_DEFAULT_REGION.
#   * apply is gated on TfApply, destroy on TfDestroy.
# All of these are set as Octopus project variables (see setup-octopus-rw.py),
# QA-scoped. AWS auth is the Octopus worker's role — do NOT set aws_profile.

if ($PSEdition -eq "Core") {
  $PSStyle.OutputRendering = "PlainText"
}

$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"
$RootPath = Get-Location

Trap {
  Write-Error $_ -ErrorAction Continue
  Set-Location $RootPath
  exit 1
}

# Export every TF_* Octopus variable as an environment variable so Terraform
# picks up TF_VAR_* automatically. Identical to iaac-talos.
$OctopusParameters.GetEnumerator() `
| Where-Object { $_.Key -like "TF_*" } `
| ForEach-Object {
  $key = $_.Key
  $value = $_.Value
  try {
    [Environment]::SetEnvironmentVariable($key, $value)
  }
  catch {
    [Environment]::SetEnvironmentVariable($key, ($value | ConvertTo-Json))
  }
}

$env:S3_BUCKET          = $S3_BUCKET
$env:AWS_DEFAULT_REGION = $AWS_DEFAULT_REGION
$env:TfDestroy          = $TfDestroy
$env:TF_STATE_KEY       = $TF_STATE_KEY

Write-Host "`n[STEP] Running Terraform"

Set-Location terraform
tfswitch

ce terraform init -no-color `
  -backend-config="bucket=$S3_BUCKET" `
  -backend-config="key=$TF_STATE_KEY" `
  -backend-config="region=$AWS_DEFAULT_REGION" `
  -backend-config="encrypt=true"

if ($TfDestroy -eq "true") {
  ce terraform plan -destroy -out=tfplan -input=false -no-color
  ce terraform apply tfplan
}
else {
  ce terraform plan -out=tfplan -input=false -no-color

  if ($TfApply -eq "true") {
    ce terraform apply tfplan

    Write-Host "[STEP] Capturing Terraform outputs..."
    $terraformOutputs = ce terraform output -json | ConvertFrom-Json | ConvertTo-Yaml
    if (!(Test-Path "../../outputs")) {
      New-Item -ItemType Directory -Path "../../outputs"
    }
    $terraformOutputs | Out-File "../../outputs/terraform_outputs.yml" -Encoding utf8
    Write-Host "[STEP] Uploading outputs as Octopus artifact..."
    New-OctopusArtifact -Path "../../outputs/terraform_outputs.yml"
  }
  else {
    Write-Host "[STEP] TfApply != true — plan only, no apply."
  }
}

Set-Location $RootPath
Write-Host "`n[STEP] Done."
