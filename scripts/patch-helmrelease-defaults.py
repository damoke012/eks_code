#!/usr/bin/env python3
"""Add the two missing Flux defaults to every HelmRelease in a platform checkout.

Why this exists. On 2026-09-18 op-usxpress-qa's `grafana/grafana` was found
Stalled/RetriesExceeded with no install attempt since 14 July, while the pod ran 3/3
for 72 days -- two months of commits reaching nothing, reported by no status field.
Two Flux defaults in series caused it, and `scripts/check-helmrelease-truth.sh` then
found 13 of 19 releases missing the first and 16 of 19 missing the second. Grafana was
not unlucky; it was first.

  * `.spec.timeout` unset -> Helm allows readiness 5 minutes and records a merely slow
    install as `failed`.
  * `install.remediation.remediateLastFailure` unset -> defaults FALSE for install and
    TRUE for upgrade, so every retry attempts to UPGRADE a release whose only version
    is a failed install, which Helm refuses.

Edits are textual and anchored on structure, so comments, key order and formatting
survive for review. A YAML round-trip would rewrite all 18 files and make the diff
unreadable, which is how an unrelated change rides along unnoticed.

CONSERVATIVE BY CONSTRUCTION:
  * only ever ADDS `timeout` and `remediateLastFailure`, never edits another value
  * only touches an `install.remediation` block that ALREADY EXISTS. Where there is
    none, Flux defaults to retries 0; inventing one would change behaviour beyond the
    stated fix, so the file is skipped and named.
  * refuses any file it cannot read confidently, and says which and why
  * pins a version only when --pin names it AND the current value is what --pin expects

Dry run by default: prints a unified diff per file and writes nothing.

    python3 scripts/patch-helmrelease-defaults.py /path/to/iaac-talos-flux-platform \\
        --pin external-secrets/external-secrets=2.2.x:2.2.0 \\
        --pin keda/keda=2.19.x:2.19.0
    ... --apply
"""
import argparse
import difflib
import pathlib
import re
import sys

TIMEOUT_DEFAULT = "15m"


def fail(msg):
    print(f"\n!! {msg}\n", file=sys.stderr)
    sys.exit(1)


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def find_block_children(lines, start, parent_indent):
    """Line indices of the direct children of the mapping opened at `start`.

    Stops at the first line indented at or below the parent -- that is the end of the
    block. Blank lines and comments never end a block; treating them as terminators
    would silently truncate a block that merely contains a comment.
    """
    out = []
    child_indent = None
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        ind = indent_of(line)
        if ind <= parent_indent:
            break
        if child_indent is None:
            child_indent = ind
        if ind == child_indent:
            out.append(i)
    return out, child_indent


def top_level_spec(lines):
    for i, line in enumerate(lines):
        if re.match(r"^spec:\s*$", line):
            return i
    return None


