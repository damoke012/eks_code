#!/usr/bin/env python3
"""INFRA-1674 final step — wire RisingWave into op-usxpress-prod's infra.yaml.

Does two things and nothing else:

  1. Replaces the "deliberately absent" note in the header, which becomes false the
     moment this lands. That note is load-bearing — it is what stopped the 17-day
     "path not found" failure — so it is rewritten, not deleted.
  2. Appends the RisingWave block: the GitRepository, risingwave-operator,
     risingwave-onprem and risingwave-routes Kustomizations.

Flux orders by dependsOn, not file position, so appending is safe.

REFUSES unless the prerequisites actually exist, because wiring a path before its
secrets exist is exactly the failure the header warns about. Read-only without --write.
"""
import argparse
import pathlib
import subprocess
import sys

OLD_NOTE = """# RisingWave: deliberately absent — ./manifests/op-usxpress-prod does not exist
# in iaac-risingwave-onprem yet; wiring it = the 17-day "path not found" failure."""

NEW_NOTE = """# RisingWave: wired 2026-09-01 under INFRA-1674, once ./manifests/op-usxpress-prod
# existed in iaac-risingwave-onprem and the six Secrets Manager entries were in
# place. It was absent before that on purpose — wiring a path that does not exist
# is the 17-day "path not found" failure, and Flux reports it as a stuck
# Kustomization rather than an error anyone notices."""

SECRETS = ["postgres", "root", "svc-reporting", "secret_store_private_key",
           "console_license_key", "dex_entra_client_secret"]


def check_prereqs(profile: str) -> bool:
    ok = True
    print("  prerequisites in account 937464026810:")
    for s in SECRETS:
        path = f"op-usxpress-prod/risingwave/{s}"
        r = subprocess.run(
            ["aws", "secretsmanager", "describe-secret", "--secret-id", path,
             "--profile", profile, "--region", "us-east-2"],
            capture_output=True, text=True)
        if r.returncode == 0:
            print(f"      ok       {path}")
        elif "ResourceNotFoundException" in r.stderr:
            print(f"      MISSING  {path}")
            ok = False
        else:
            # Never read a transport failure as a finding about the secret.
            print(f"      UNKNOWN  {path} -- {r.stderr.strip().splitlines()[0] if r.stderr else 'no detail'}")
            ok = False

    for kind, name in [("iam", "op-usxpress-prod-risingwave"),
                       ("s3", "risingwave-state-op-usxpress-prod")]:
        if kind == "iam":
            r = subprocess.run(["aws", "iam", "get-role", "--role-name", name,
                                "--profile", profile], capture_output=True, text=True)
        else:
            r = subprocess.run(["aws", "s3api", "head-bucket", "--bucket", name,
                                "--profile", profile], capture_output=True, text=True)
        if r.returncode == 0:
            print(f"      ok       {name}")
        else:
            print(f"      MISSING  {name}")
            ok = False
    return ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("infra_yaml", type=pathlib.Path,
                    help="clusters/op-usxpress-prod/flux-system/infra.yaml")
    ap.add_argument("block", type=pathlib.Path, help="the RisingWave block to append")
    ap.add_argument("--profile", default="ops-controller")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--skip-prereqs", action="store_true",
                    help="draft the change before the Terraform has run (never merge this)")
    args = ap.parse_args()

    for p in (args.infra_yaml, args.block):
        if not p.is_file():
            print(f"ABORT  not a file: {p}", file=sys.stderr)
            return 2

    src = args.infra_yaml.read_text()

    if "risingwave-onprem" in src:
        print("  already wired — nothing to do")
        return 0
    if OLD_NOTE not in src:
        print("ABORT  the 'deliberately absent' note is not where expected.\n"
              "       Read the header before changing it.", file=sys.stderr)
        return 3

    ready = check_prereqs(args.profile)
    print()
    if not ready:
        if not args.skip_prereqs:
            print("ABORT  prerequisites incomplete. Wiring now reproduces the failure the\n"
                  "       header warns about. Run the Octopus deploy first, or pass\n"
                  "       --skip-prereqs to draft the change without merging it.",
                  file=sys.stderr)
            return 4
        print("  --skip-prereqs: drafting anyway. DO NOT MERGE until the list above is clean.")

    out = src.replace(OLD_NOTE, NEW_NOTE)
    out = out.rstrip("\n") + "\n" + args.block.read_text().rstrip("\n") + "\n"

    if not args.write:
        print(f"  dry run — {len(src.splitlines())} lines -> {len(out.splitlines())} lines")
        print("  pass --write to apply")
        return 0

    args.infra_yaml.write_text(out)
    print(f"  written: {args.infra_yaml}")
    print("  now: git diff, then confirm the four new documents parse")
    return 0


if __name__ == "__main__":
    sys.exit(main())
