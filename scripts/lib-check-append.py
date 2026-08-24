#!/usr/bin/env python3
"""Assert an append to a multi-document YAML added exactly what it claimed to.

Used by pr-sso-dev-prod.sh. Parsing is not the check: clusters/bm-dev/flux-system/
infra.yaml has no trailing newline, so appending "---" glued it onto a comment
line, the document separator vanished, and the new keys became DUPLICATE
top-level keys on the previous Kustomization. PyYAML keeps the last value, so the
file parsed cleanly while app-namespaces had been silently replaced by rbac.

    lib-check-append.py <file> <count-before>   ->  prints count-after, exit 0
"""
import sys, yaml

path, before = sys.argv[1], int(sys.argv[2])
docs = [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if d]
ks = [d for d in docs if d.get("kind") == "Kustomization"]
names = [d.get("metadata", {}).get("name") for d in ks]

if len(ks) != before + 2:
    sys.exit(f"expected {before + 2} Kustomizations, found {len(ks)} "
             f"-- the append did not add two documents")
for want in ("rbac", "aws-iam-authenticator", "app-namespaces"):
    if want not in names:
        sys.exit(f"Kustomization '{want}' is missing after the append")
if len(names) != len(set(names)):
    dupes = sorted({n for n in names if names.count(n) > 1})
    sys.exit(f"duplicate Kustomization names after the append: {dupes}")
print(len(ks))
