#!/usr/bin/env python3
"""add-helm-remediation.py — close finding F4: a blown Helm timeout escalates
into a release state Flux cannot recover from.

THE BUG (see BUILD-FINDINGS-2026-07-29.md F4)
  When the istio-cni/ztunnel blackout (F1) pushed chart installs past their
  timeouts, helm-controller began a rollback-uninstall. kyverno's uninstall then
  hung on its pre-delete hook, parking the release at:

      Could not determine release state: unable to determine state for release
      with status 'uninstalling'

  Flux retries that forever without progressing. THREE releases wedged this way in
  a single build — kyverno, argocd, istio-ingressgateway — each needing a human
  with `helm uninstall --no-hooks`.

  Root cause: no `spec.install.remediation` anywhere, so a timeout has no retry
  path and converts straight into an unrecoverable state.

WHAT THIS DOES
  Adds to every HelmRelease that lacks it:

      spec.install.remediation.retries: 3
      spec.upgrade.remediation.retries: 3

  Edits are LINE-BASED so comments, key order and formatting survive. Every file
  is re-parsed after writing and the result compared against the original
  structure — a file whose kind/name/chart changed is restored and reported.

  Files where the anchor is ambiguous are SKIPPED and listed for manual handling
  rather than guessed at.

USAGE
  Run from the ROOT of a checked-out iaac-talos-flux-platform, on a branch:

    git checkout -b fix/helm-install-remediation op-prod
    python3 add-helm-remediation.py                    # dry-run
    python3 add-helm-remediation.py --apply
    git diff

  Optional: --timeout 15m also sets spec.timeout on releases that declare none.
  The default 5m health timeouts are tuned for a warm cluster; on a greenfield
  build with no image cache they fire routinely and make a healthy cluster read as
  broken. Existing timeouts are REPORTED, never overwritten — raising someone's
  deliberate 10m to 15m is a judgement call, not a mechanical one.
"""

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("ERROR: PyYAML missing.  pip install pyyaml  (or: apt install python3-yaml)")

ap = argparse.ArgumentParser()
ap.add_argument("--apply", action="store_true")
ap.add_argument("--retries", type=int, default=3)
ap.add_argument("--timeout", default=None,
                help="set spec.timeout on releases that declare none, e.g. 15m")
ap.add_argument("--root", default="infrastructure",
                help="directory to walk (default: infrastructure)")
args = ap.parse_args()

ROOT = Path(args.root)
if not ROOT.is_dir():
    sys.exit(f"ERROR: {ROOT} not found. Run from the root of iaac-talos-flux-platform.")

SPEC_KEY = re.compile(r"^  (\w+):")          # direct child of a top-level `spec:`
INTERVAL = re.compile(r"^  interval:\s")     # spec-level interval, not chart.spec.interval


def summarize(doc):
    """Structural fingerprint used to prove an edit changed nothing but remediation."""
    if not isinstance(doc, dict):
        return None
    spec = doc.get("spec") or {}
    chart = ((spec.get("chart") or {}).get("spec") or {})
    return (doc.get("kind"), (doc.get("metadata") or {}).get("name"),
            (doc.get("metadata") or {}).get("namespace"),
            chart.get("chart"), chart.get("version"), spec.get("interval"))


