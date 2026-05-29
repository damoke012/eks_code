#!/usr/bin/env python3
"""
Idempotent patch for DX__SetupVariables ScriptModule in OnPremise space.

Replaces the SSM kubeconfig block in SetAWSCredentials with a skip message.
The actual SSM kubeconfig logic lives in the DX-Apply inline script instead,
because the module runs under the "deployment" profile (cross-account role)
which doesn't have access to on-prem SSM parameters.

Usage:
    OCTOPUS_API_KEY=API-... ./patch-setup-variables.py [--dry-run]

Cloud-safety: Only modifies Spaces-302 (OnPremise). USXpress space untouched.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

OCTO = "https://octopus.usxpress.io"
DST_SPACE = "Spaces-302"
LVS_NAME = "DX__SetupVariables"


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
        sys.exit(f"HTTP {e.code} on {method} {path}: {err}")


def main():
    ap = argparse.ArgumentParser(description="Patch DX__SetupVariables for on-prem")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    key = os.environ.get("OCTOPUS_API_KEY")
    if not key:
        sys.exit("OCTOPUS_API_KEY not set")

    # Find DX__SetupVariables library variable set
    lvs_list = api("GET", f"/api/{DST_SPACE}/libraryvariablesets?take=200", key=key)
    lvs = None
    for item in lvs_list.get("Items", []):
        if item["Name"] == LVS_NAME:
            lvs = item
            break
    if not lvs:
        sys.exit(f"{LVS_NAME} not found in {DST_SPACE}")

    vsid = lvs["VariableSetId"]
    vs = api("GET", f"/api/{DST_SPACE}/variables/{vsid}", key=key)

    # Find the script module variable
    script_var = None
    for v in vs["Variables"]:
        if v["Name"] == f"Octopus.Script.Module[{LVS_NAME}]":
            script_var = v
            break
    if not script_var:
        sys.exit(f"Script module variable not found in {LVS_NAME}")

    script = script_var["Value"]
    NL = "\r\n" if "\r\n" in script else "\n"

    # Check if already patched
    if "Kubeconfig deferred to DX-Apply" in script:
        print("ALREADY PATCHED: DX__SetupVariables SSM block already simplified")
        return

    # Find the SSM kubeconfig block
    # Pattern: if ($useEksApi -eq "false") { ...aws ssm get-parameter... }
    pattern = r'if \(\$useEksApi -eq "false"\)\s*\{[^}]*aws ssm get-parameter[^}]*Write-Host "Kubeconfig written to \$env:KUBECONFIG"[^}]*\}'
    match = re.search(pattern, script, re.DOTALL)

    if not match:
        # Try simpler detection
        if "aws ssm get-parameter" in script and 'useEksApi -eq "false"' in script:
            # Find the block boundaries
            start_marker = 'if ($useEksApi -eq "false")'
            start_idx = script.index(start_marker)
            # Find the closing brace by counting braces
            depth = 0
            end_idx = start_idx
            for i in range(start_idx, len(script)):
                if script[i] == '{':
                    depth += 1
                elif script[i] == '}':
                    depth -= 1
                    if depth == 0:
                        end_idx = i + 1
                        break
            old_block = script[start_idx:end_idx]
        else:
            print("No SSM kubeconfig block found — module may already be clean")
            return
    else:
        old_block = match.group()

    new_block = NL.join([
        'if ($useEksApi -eq "false")',
        '    {',
        '      # On-prem: kubeconfig is built by the DX-Apply inline script using IRSA natively.',
        '      # Skipping SSM reads here to avoid credential conflicts with the deployment profile.',
        '      Write-Host "On-prem mode (TF_VAR_use_eks_api=false). Kubeconfig deferred to DX-Apply."',
        '    }',
    ])

    print(f"Found SSM block ({len(old_block)} chars)")
    if args.dry_run:
        print("DRY-RUN: would replace SSM block with skip message")
        return

    script_var["Value"] = script.replace(old_block, new_block)
    api("PUT", f"/api/{DST_SPACE}/variables/{vsid}", body=vs, key=key)
    print("PATCHED: DX__SetupVariables SSM block simplified")


if __name__ == "__main__":
    main()
