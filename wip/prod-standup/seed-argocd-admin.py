#!/usr/bin/env python3
"""seed-argocd-admin.py — one-time seed of the Argo CD admin credential.

WHY THIS IS NOT A TERRAFORM RESOURCE
  Terraform creates and populates talosconfig and both grafana SM secrets.
  It does NOT touch op-usxpress-<env>/platform/argocd — that secret is only
  READ, by the argocd-admin-credentials ExternalSecret. Two consequences:

    * nothing seeds it, so without this script Argo CD comes up with a GREEN
      ExternalSecret and an unusable login (SecretSynced proves the sync ran,
      not that the value works)
    * `terraform destroy` never deletes it, so it SURVIVES teardown->rebuild.
      Run this once per cluster, not once per build. Hands-off rebuilds are
      unaffected.

FORMAT
  argocd-secret expects `admin.password` as a BCRYPT HASH, not plaintext, and
  `admin.passwordMtime` as an RFC3339 timestamp. The ExternalSecret pulls both
  as JSON properties of a single SM secret:

      { "admin.password": "$2b$...", "admin.passwordMtime": "2026-07-29T.." }

USAGE
    pip install bcrypt
    python3 seed-argocd-admin.py --cluster op-usxpress-prod            # dry-run
    python3 seed-argocd-admin.py --cluster op-usxpress-prod --apply
    python3 seed-argocd-admin.py --cluster op-usxpress-prod --apply --force

  --force rotates an existing secret. Without it the script refuses to
  overwrite, so re-running is safe.

  The generated password is printed ONCE. Store it in the team password
  manager immediately — only the bcrypt hash goes to AWS, so it cannot be
  recovered afterwards.
"""

import argparse
import datetime
import json
import secrets
import string
import subprocess
import sys

try:
    import bcrypt
except ImportError:
    sys.exit("ERROR: bcrypt missing. pip install bcrypt")

ap = argparse.ArgumentParser()
ap.add_argument("--cluster", required=True, help="e.g. op-usxpress-prod")
ap.add_argument("--profile", default="ops-controller", help="AWS CLI profile")
ap.add_argument("--region", default="us-east-2")
ap.add_argument("--apply", action="store_true")
ap.add_argument("--force", action="store_true", help="rotate an existing secret")
args = ap.parse_args()

SECRET_NAME = f"{args.cluster}/platform/argocd"


def aws(*a, check=True):
    r = subprocess.run(
        ["aws", *a, "--profile", args.profile, "--region", args.region],
        capture_output=True, text=True,
    )
    if check and r.returncode != 0:
        sys.exit(f"ERROR: aws {' '.join(a)}\n{r.stderr.strip()[:400]}")
    return r


print(f"secret : {SECRET_NAME}")
print(f"profile: {args.profile}  region: {args.region}")

probe = aws("secretsmanager", "describe-secret", "--secret-id", SECRET_NAME,
            "--query", "[ARN,DeletedDate]", "--output", "text", check=False)
exists = probe.returncode == 0
deleted = None
if exists:
    parts = probe.stdout.split()
    arn = parts[0]
    deleted = parts[1] if len(parts) > 1 and parts[1] != "None" else None
    print(f"status : EXISTS  {arn}")
    if deleted:
        print(f"         scheduled for deletion ({deleted}) — will restore")
    if not args.force:
        print("\nRefusing to overwrite an existing credential. Re-run with --force "
              "to rotate.\nIf Argo CD is already using it, rotating means every "
              "existing admin session breaks.")
        sys.exit(0)
else:
    print("status : ABSENT — will create")

# 28 chars, alphanumeric + safe punctuation. Avoids quoting hazards in shells
# and JSON while staying well past any sane brute-force threshold.
alphabet = string.ascii_letters + string.digits + "!@#%^*-_=+"
password = "".join(secrets.choice(alphabet) for _ in range(28))
hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
mtime = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()

payload = json.dumps({"admin.password": hashed, "admin.passwordMtime": mtime})

print("\nwould write JSON with properties:")
print(f"  admin.password     = {hashed[:20]}...  (bcrypt, {len(hashed)} chars)")
print(f"  admin.passwordMtime = {mtime}")

if not args.apply:
    sys.exit("\n[DRY-RUN] Nothing written. Re-run with --apply.")

if deleted:
    aws("secretsmanager", "restore-secret", "--secret-id", SECRET_NAME)
    print("restored from scheduled deletion")

if exists:
    aws("secretsmanager", "put-secret-value", "--secret-id", SECRET_NAME,
        "--secret-string", payload)
    print(f"\n✓ Rotated {SECRET_NAME}")
else:
    aws("secretsmanager", "create-secret", "--name", SECRET_NAME,
        "--description", "Argo CD admin credential (bcrypt). Read by ESO; not managed by Terraform.",
        "--secret-string", payload)
    print(f"\n✓ Created {SECRET_NAME}")

print("\n" + "=" * 68)
print("  ADMIN PASSWORD — shown once, store it in the password manager NOW")
print("=" * 68)
print(f"  {password}")
print("=" * 68)
print("\nOnly the bcrypt hash is stored in AWS; this plaintext cannot be recovered.")
print("Verify after Argo CD reconciles:")
print("  kubectl -n argocd get externalsecret argocd-admin-credentials")
print("  kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.admin\\.password}' | base64 -d | head -c 4")
print("  (expect it to start with $2 — a bcrypt hash, not a placeholder)")
