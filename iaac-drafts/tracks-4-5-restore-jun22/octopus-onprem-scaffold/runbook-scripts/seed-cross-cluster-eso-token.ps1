# Seed Cross-Cluster ESO Token — runbook script body
#
# Inputs (from Octopus environment variables / project variables):
#   $SourceKubeconfigSecretArn       AWS SM ARN of source cluster kubeconfig
#   $SourceReaderSaNamespace         e.g., "external-secrets"
#   $SourceReaderSaName              e.g., "cloud-eks-reader"
#   $TargetKubeconfigPath            path to target kubeconfig file (on-prem)
#
# Outputs:
#   Secret 'cloud-eks-reader-token' created/updated in target cluster's
#   external-secrets namespace with keys: token, ca

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "=== Seed Cross-Cluster ESO Token ==="
Write-Host "Source SA: $SourceReaderSaNamespace/$SourceReaderSaName"
Write-Host "Target: $TargetKubeconfigPath"

# 1. Fetch source kubeconfig from AWS SM
Write-Host ""
Write-Host "Step 1: pulling source kubeconfig from AWS SM..."
$sourceKubeconfig = aws secretsmanager get-secret-value `
  --secret-id $SourceKubeconfigSecretArn `
  --query SecretString --output text
$sourceKubeconfigPath = New-TemporaryFile
$sourceKubeconfig | Out-File -FilePath $sourceKubeconfigPath -Encoding utf8
Write-Host "Wrote source kubeconfig to $sourceKubeconfigPath"

# 2. Read reader SA token from source cluster
Write-Host ""
Write-Host "Step 2: reading reader SA token from source cluster..."
$token = kubectl --kubeconfig $sourceKubeconfigPath `
  -n $SourceReaderSaNamespace `
  create token $SourceReaderSaName --duration=87600h
if ([string]::IsNullOrWhiteSpace($token)) {
  throw "Failed to obtain reader SA token from source cluster"
}
Write-Host "Token obtained (length: $($token.Length))"

# 3. Read source cluster CA cert
Write-Host ""
Write-Host "Step 3: extracting source cluster CA cert from kubeconfig..."
$caData = kubectl --kubeconfig $sourceKubeconfigPath config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'
if ([string]::IsNullOrWhiteSpace($caData)) {
  throw "Failed to extract CA cert from source kubeconfig"
}
$caPem = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($caData))
Write-Host "CA cert extracted (length: $($caPem.Length))"

# 4. Apply Secret to target cluster
Write-Host ""
Write-Host "Step 4: applying Secret to target cluster..."
$secretYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: cloud-eks-reader-token
  namespace: external-secrets
  labels:
    app.kubernetes.io/managed-by: octopus-onprem-bootstrap
    app.kubernetes.io/part-of: cross-cluster-eso
  annotations:
    seeded-by: onprem-platform-bootstrap/Seed-Cross-Cluster-ESO-Token
    seeded-at: "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)"
type: Opaque
stringData:
  token: |
$($token -split "`n" | ForEach-Object { "    $_" } | Out-String)
  ca: |
$($caPem -split "`n" | ForEach-Object { "    $_" } | Out-String)
"@

$secretYamlPath = New-TemporaryFile
$secretYaml | Out-File -FilePath $secretYamlPath -Encoding utf8
kubectl --kubeconfig $TargetKubeconfigPath apply -f $secretYamlPath

# 5. Trigger a CSS refresh + wait for Ready
Write-Host ""
Write-Host "Step 5: triggering ClusterSecretStore refresh + waiting for Ready..."
kubectl --kubeconfig $TargetKubeconfigPath `
  annotate clustersecretstore cloud-eks `
  external-secrets.io/force-refresh=$(Get-Date -Format 's') --overwrite

$timeout = 120
for ($i = 0; $i -lt $timeout / 5; $i++) {
  $status = kubectl --kubeconfig $TargetKubeconfigPath `
    get clustersecretstore cloud-eks -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  Write-Host "Attempt $($i+1): Ready=$status"
  if ($status -eq "True") {
    Write-Host "cloud-eks ClusterSecretStore is Ready"
    break
  }
  Start-Sleep -Seconds 5
}

if ($status -ne "True") {
  throw "cloud-eks CSS did not reach Ready within $timeout seconds. Check ESO operator logs."
}

# 6. Cleanup
Remove-Item -Path $sourceKubeconfigPath -Force -ErrorAction SilentlyContinue
Remove-Item -Path $secretYamlPath -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Cross-cluster ESO token seeded successfully ==="
