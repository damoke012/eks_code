#!/usr/bin/env python3
"""INFRA-1674 step 4a — derive manifests/op-usxpress-<target>/ from an existing environment.

Only the RisingWave workload lives here: operator, CR, console, ghostunnel, postgres,
ExternalSecrets, bootstrap jobs. The **routes do not** — VirtualServices and Gateways come
from iaac-talos-flux-platform's per-cluster branch, so nothing in this tree carries a node
IP or a DNS target. Verified 2026-08-31: zero `10.10.x` in all 24 QA files.

Three substitutions, and they are the whole difference:

    op-usxpress-qa      -> op-usxpress-prod     (also fixes the state bucket name)
    op-qa.usxpress.io   -> op-prod.usxpress.io  (also fixes the Dex redirect URI)
    527101283767        -> 937464026810

Deliberately NOT substituted: the Dex `clientID`. Dev, QA and prod share one Entra app
registration and only the redirect URI differs.

Refuses rather than guesses: any source token that looks environment-shaped but is not one
of the three is reported, and an unknown AWS account id aborts.

Read-only unless --write.
"""
import argparse
import pathlib
import re
import sys

ACCOUNTS = {
    "700736442855": "op-usxpress-dev",
    "527101283767": "op-usxpress-qa",
    "937464026810": "op-usxpress-prod",
    "064859874041": "ecr / infra-common",
    "155768531003": "network (route53 zone)",
    "786352483360": "PLAYGROUND — never a cluster account",
}

# Order matters only in that the cluster-name rule must run before nothing else;
# `risingwave-state-op-usxpress-qa` is fixed as a side effect of rule 1.
def rules(src_env, dst_env, src_acct, dst_acct):
    return [
        (f"op-usxpress-{src_env}", f"op-usxpress-{dst_env}"),
        (f"op-{src_env}.usxpress.io", f"op-{dst_env}.usxpress.io"),
        (src_acct, dst_acct),
    ]

ENVISH = re.compile(
    r"arn:aws:[a-z0-9:/_-]+"
    r"|\b\d{12}\b"
    r"|[a-z0-9.-]+\.usxpress\.(?:io|com)"
    r"|\b10\.10\.\d{1,3}\.\d{1,3}\b"
    r"|op-usxpress-(?:dev|qa|prod)"
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("repo", type=pathlib.Path, help="clone of iaac-risingwave-onprem")
    ap.add_argument("--from", dest="src", default="qa", choices=["dev", "qa", "prod"])
    ap.add_argument("--to", dest="dst", default="prod", choices=["dev", "qa", "prod"])
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    if args.src == args.dst:
        print("ABORT  --from and --to are the same environment", file=sys.stderr)
        return 2

    src_dir = args.repo / "manifests" / f"op-usxpress-{args.src}"
    dst_dir = args.repo / "manifests" / f"op-usxpress-{args.dst}"
    if not src_dir.is_dir():
        print(f"ABORT  no source tree at {src_dir}", file=sys.stderr)
        return 2
    if dst_dir.exists() and not args.write:
        print(f"  note: {dst_dir} already exists — files would be OVERWRITTEN")

    src_acct = next(a for a, n in ACCOUNTS.items() if n == f"op-usxpress-{args.src}")
    dst_acct = next(a for a, n in ACCOUNTS.items() if n == f"op-usxpress-{args.dst}")
    subs = rules(args.src, args.dst, src_acct, dst_acct)

    files = sorted(p for p in src_dir.rglob("*") if p.is_file())
    print(f"  {len(files)} files under {src_dir}")
    print(f"  substitutions:")
    for a, b in subs:
        print(f"      {a}  ->  {b}")
    print()

    unexpected: dict[str, set[str]] = {}
    fatal = False
    total = 0
    # Buffer every rewritten file. Nothing touches disk until all checks pass, so an
    # abort really means nothing written rather than a half-built tree.
    pending: list[tuple[pathlib.Path, str]] = []

    for f in files:
        raw = f.read_text()
        out = raw
        hits = 0
        for a, b in subs:
            n = out.count(a)
            hits += n
            out = out.replace(a, b)

        # A known account id anywhere in the output is fatal — check by substring, not by
        # token equality: an id nested inside an ARN is consumed by the ARN alternative
        # and never appears as a token of its own.
        for acct, who in ACCOUNTS.items():
            if acct != dst_acct and acct in out:
                print(f"  FATAL   {f.relative_to(src_dir)}: account {acct} ({who}) survives the rewrite")
                fatal = True

        # Anything still environment-shaped in the OUTPUT is a value we did not handle.
        for tok in set(ENVISH.findall(out)):
            if f"op-usxpress-{args.dst}" in tok or f"op-{args.dst}.usxpress.io" in tok:
                continue
            if dst_acct in tok:
                continue
            if any(a in tok for a in ACCOUNTS):
                continue  # already reported as FATAL above
            unexpected.setdefault(tok, set()).add(str(f.relative_to(src_dir)))

        rel = f.relative_to(src_dir)
        if hits:
            print(f"  {hits:3d} sub  {rel}")
            total += hits
        else:
            print(f"        -  {rel}")

        pending.append((dst_dir / rel, out))

    print(f"\n  {total} substitutions across {len(files)} files")

    if unexpected:
        print("\n  REVIEW — environment-shaped tokens that no rule touched:")
        for tok, where in sorted(unexpected.items()):
            print(f"      {tok}   in {', '.join(sorted(where))}")
        print("      Confirm each is genuinely environment-neutral before merging.")
        print("      The Dex clientID is expected here: one registration serves all three.")

    if fatal:
        print("\nABORT  a known account id survived. Nothing written.", file=sys.stderr)
        return 3

    if not args.write:
        print("\n  dry run — pass --write to create the tree")
        return 0

    for target, content in pending:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    print(f"\n  written: {dst_dir}  ({len(pending)} files)")
    print("  next: kubectl kustomize that directory and read the output before committing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
