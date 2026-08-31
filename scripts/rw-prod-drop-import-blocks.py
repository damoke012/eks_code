#!/usr/bin/env python3
"""INFRA-1674 task A — remove the five unconditional `import` blocks from
iaac-risingwave-onprem's secrets.tf.

WHY: an `import` block is idempotent only for an object already in state. For a
remote object that does not exist, Terraform fails the plan with
"Cannot import non-existent remote object". op-usxpress-prod (937464026810) has
none of the five secrets, so prod's first plan dies before creating anything.

Removing them is a state no-op for dev and QA, whose secrets are already adopted.
The file's own comment already says to remove them after each environment's first
apply; that never happened.

Read-only unless --write is passed. Never applies anything.
"""
import argparse
import re
import sys
from pathlib import Path

EXPECTED = {
    "aws_secretsmanager_secret.postgres",
    "aws_secretsmanager_secret.root",
    "aws_secretsmanager_secret.svc_reporting",
    "aws_secretsmanager_secret.secret_store_private_key",
    "aws_secretsmanager_secret.console_license_key",
}

# The comment header that introduces the blocks, so it goes with them.
# Only the Imports header's own comment lines — never a following `// ── ` divider.
HEADER = re.compile(
    r"^// ── Imports —.*\n(?://(?! ──).*\n)*", re.MULTILINE
)
BLOCK = re.compile(
    r"^import\s*\{\s*\n"
    r"\s*to\s*=\s*(?P<to>[\w.]+)\s*\n"
    r"\s*id\s*=\s*\"[^\"]*\"\s*\n"
    r"\}\s*\n\n?",
    re.MULTILINE,
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "secrets_tf",
        type=Path,
        help="path to deploy/terraform/secrets.tf in a clone of iaac-risingwave-onprem",
    )
    ap.add_argument("--write", action="store_true", help="rewrite the file in place")
    args = ap.parse_args()

    if not args.secrets_tf.is_file():
        print(f"ABORT  not a file: {args.secrets_tf}", file=sys.stderr)
        return 2

    src = args.secrets_tf.read_text()
    found = {m.group("to") for m in BLOCK.finditer(src)}

    if not found:
        print("  no import blocks found — already removed, or the file changed shape")
        return 0

    missing = EXPECTED - found
    extra = found - EXPECTED
    for name in sorted(found):
        print(f"  REMOVE  import -> {name}")
    for name in sorted(missing):
        print(f"  absent  expected but not present: {name}")
    for name in sorted(extra):
        print(f"  NEW     not in the expected five: {name}")

    if extra:
        print(
            "\nABORT  an import block exists that this change was not written for.\n"
            "       Read it before removing anything.",
            file=sys.stderr,
        )
        return 3

    # Header first: while the import blocks are still present they terminate the
    # comment run, so the next section's `// ── ` divider cannot be swallowed.
    out = HEADER.sub("", src)
    out = BLOCK.sub("", out)
    out = re.sub(r"\n{3,}", "\n\n", out)

    if not args.write:
        print(f"\n  dry run — {len(src.splitlines())} lines -> {len(out.splitlines())} lines")
        print("  pass --write to apply")
        return 0

    args.secrets_tf.write_text(out)
    print(f"\n  written: {args.secrets_tf}")
    print("  now run: terraform fmt -check && terraform validate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
