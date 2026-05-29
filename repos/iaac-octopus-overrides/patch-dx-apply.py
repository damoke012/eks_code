#!/usr/bin/env python3
"""
Idempotent patch for DX-Apply deployment process in OnPremise space.

Inserts the SSM kubeconfig block into the DX-Apply inline script for on-prem
deployments (TF_VAR_use_eks_api=false). This block:
  1. Reads cluster endpoint, CA, and token from SSM Parameter Store
  2. Writes a kubeconfig file for kubectl/helm/terraform
  3. Logs into ECR for Helm chart pulls

Usage:
    OCTOPUS_API_KEY=API-... ./patch-dx-apply.py --project brands-api [--dry-run]
    OCTOPUS_API_KEY=API-... ./patch-dx-apply.py --all [--dry-run]

Cloud-safety: Only modifies deployment processes in Spaces-302 (OnPremise).
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

OCTO = "https://octopus.usxpress.io"
DST_SPACE = "Spaces-302"

# The SSM kubeconfig block to insert before `chmod +x ./mage/mage`
SSM_KUBECONFIG_BLOCK = r'''# On-prem kubeconfig from SSM (if TF_VAR_use_eks_api=false)
$useEksApi = $OctopusParameters["TF_VAR_use_eks_api"]
Write-Host "TF_VAR_use_eks_api = [$useEksApi]"
if ($useEksApi -eq "false")
{
  # Temporarily disable native command error preference so aws cli errors
  # dont abort the script (the module import already failed on aws eks)
  $prevPref = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false

  $clusterName = $OctopusParameters["CLUSTER_NAME"]
  $clusterRegion = $OctopusParameters["CLUSTER_REGION"]
  Write-Host "Building kubeconfig from SSM for cluster=$clusterName region=$clusterRegion"

  # Clear stale AWS config from failed module import so IRSA env vars work
  Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
  # Keep AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE - the module set up valid IRSA credentials
  $env:AWS_DEFAULT_REGION = $clusterRegion
  $env:AWS_REGION = $clusterRegion
  Write-Host "Cleared stale AWS config, region=$clusterRegion, using IRSA natively"

  $ssmEndpoint = aws ssm get-parameter --name "/clusters/$clusterName/endpoint" --with-decryption --query "Parameter.Value" --output text --region $clusterRegion
  Write-Host "endpoint=$ssmEndpoint"
  $ssmCA = aws ssm get-parameter --name "/clusters/$clusterName/certificate_authority" --with-decryption --query "Parameter.Value" --output text --region $clusterRegion
  Write-Host "CA length=$($ssmCA.Length)"
  $ssmToken = aws ssm get-parameter --name "/clusters/$clusterName/token" --with-decryption --query "Parameter.Value" --output text --region $clusterRegion
  Write-Host "token length=$($ssmToken.Length)"

  $kubeconfigPath = Join-Path (Get-Location).Path ".kubeconfig"
  @"
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: $ssmEndpoint
    certificate-authority-data: $ssmCA
  name: cluster
contexts:
- context:
    cluster: cluster
    user: terraform-runner
  name: cluster
current-context: cluster
users:
- name: terraform-runner
  user:
    token: $ssmToken
"@ | Set-Content -Path $kubeconfigPath
  $env:KUBECONFIG = $kubeconfigPath
  New-Item -ItemType Directory -Path /root/.kube -Force -ErrorAction SilentlyContinue | Out-Null
  Copy-Item -Path $kubeconfigPath -Destination /root/.kube/config -Force -ErrorAction SilentlyContinue
  Write-Host "Kubeconfig written to $kubeconfigPath"

  # Also set up ECR helm login
  aws ecr get-login-password --region us-east-2 | helm registry login --username AWS --password-stdin 064859874041.dkr.ecr.us-east-2.amazonaws.com

  $PSNativeCommandUseErrorActionPreference = $prevPref
}

'''

INSERTION_MARKER = "chmod +x ./mage/mage"
IDEMPOTENCY_CHECK = "On-prem kubeconfig from SSM"


def api(method, path, body=None, key=None):
    req = urllib.request.Request(
        f"{OCTO}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        headers={"X-Octopus-ApiKey": key, "Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        err = e.read().decode()[:400]
        print(f"  HTTP {e.code} on {method} {path}: {err}", file=sys.stderr)
        return None


def find_project(name, key):
    d = api("GET", f"/api/{DST_SPACE}/projects?partialName={name}&take=10", key=key)
    if not d:
        return None
    for p in d.get("Items", []):
        if p["Name"] == name:
            return p
    return None


def patch_project(project_name, key, dry_run=False):
    print(f"\n{'='*50}")
    print(f"Patching DX-Apply for: {project_name}")

    proj = find_project(project_name, key)
    if not proj:
        print(f"  ERROR: project {project_name!r} not found in {DST_SPACE}")
        return False

    dp_id = f"deploymentprocess-{proj['Id']}"
    dp = api("GET", f"/api/{DST_SPACE}/deploymentprocesses/{dp_id}", key=key)
    if not dp:
        print(f"  ERROR: deployment process not found")
        return False

    for step in dp.get("Steps", []):
        for action in step.get("Actions", []):
            if action["Name"] != "DX-Apply":
                continue

            script = action["Properties"].get("Octopus.Action.Script.ScriptBody", "")

            if IDEMPOTENCY_CHECK in script:
                print("  ALREADY PATCHED: SSM kubeconfig block present")
                return True

            if INSERTION_MARKER not in script:
                print(f"  ERROR: insertion marker '{INSERTION_MARKER}' not found in script")
                return False

            new_script = script.replace(
                INSERTION_MARKER,
                SSM_KUBECONFIG_BLOCK + INSERTION_MARKER,
            )

            if dry_run:
                print("  DRY-RUN: would insert SSM kubeconfig block")
                return True

            action["Properties"]["Octopus.Action.Script.ScriptBody"] = new_script
            result = api("PUT", f"/api/{DST_SPACE}/deploymentprocesses/{dp_id}", body=dp, key=key)
            if result:
                print("  PATCHED: SSM kubeconfig block inserted")
                return True
            else:
                print("  ERROR: failed to save deployment process")
                return False

    print("  ERROR: DX-Apply action not found in deployment process")
    return False


def main():
    ap = argparse.ArgumentParser(description="Patch DX-Apply for on-prem SSM kubeconfig")
    ap.add_argument("--project", "-p", default="brands-api")
    ap.add_argument("--all", action="store_true",
                    help="Patch all module-coverage apps")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    key = os.environ.get("OCTOPUS_API_KEY")
    if not key:
        sys.exit("OCTOPUS_API_KEY not set")

    projects = [
        "brands-api",
        "geoenrichment-sync-handler",
        "attrition-api",
        "io-notifications-handler",
        "trailers-api",
        "safetylytx-video-api",
    ] if args.all else [args.project]

    ok = fail = 0
    for name in projects:
        if patch_project(name, key, args.dry_run):
            ok += 1
        else:
            fail += 1

    print(f"\nDone: {ok} ok, {fail} failed")
    if fail > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
