#!/usr/bin/env python3
"""
Pin a cluster's iaac-risingwave-onprem GitRepository to an exact tag.

Why a script and not sed: `branch: main` appears many times in each cluster's
infra.yaml -- the `infra` source, `iaac-risingwave-2`, others. Only the document
whose url is iaac-risingwave-onprem may change, and exactly one line in it.

Dry-run by default. --apply writes.

  ./pin-risingwave-tag.py --repo ~/pr-work/iaac-talos-flux-cluster --tag v0.5.6
  ./pin-risingwave-tag.py --repo ~/pr-work/iaac-talos-flux-cluster --tag v0.5.6 --apply
"""
import argparse
import difflib
import pathlib
import re
import sys

URL = "https://github.com/variant-inc/iaac-risingwave-onprem.git"
DEFAULT_CLUSTERS = ["op-usxpress-qa", "op-usxpress-prod"]


def fail(msg):
    print(f"!! {msg}", file=sys.stderr)
    sys.exit(1)


def pin_document(doc, tag):
    """Return (new_doc, status). Only touches the ref: block's branch line."""
    lines = doc.split("\n")
    ref_idx = None
    for i, line in enumerate(lines):
        if re.match(r"^\s*ref:\s*$", line):
            ref_idx = i
            break
    if ref_idx is None:
        return doc, "no-ref-block"

    # The ref block is the indented run immediately after `ref:`.
    ref_indent = len(lines[ref_idx]) - len(lines[ref_idx].lstrip())
    changed = 0
    for i in range(ref_idx + 1, len(lines)):
        line = lines[i]
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= ref_indent:
            break  # left the ref block
        m = re.match(r"^(\s*)branch:\s*\S+\s*$", line)
        if m:
            lines[i] = f"{m.group(1)}tag: {tag}"
            changed += 1
        elif re.match(r"^\s*tag:\s*\S+\s*$", line):
            return doc, "already-tag"

    if changed == 0:
        return doc, "no-branch-line"
    if changed > 1:
        fail("more than one branch: line inside a single ref block -- refusing")
    return "\n".join(lines), "pinned"


def process(path, tag):
    original = path.read_text()
    docs = original.split("\n---\n")

    targets = [i for i, d in enumerate(docs) if URL in d and "kind: GitRepository" in d]
    if len(targets) == 0:
        fail(f"{path}: no GitRepository document references {URL}")
    if len(targets) > 1:
        fail(f"{path}: {len(targets)} GitRepository documents reference {URL} -- refusing")

    i = targets[0]
    new_doc, status = pin_document(docs[i], tag)
    if status == "already-tag":
        return original, original, "already pinned"
    if status != "pinned":
        fail(f"{path}: could not pin ({status}) -- the block is not the shape this script expects")

    docs[i] = new_doc
    updated = "\n---\n".join(docs)

    # Exactly one line may differ, and it must be the branch -> tag swap.
    diff = [
        l for l in difflib.unified_diff(original.split("\n"), updated.split("\n"), n=0)
        if l.startswith(("+", "-")) and not l.startswith(("+++", "---"))
    ]
    removed = [l for l in diff if l.startswith("-")]
    added = [l for l in diff if l.startswith("+")]
    if len(removed) != 1 or len(added) != 1:
        fail(f"{path}: expected exactly one line changed, got -{len(removed)} +{len(added)}")
    if "branch:" not in removed[0] or f"tag: {tag}" not in added[0]:
        fail(f"{path}: unexpected change {removed[0]!r} -> {added[0]!r}")

    return original, updated, "pinned"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="path to an iaac-talos-flux-cluster clone")
    ap.add_argument("--tag", required=True, help="exact tag, e.g. v0.5.6 (never v0 or v0.5 -- they float)")
    ap.add_argument("--clusters", default=",".join(DEFAULT_CLUSTERS))
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    if re.fullmatch(r"v\d+", args.tag) or re.fullmatch(r"v\d+\.\d+", args.tag):
        fail(f"{args.tag} is a FLOATING tag -- it moves on every release and gives you no gate. "
             "Use an exact patch tag such as v0.5.6.")

    repo = pathlib.Path(args.repo).expanduser()
    if not (repo / "clusters").is_dir():
        fail(f"{repo} does not look like iaac-talos-flux-cluster (no clusters/ directory)")

    results = []
    for cluster in args.clusters.split(","):
        path = repo / "clusters" / cluster / "flux-system" / "infra.yaml"
        if not path.is_file():
            fail(f"{path} not found")
        original, updated, status = process(path, args.tag)
        results.append((path, original, updated, status))

    for path, original, updated, status in results:
        rel = path.relative_to(repo)
        if status == "already pinned":
            print(f"== {rel}: already pinned, nothing to do")
            continue
        print(f"== {rel}")
        for line in difflib.unified_diff(
            original.split("\n"), updated.split("\n"),
            fromfile=str(rel), tofile=str(rel), lineterm="", n=3
        ):
            print(line)
        print()

    if not args.apply:
        print("dry run -- nothing written. Re-run with --apply.")
        return

    for path, _original, updated, status in results:
        if status == "pinned":
            path.write_text(updated)
            print(f"wrote {path}")


if __name__ == "__main__":
    main()