def patch(text, rel_id, pin):
    """Return (new_text, [notes]) or (None, [reasons it was skipped])."""
    lines = text.splitlines()
    notes = []

    if sum(1 for l in lines if re.match(r"^\s*kind:\s*HelmRelease\s*$", l)) != 1:
        return None, ["not exactly one HelmRelease document in the file"]

    spec_i = top_level_spec(lines)
    if spec_i is None:
        return None, ["no top-level `spec:` at column 0"]

    spec_children, spec_indent = find_block_children(lines, spec_i, 0)
    if spec_indent is None:
        return None, ["`spec:` has no children"]

    inserts = []  # (line index to insert BEFORE, text)

    # --- 1. spec.timeout ------------------------------------------------------
    have_timeout = any(re.match(r"^\s*timeout:", lines[i]) for i in spec_children)
    if have_timeout:
        notes.append("timeout already set")
    else:
        inserts.append((spec_i + 1, " " * spec_indent + f"timeout: {TIMEOUT_DEFAULT}"))
        notes.append(f"+ spec.timeout: {TIMEOUT_DEFAULT}")

    # --- 2. install.remediation.remediateLastFailure --------------------------
    install_i = next(
        (i for i in spec_children if re.match(r"^\s*install:\s*$", lines[i])), None
    )
    if install_i is None:
        notes.append("no install: block -- remediation left alone")
    else:
        inst_children, inst_indent = find_block_children(lines, install_i, spec_indent)
        rem_i = next(
            (i for i in inst_children if re.match(r"^\s*remediation:\s*$", lines[i])),
            None,
        )
        if rem_i is None:
            # Flux defaults install retries to 0. Adding a remediation block here would
            # change behaviour beyond the fix, so it is a skip, not a silent insert.
            notes.append("SKIPPED remediateLastFailure: no install.remediation block")
        else:
            rem_children, rem_indent = find_block_children(lines, rem_i, inst_indent)
            if any(
                re.match(r"^\s*remediateLastFailure:", lines[i]) for i in rem_children
            ):
                notes.append("remediateLastFailure already set")
            elif rem_indent is None:
                notes.append("SKIPPED remediateLastFailure: remediation block is empty")
            else:
                inserts.append(
                    (rem_i + 1, " " * rem_indent + "remediateLastFailure: true")
                )
                notes.append("+ install.remediation.remediateLastFailure: true")

    # --- 3. pin a floating chart version --------------------------------------
    # Only when --pin names this release AND the file still holds the expected
    # floating value. A version that has already been changed is not ours to rewrite.
    new_lines = lines[:]
    if rel_id in pin:
        want_from, want_to = pin[rel_id]
        pat = re.compile(r'^(\s*version:\s*)(["\']?)' + re.escape(want_from) + r'\2\s*$')
        hits = [i for i, l in enumerate(new_lines) if pat.match(l)]
        if len(hits) == 1:
            i = hits[0]
            m = pat.match(new_lines[i])
            new_lines[i] = f'{m.group(1)}"{want_to}"'
            notes.append(f"version {want_from} -> {want_to}")
        elif not hits:
            notes.append(f"SKIPPED pin: no `version: {want_from}` line found")
        else:
            notes.append(f"SKIPPED pin: {len(hits)} `version: {want_from}` lines")

    for at, text_line in sorted(inserts, key=lambda x: -x[0]):
        new_lines.insert(at, text_line)

    if new_lines == lines:
        return None, notes + ["nothing to change"]
    return "\n".join(new_lines) + ("\n" if text.endswith("\n") else ""), notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", help="path to an iaac-talos-flux-platform checkout")
    ap.add_argument(
        "--pin",
        action="append",
        default=[],
        metavar="NS/NAME=FROM:TO",
        help="pin a floating chart, e.g. keda/keda=2.19.x:2.19.0. Repeatable.",
    )
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    pin = {}
    for p in a.pin:
        m = re.fullmatch(r"([^=]+)=([^:]+):(.+)", p)
        if not m:
            fail(f"--pin expects NS/NAME=FROM:TO, got {p!r}")
        pin[m.group(1)] = (m.group(2), m.group(3))

    root = pathlib.Path(a.root)
    if not (root / ".git").exists():
        fail(f"{root} is not a git checkout -- edit the branch, not a stale copy")

    files = [
        f
        for f in sorted(root.rglob("*.yaml"))
        if ".git" not in f.parts and "kind: HelmRelease" in f.read_text()
    ]
    if not files:
        fail("no file under this checkout contains `kind: HelmRelease`")
    print(f"{len(files)} HelmRelease file(s) under {root}\n")

    changed = skipped = 0
    seen_ids = set()
    for f in files:
        text = f.read_text()
        ns = re.search(r"^\s*namespace:\s*(\S+)\s*$", text, re.M)
        nm = re.search(r"^\s*name:\s*(\S+)\s*$", text, re.M)
        rel_id = f"{ns.group(1)}/{nm.group(1)}" if ns and nm else "?/?"
        seen_ids.add(rel_id)

        new, notes = patch(text, rel_id, pin)
        rel_path = f.relative_to(root)
        if new is None:
            skipped += 1
            print(f"-- {rel_path}  ({rel_id})")
            for n in notes:
                print(f"     {n}")
            continue

        changed += 1
        print(f"** {rel_path}  ({rel_id})")
        for n in notes:
            print(f"     {n}")
        for line in difflib.unified_diff(
            text.splitlines(), new.splitlines(),
            fromfile=str(rel_path), tofile=str(rel_path), lineterm="", n=2,
        ):
            print("   " + line)
        print()
        if a.apply:
            f.write_text(new)

    unmatched = set(pin) - seen_ids
    if unmatched:
        print("!! --pin named releases that were not found: " + ", ".join(sorted(unmatched)))

    print(f"\n{changed} file(s) to change, {skipped} left alone.")
    if not a.apply:
        print("dry run -- nothing written. Re-run with --apply, then read `git diff`.")


if __name__ == "__main__":
    main()
