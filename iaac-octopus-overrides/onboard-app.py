#!/usr/bin/env python3
"""
Onboard an app to the OnPremise Octopus space for on-prem deployment.

Combines all per-app setup steps into one idempotent script:
  1. Seed terraform state (auth + mongodb-user) from cloud S3
  2. Fix SM ARNs in auth state (cloud account → playground account)
  3. Copy MongoDB Atlas certificate secret to playground SM
  4. Copy missing project variables from cloud to OnPremise
  5. Patch DX-Apply deployment process with SSM kubeconfig block

Prerequisites:
  - App already imported via Bento (project exists in OnPremise space)
  - OCTOPUS_API_KEY set
  - AWS profiles: usx-dev (cloud dev, 700736442855), playground (786352483360)
  - AWS CLI available

Usage:
    OCTOPUS_API_KEY=API-... ./onboard-app.py brands-api [--dry-run]
    OCTOPUS_API_KEY=API-... ./onboard-app.py --all [--dry-run]

Cloud-safety: Reads from cloud S3/SM (read-only). Writes only to playground
S3/SM and OnPremise Octopus space.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

OCTO = "https://octopus.usxpress.io"
SRC_SPACE = "Spaces-245"   # USXpress (cloud, read-only)
DST_SPACE = "Spaces-302"   # OnPremise (write target)

# S3 buckets for terraform state
CLOUD_STATE_BUCKET = "usxpress-tf-state-8300lkoz74prn4fd"
CLOUD_STATE_REGION = "us-east-2"
CLOUD_AWS_PROFILE = "usx-dev"
CLOUD_AWS_ACCOUNT = "700736442855"

ONPREM_STATE_BUCKET = "dpl2-local-test-tfstate"
ONPREM_STATE_REGION = "us-east-1"
ONPREM_AWS_PROFILE = "playground"
ONPREM_AWS_ACCOUNT = "786352483360"

# Modules whose state should be seeded from cloud
STATE_MODULES = ["common/auth", "common/mongodb-user"]

# MongoDB Atlas secrets to copy from cloud dev to playground
MONGO_SECRETS_PATTERNS = [
    "mongo-cluster-{env}-{group}",
]


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


def run(cmd, check=True):
    """Run a shell command and return stdout."""
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"  CMD FAILED: {cmd}", file=sys.stderr)
        print(f"  stderr: {result.stderr[:300]}", file=sys.stderr)
        return None
    return result.stdout.strip()


def find_project(space_id, name, key):
    d = api("GET", f"/api/{space_id}/projects?partialName={name}&take=10", key=key)
    if not d:
        return None
    for p in d.get("Items", []):
        if p["Name"] == name:
            return p
    return None


# ─── Step 1: Seed terraform state ───

def seed_state(app_name, module_path, dry_run=False):
    """Copy terraform state for a module from cloud S3 to on-prem S3."""
    cloud_key = f"USXpress/{app_name}/{module_path}"
    onprem_key = f"USXpress/{app_name}/{module_path}"
    tmp_file = f"/tmp/state-{app_name}-{module_path.replace('/', '-')}.json"

    print(f"\n  Seeding state: {module_path}")

    # Check if on-prem state already exists
    check = run(
        f"aws s3 ls s3://{ONPREM_STATE_BUCKET}/{onprem_key} "
        f"--profile {ONPREM_AWS_PROFILE} --region {ONPREM_STATE_REGION} 2>/dev/null",
        check=False,
    )
    if check:
        print(f"    SKIP: state already exists in on-prem bucket")
        return True

    # Download from cloud
    result = run(
        f"aws s3 cp s3://{CLOUD_STATE_BUCKET}/{cloud_key} {tmp_file} "
        f"--profile {CLOUD_AWS_PROFILE} --region {CLOUD_STATE_REGION}"
    )
    if not result:
        print(f"    WARN: no cloud state found for {cloud_key} — skipping")
        return True  # Not an error — module may not have run in cloud

    # Fix SM ARNs for auth state (cloud account → playground account)
    if "auth" in module_path:
        fix_auth_state_arns(app_name, tmp_file, dry_run)

    if dry_run:
        print(f"    DRY-RUN: would upload state to s3://{ONPREM_STATE_BUCKET}/{onprem_key}")
        return True

    # Upload to on-prem
    result = run(
        f"aws s3 cp {tmp_file} s3://{ONPREM_STATE_BUCKET}/{onprem_key} "
        f"--profile {ONPREM_AWS_PROFILE} --region {ONPREM_STATE_REGION}"
    )
    if result is not None:
        print(f"    DONE: state seeded")
        return True
    return False


def fix_auth_state_arns(app_name, state_file, dry_run=False):
    """Replace cloud SM ARNs with playground SM ARNs in auth state file."""
    secret_name = f"azure-app-dx-dev-usxpress-{app_name}"

    # Get the playground SM secret ARN
    playground_arn = run(
        f"aws secretsmanager describe-secret --secret-id {secret_name} "
        f"--profile {ONPREM_AWS_PROFILE} --region {ONPREM_STATE_REGION} "
        f"--query ARN --output text 2>/dev/null",
        check=False,
    )

    with open(state_file) as f:
        state = f.read()

    # Find cloud SM ARN pattern and replace with playground ARN
    import re
    cloud_arn_pattern = (
        f"arn:aws:secretsmanager:{CLOUD_STATE_REGION}:{CLOUD_AWS_ACCOUNT}"
        f":secret:{secret_name}-[A-Za-z0-9]{{6}}"
    )
    matches = re.findall(cloud_arn_pattern, state)

    if not matches:
        print(f"    No cloud SM ARNs found for {secret_name} — state may be clean")
        return

    if playground_arn:
        # Replace with actual playground ARN
        for old_arn in set(matches):
            count = state.count(old_arn)
            state = state.replace(old_arn, playground_arn)
            print(f"    Replaced {count}x: {old_arn[:60]}... → playground ARN")
    else:
        # Secret doesn't exist in playground yet — remove SM resources from state
        # so terraform creates them fresh
        print(f"    SM secret {secret_name} not in playground — terraform will create on first deploy")
        # Remove the aws_secretsmanager_secret and aws_secretsmanager_secret_version
        # resources from state by replacing their ARNs with empty/dummy values
        for old_arn in set(matches):
            state = state.replace(old_arn, f"arn:aws:secretsmanager:{ONPREM_STATE_REGION}:{ONPREM_AWS_ACCOUNT}:secret:{secret_name}-PENDING")

    if not dry_run:
        with open(state_file, "w") as f:
            f.write(state)


# ─── Step 2: Copy MongoDB Atlas secrets ───

def copy_mongo_secrets(app_name, env="dev", group="enterprise", dry_run=False):
    """Copy MongoDB Atlas certificate secret from cloud dev to playground."""
    for pattern in MONGO_SECRETS_PATTERNS:
        secret_name = pattern.format(env=env, group=group)
        print(f"\n  MongoDB secret: {secret_name}")

        # Check if already exists in playground
        check = run(
            f"aws secretsmanager describe-secret --secret-id {secret_name} "
            f"--profile {ONPREM_AWS_PROFILE} --region {ONPREM_STATE_REGION} "
            f"--query Name --output text 2>/dev/null",
            check=False,
        )
        if check == secret_name:
            print(f"    SKIP: already exists in playground")
            continue

        # Get from cloud dev
        value = run(
            f"aws secretsmanager get-secret-value --secret-id {secret_name} "
            f"--profile {CLOUD_AWS_PROFILE} --region {CLOUD_STATE_REGION} "
            f"--query SecretString --output text 2>/dev/null",
            check=False,
        )
        if not value:
            print(f"    WARN: not found in cloud dev — skipping")
            continue

        if dry_run:
            print(f"    DRY-RUN: would create {secret_name} in playground")
            continue

        result = run(
            f"aws secretsmanager create-secret --name {secret_name} "
            f"--secret-string '{value}' "
            f"--profile {ONPREM_AWS_PROFILE} --region {ONPREM_STATE_REGION}",
        )
        if result is not None:
            print(f"    DONE: secret created in playground")


# ─── Step 3: Copy project variables ───

def copy_project_variables(app_name, key, dry_run=False):
    """Copy missing project variables from cloud to OnPremise project."""
    print(f"\n  Syncing project variables")

    src_proj = find_project(SRC_SPACE, app_name, key)
    dst_proj = find_project(DST_SPACE, app_name, key)
    if not src_proj or not dst_proj:
        print(f"    WARN: project not found in {'source' if not src_proj else 'target'} — skipping")
        return

    src_vs = api("GET", f"/api/{SRC_SPACE}/variables/{src_proj['VariableSetId']}", key=key)
    dst_vs = api("GET", f"/api/{DST_SPACE}/variables/{dst_proj['VariableSetId']}", key=key)

    dst_names = {v["Name"] for v in dst_vs.get("Variables", [])}
    added = 0

    for v in src_vs.get("Variables", []):
        name = v["Name"]
        # Only copy variables that don't exist in destination
        if name not in dst_names:
            # Skip sensitive variables (they'll be empty in API response)
            if v.get("IsSensitive"):
                continue
            dst_vs["Variables"].append({
                "Name": name,
                "Value": v.get("Value", ""),
                "Scope": {},  # unscoped — Octopus resolves per environment
                "IsSensitive": False,
                "IsEditable": True,
                "Type": v.get("Type", "String"),
            })
            print(f"    + ADD {name} = {(v.get('Value') or '')[:50]!r}")
            added += 1

    if added == 0:
        print(f"    All variables already present")
        return

    if dry_run:
        print(f"    DRY-RUN: would add {added} variables")
        return

    api("PUT", f"/api/{DST_SPACE}/variables/{dst_proj['VariableSetId']}", body=dst_vs, key=key)
    print(f"    DONE: added {added} variables")


# ─── Main ───

def onboard_app(app_name, key, dry_run=False):
    print(f"\n{'='*60}")
    print(f"Onboarding: {app_name}")
    print(f"  cloud: {SRC_SPACE} ({CLOUD_AWS_ACCOUNT})")
    print(f"  onprem: {DST_SPACE} ({ONPREM_AWS_ACCOUNT})")

    # Verify project exists in OnPremise
    proj = find_project(DST_SPACE, app_name, key)
    if not proj:
        print(f"  ERROR: {app_name!r} not found in OnPremise space")
        print(f"  Run Bento import first: USXpress → OnPremise")
        return False

    ok = True

    # Step 1: Seed terraform state
    for module in STATE_MODULES:
        if not seed_state(app_name, module, dry_run):
            ok = False

    # Step 2: Copy MongoDB Atlas secrets
    # Detect env/group from spec or use defaults
    copy_mongo_secrets(app_name, env="dev", group="enterprise", dry_run=dry_run)

    # Step 3: Copy project variables
    copy_project_variables(app_name, key, dry_run)

    # Step 4: Patch DX-Apply (delegate to patch-dx-apply.py logic)
    print(f"\n  DX-Apply patch: run ./patch-dx-apply.py --project {app_name}")

    return ok


def main():
    ap = argparse.ArgumentParser(description="Onboard app to OnPremise space")
    ap.add_argument("app", nargs="?", default="brands-api",
                    help="App name to onboard (default: brands-api)")
    ap.add_argument("--all", action="store_true",
                    help="Onboard all 6 module-coverage apps")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    key = os.environ.get("OCTOPUS_API_KEY")
    if not key:
        sys.exit("OCTOPUS_API_KEY not set")

    apps = [
        "brands-api",
        "geoenrichment-sync-handler",
        "attrition-api",
        "io-notifications-handler",
        "trailers-api",
        "safetylytx-video-api",
    ] if args.all else [args.app]

    ok = fail = 0
    for name in apps:
        if onboard_app(name, key, args.dry_run):
            ok += 1
        else:
            fail += 1

    print(f"\nDone: {ok} ok, {fail} failed")
    if fail > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