def patch_doc(text):
    """Return (new_text, [actions], skip_reason). Operates on ONE yaml document."""
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as e:
        return text, [], f"unparseable: {str(e)[:80]}"
    if not isinstance(doc, dict) or doc.get("kind") != "HelmRelease":
        return text, [], None

    spec = doc.get("spec") or {}
    name = (doc.get("metadata") or {}).get("name", "?")
    lines = text.split("\n")
    actions = []

    # locate the spec-level anchor line once
    anchor = next((i for i, l in enumerate(lines) if INTERVAL.match(l)), None)

    for key in ("install", "upgrade"):
        block = spec.get(key)
        if isinstance(block, dict) and isinstance(block.get("remediation"), dict) \
                and block["remediation"].get("retries") is not None:
            continue  # already has it

        if isinstance(block, dict):
            # `install:` exists but has no remediation -> nest under the existing key
            idx = next((i for i, l in enumerate(lines) if l.rstrip() == f"  {key}:"), None)
            if idx is None:
                return text, [], f"{name}: spec.{key} present but `  {key}:` line not found"
            lines[idx + 1:idx + 1] = ["    remediation:", f"      retries: {args.retries}"]
            actions.append(f"{name}: spec.{key}.remediation.retries={args.retries} (nested)")
        else:
            if anchor is None:
                return text, [], f"{name}: no spec-level `interval:` to anchor to"
            lines[anchor + 1:anchor + 1] = [
                f"  {key}:", "    remediation:", f"      retries: {args.retries}"]
            actions.append(f"{name}: spec.{key}.remediation.retries={args.retries}")
        # re-find the anchor, list indices shifted
        anchor = next((i for i, l in enumerate(lines) if INTERVAL.match(l)), None)

    if args.timeout:
        if spec.get("timeout") is None:
            if anchor is None:
                return text, [], f"{name}: no spec-level `interval:` to anchor timeout to"
            lines[anchor + 1:anchor + 1] = [f"  timeout: {args.timeout}"]
            actions.append(f"{name}: spec.timeout={args.timeout}")
        else:
            actions.append(f"{name}: spec.timeout={spec['timeout']} LEFT AS-IS (declared)")

    return "\n".join(lines), actions, None


changed, skipped, all_actions = [], [], []

for path in sorted(ROOT.rglob("*.yaml")):
    raw = path.read_text()
    if "kind: HelmRelease" not in raw:
        continue

    docs = raw.split("\n---\n")
    try:
        before = [summarize(yaml.safe_load(x)) for x in docs]
    except yaml.YAMLError as e:
        skipped.append(f"{path}: does not parse as YAML ({str(e)[:60]}) — untouched")
        continue
    out, file_actions, bad = [], [], None

    for d in docs:
        new, acts, reason = patch_doc(d)
        if reason:
            bad = reason
        out.append(new)
        file_actions += acts

    if bad:
        skipped.append(f"{path}: {bad}")
        continue
    if not file_actions:
        continue

    new_raw = "\n---\n".join(out)

    # verify: parses, and nothing but remediation/timeout moved
    try:
        after = [summarize(x) for x in yaml.safe_load_all(new_raw)]
    except yaml.YAMLError as e:
        skipped.append(f"{path}: edit produced invalid YAML ({str(e)[:60]}) — NOT written")
        continue
    if after != before:
        skipped.append(f"{path}: structural fingerprint changed — NOT written")
        continue
    unset = [x for x in yaml.safe_load_all(new_raw)
             if isinstance(x, dict) and x.get("kind") == "HelmRelease"
             and (((x.get("spec") or {}).get("install") or {}).get("remediation")
                  or {}).get("retries") is None]
    if unset:
        names = ", ".join((x.get("metadata") or {}).get("name", "?") for x in unset)
        skipped.append(f"{path}: verification failed — install.remediation absent on {names}")
        continue

    changed.append((path, new_raw))
    all_actions += file_actions

print(f"=== {len(changed)} file(s) to change, {len(all_actions)} edit(s) ===")
for a in all_actions:
    print(f"  + {a}")

if skipped:
    print(f"\n=== {len(skipped)} SKIPPED (handle by hand) ===")
    for s in skipped:
        print(f"  ! {s}")

if not changed:
    sys.exit("\nNothing to do — every HelmRelease already declares install remediation.")

if not args.apply:
    sys.exit("\n[DRY-RUN] No files written. Re-run with --apply.")

for path, new_raw in changed:
    path.write_text(new_raw)
print(f"\n✓ Wrote {len(changed)} file(s). Review with `git diff` before committing.")
