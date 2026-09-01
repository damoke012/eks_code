#!/usr/bin/env python3
"""INFRA-1674 step 4b — derive a cluster's risingwave-routes/ from another cluster's.

Why derive from QA rather than fix op-prod's files in place: op-prod's copies came
verbatim from dev — dev hostnames, dev's seven worker IPs. QA's were corrected under
INFRA-1645 on 2026-08-20 and carry the explanation. Deriving inherits the fix and the
comment; patching in place inherits neither.

Two things change, and only two:

  1. `op-<src>` -> `op-<dst>` in every hostname and certificate SAN.
  2. The `external-dns.alpha.kubernetes.io/target` value, which is NOT a token swap —
     each cluster targets a different set of node addresses. The destination value is
     READ from the destination branch's own working argocd VirtualService, so it is
     whatever that cluster already proves works, not a guess and not another cluster's.

Refuses if the destination target cannot be read. Read-only unless --write.
"""
import argparse
import pathlib
import re
import subprocess
import sys

ROUTES = "infrastructure/risingwave-routes"
ARGOCD_VS = "infrastructure/argocd-config/virtualservice-argocd.yaml"
TARGET_KEY = "external-dns.alpha.kubernetes.io/target"
# The value may be quoted or bare — QA quotes it, prod does not. Requiring quotes
# made the script report "carries no target" for a file that plainly has one.
TARGET_RE = re.compile(
    rf'({re.escape(TARGET_KEY)}:[ \t]*)"?([^"\n]+?)"?[ \t]*$',
    re.MULTILINE,
)


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True,
    )


def show(repo, ref, path):
    r = git(repo, "show", f"{ref}:{path}")
    return r.stdout if r.returncode == 0 else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("repo", type=pathlib.Path, help="clone of iaac-talos-flux-platform")
    ap.add_argument("--from", dest="src", default="qa", choices=["dev", "qa", "prod"])
    ap.add_argument("--to", dest="dst", default="prod", choices=["dev", "qa", "prod"])
    ap.add_argument("--write", action="store_true",
                    help="write into the working tree — you must already be ON the destination branch")
    args = ap.parse_args()

    if args.src == args.dst:
        print("ABORT  --from and --to are the same", file=sys.stderr)
        return 2

    src_ref = f"origin/op-{args.src}"
    dst_ref = f"origin/op-{args.dst}"

    # The destination's own working route is the authority for the target addresses.
    argocd = show(args.repo, dst_ref, ARGOCD_VS)
    if argocd is None:
        print(f"ABORT  cannot read {dst_ref}:{ARGOCD_VS} — no authority for the target list",
              file=sys.stderr)
        return 3
    m = TARGET_RE.search(argocd)
    if not m:
        print(f"ABORT  {dst_ref}:{ARGOCD_VS} carries no {TARGET_KEY}", file=sys.stderr)
        return 3
    dst_target = m.group(2)

    src_argocd = show(args.repo, src_ref, ARGOCD_VS)
    src_target = TARGET_RE.search(src_argocd).group(2) if src_argocd else None

    print(f"  source      {src_ref}:{ROUTES}")
    print(f"  destination {dst_ref}")
    print(f"  hostname    op-{args.src}  ->  op-{args.dst}")
    print(f"  target      taken from {dst_ref}:{ARGOCD_VS}, the destination's own working route")
    print(f"                {dst_target}")
    if src_target:
        print(f"              (source used {src_target})")
    print()

    listing = git(args.repo, "ls-tree", "-r", "--name-only", src_ref, "--", ROUTES)
    if listing.returncode != 0 or not listing.stdout.strip():
        print(f"ABORT  no files under {src_ref}:{ROUTES}", file=sys.stderr)
        return 3
    files = listing.stdout.split()

    pending: list[tuple[pathlib.Path, str]] = []
    stale = []

    for path in files:
        body = show(args.repo, src_ref, path)
        if body is None:
            print(f"ABORT  cannot read {src_ref}:{path}", file=sys.stderr)
            return 3

        out = body.replace(f"op-{args.src}", f"op-{args.dst}")
        subs = body.count(f"op-{args.src}")
        out, n = TARGET_RE.subn(lambda mm: f'{mm.group(1)}"{dst_target}"', out)  # always emit quoted

        # Anything still naming another environment is a value neither rule reached.
        for other in ("dev", "qa", "prod"):
            if other == args.dst:
                continue
            if f"op-{other}" in out:
                stale.append((path, f"op-{other}"))

        print(f"  {subs:2d} host  {n} target   {path}")
        pending.append((args.repo / path, out))

    if stale:
        print("\n  FATAL — another environment's identifier survives:")
        for path, tok in stale:
            print(f"      {path}: {tok}")
        print("\nABORT  nothing written.", file=sys.stderr)
        return 4

    if not args.write:
        print(f"\n  dry run — {len(pending)} files. Pass --write (on the {dst_ref} branch) to apply.")
        return 0

    # The local branch NAME is not evidence — a fix/... branch off op-prod is correct
    # and would fail a name check. What matters is which branch it tracks.
    branch = git(args.repo, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    upstream = git(args.repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}").stdout.strip()
    if not upstream:
        print(f"\nABORT  '{branch}' tracks nothing, so the destination cannot be confirmed.\n"
              f"       Branch from origin/op-{args.dst} and retry.", file=sys.stderr)
        return 5
    if not upstream.endswith(f"op-{args.dst}"):
        print(f"\nABORT  '{branch}' tracks '{upstream}', not origin/op-{args.dst}.",
              file=sys.stderr)
        return 5
    print(f"  branch      {branch} -> tracks {upstream}")

    for target, content in pending:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    print(f"\n  written: {len(pending)} files into {branch}")
    print("  now: git diff — every changed line should be a hostname or a target list")
    return 0


if __name__ == "__main__":
    sys.exit(main())
