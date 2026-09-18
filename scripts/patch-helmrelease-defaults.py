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

DOCUMENT-AWARE. A platform file routinely holds a HelmRepository and a HelmRelease in
one multi-document YAML, repository first. The first version of this script looked for
the first top-level `spec:` in the FILE and wrote `timeout: 15m` onto the repository --
a valid field there, so nothing complained, while the HelmRelease it was meant to
protect kept the 5-minute default. Three of eighteen files were patched into a no-op
that read as a success in the diff. It also counted `kind: HelmRelease` occurrences as
its safety guard, which one HelmRelease plus one HelmRepository passes. Each document
is now located, classified and patched on its own.

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


def split_documents(text):
    """[(start, end)] line ranges, one per YAML document.

    Splits on a `---` alone at column 0. A `---` indented, or carrying content, is not
    a document separator and must not be treated as one.
    """
    lines = text.splitlines()
    bounds, start = [], 0
    for i, line in enumerate(lines):
        if re.match(r"^---\s*$", line):
            bounds.append((start, i))
            start = i + 1
    bounds.append((start, len(lines)))
    return [b for b in bounds if b[1] > b[0]]


def doc_identity(doc_lines):
    """(kind, 'ns/name') for one document, read from its OWN metadata block."""
    kind = None
    for line in doc_lines:
        m = re.match(r"^kind:\s*(\S+)\s*$", line)
        if m:
            kind = m.group(1)
            break
    meta_i = next((i for i, l in enumerate(doc_lines)
                   if re.match(r"^metadata:\s*$", l)), None)
    ns = nm = "?"
    if meta_i is not None:
        children, _ = find_block_children(doc_lines, meta_i, 0)
        for i in children:
            m = re.match(r"^\s*name:\s*(\S+)\s*$", doc_lines[i])
            if m:
                nm = m.group(1)
            m = re.match(r"^\s*namespace:\s*(\S+)\s*$", doc_lines[i])
            if m:
                ns = m.group(1)
    return kind, f"{ns}/{nm}"


def patch_document(doc, rel_id, pin):
    """Patch ONE HelmRelease document. Returns (new_lines | None, notes)."""
    notes = []
    spec_i = top_level_spec(doc)
    if spec_i is None:
        return None, ["no `spec:` at column 0 in this document"]

    spec_children, spec_indent = find_block_children(doc, spec_i, 0)
    if spec_indent is None:
        return None, ["`spec:` has no children"]

    inserts = []  # (line index to insert BEFORE, text)

    # --- 1. spec.timeout ------------------------------------------------------
    if any(re.match(r"^\s*timeout:", doc[i]) for i in spec_children):
        notes.append("timeout already set")
    else:
        inserts.append((spec_i + 1, " " * spec_indent + f"timeout: {TIMEOUT_DEFAULT}"))
        notes.append(f"+ spec.timeout: {TIMEOUT_DEFAULT}")

    # --- 2. install.remediation.remediateLastFailure --------------------------
    install_i = next(
        (i for i in spec_children if re.match(r"^\s*install:\s*$", doc[i])), None
    )
    if install_i is None:
        notes.append("no install: block -- remediation left alone")
    else:
        inst_children, inst_indent = find_block_children(doc, install_i, spec_indent)
        rem_i = next(
            (i for i in inst_children if re.match(r"^\s*remediation:\s*$", doc[i])), None
        )
        if rem_i is None:
            # Flux defaults install retries to 0. Adding a remediation block here would
            # change behaviour beyond the fix, so it is a skip, not a silent insert.
            notes.append("SKIPPED remediateLastFailure: no install.remediation block")
        else:
            rem_children, rem_indent = find_block_children(doc, rem_i, inst_indent)
            if any(re.match(r"^\s*remediateLastFailure:", doc[i]) for i in rem_children):
                notes.append("remediateLastFailure already set")
            elif rem_indent is None:
                notes.append("SKIPPED remediateLastFailure: remediation block is empty")
            else:
                inserts.append((rem_i + 1, " " * rem_indent + "remediateLastFailure: true"))
                notes.append("+ install.remediation.remediateLastFailure: true")

    # --- 3. pin a floating chart version --------------------------------------
    # Only when --pin names this release AND the document still holds the expected
    # floating value. A version already changed is not ours to rewrite.
    new_doc = doc[:]
    if rel_id in pin:
        want_from, want_to = pin[rel_id]
        pat = re.compile(r'^(\s*version:\s*)(["\']?)' + re.escape(want_from) + r'\2\s*$')
        hits = [i for i, l in enumerate(new_doc) if pat.match(l)]
        if len(hits) == 1:
            m = pat.match(new_doc[hits[0]])
            new_doc[hits[0]] = f'{m.group(1)}"{want_to}"'
            notes.append(f"version {want_from} -> {want_to}")
        elif not hits:
            notes.append(f"SKIPPED pin: no `version: {want_from}` line in this document")
        else:
            notes.append(f"SKIPPED pin: {len(hits)} `version: {want_from}` lines")

    for at, text_line in sorted(inserts, key=lambda x: -x[0]):
        new_doc.insert(at, text_line)

    if new_doc == doc:
        return None, notes
    return new_doc, notes


def patch_file(text, pin):
    """Patch every HelmRelease document in a file. Returns (new_text | None, notes, ids)."""
    lines = text.splitlines()
    plan, notes, ids = [], [], []

    for start, end in split_documents(text):
        doc = lines[start:end]
        kind, rid = doc_identity(doc)
        if kind != "HelmRelease":
            notes.append(f"[{kind or 'no kind'} {rid}] not a HelmRelease -- untouched")
            continue
        ids.append(rid)
        new_doc, dnotes = patch_document(doc, rid, pin)
        notes.extend(f"[{rid}] {n}" for n in dnotes)
        if new_doc is not None:
            plan.append((start, end, new_doc))

    if not ids:
        return None, notes + ["no HelmRelease document in this file"], ids
    if not plan:
        return None, notes + ["nothing to change"], ids

    # Splice from the LAST document backwards so earlier line indices stay valid.
    new_lines = lines[:]
    for start, end, new_doc in sorted(plan, key=lambda x: -x[0]):
        new_lines[start:end] = new_doc
    return "\n".join(new_lines) + ("\n" if text.endswith("\n") else ""), notes, ids


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
    print(f"{len(files)} file(s) containing a HelmRelease under {root}\n")

    changed = untouched = 0
    seen_ids = set()
    for f in files:
        text = f.read_text()
        new, notes, ids = patch_file(text, pin)
        seen_ids.update(ids)
        rel_path = f.relative_to(root)
        marker = "**" if new else "--"
        print(f"{marker} {rel_path}")
        for n in notes:
            print(f"     {n}")
        if new is None:
            untouched += 1
            continue
        changed += 1
        for line in difflib.unified_diff(
            text.splitlines(), new.splitlines(),
            fromfile=str(rel_path), tofile=str(rel_path), lineterm="", n=2,
        ):
            print("   " + line)
        print()
        if a.apply:
            f.write_text(new)

    unmatched = sorted(set(pin) - seen_ids)
    if unmatched:
        print("!! --pin named releases that were not found: " + ", ".join(unmatched))
        print("   HelmReleases seen: " + ", ".join(sorted(seen_ids)))

    print(f"\n{changed} file(s) to change, {untouched} left alone.")
    if not a.apply:
        print("dry run -- nothing written. Re-run with --apply, then read `git diff`.")


if __name__ == "__main__":
    main()
