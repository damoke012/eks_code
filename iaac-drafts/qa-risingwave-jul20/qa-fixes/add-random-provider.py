#!/usr/bin/env python3
"""add-random-provider.py — add hashicorp/random to main.tf's EXISTING
required_providers block in iaac-risingwave-onprem.

A Terraform module may declare required_providers exactly once, so secrets.tf
cannot bring its own `terraform {}` block. Run from the repo root:

    python3 ~/work/eks_code/iaac-drafts/qa-risingwave-jul20/qa-fixes/add-random-provider.py

Idempotent: exits cleanly if random is already declared.
"""
import re
import sys
from pathlib import Path

p = Path("terraform/main.tf")
if not p.exists():
    sys.exit("ERROR: terraform/main.tf not found — run from the repo root")

s = p.read_text()

if re.search(r'^\s*random\s*=\s*\{', s, re.M):
    print("random provider already declared — nothing to do")
    sys.exit(0)

m = re.search(r'(required_providers\s*\{\n)', s)
if not m:
    sys.exit("ERROR: no required_providers block found in terraform/main.tf")

# Match the indentation of the first entry inside the block so the result is
# fmt-clean rather than relying on terraform fmt to rescue it.
after = s[m.end():]
indent_match = re.search(r'^(\s+)\S', after)
indent = indent_match.group(1) if indent_match else "    "

block = (
    f'{indent}random = {{\n'
    f'{indent}  source  = "hashicorp/random"\n'
    f'{indent}  version = ">= 3.6"\n'
    f'{indent}}}\n'
)

p.write_text(s[:m.end()] + block + after)
print("added hashicorp/random to terraform/main.tf required_providers")
print("run: terraform -chdir=terraform fmt")
