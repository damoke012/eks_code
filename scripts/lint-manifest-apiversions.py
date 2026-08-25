#!/usr/bin/env python3
"""Flag a manifest whose apiVersion disagrees with what its branch already uses.

On 2026-08-25 a new ExternalSecret was written with `external-secrets.io/v1beta1`
because that is what the author remembered. op-qa serves `external-secrets.io/v1`.
Flux rejected it at dry-run, which held the argocd Kustomization not-ready, and
argocd-config and argocd-apps depend on it -- so QA delivery froze on one string.

The branch is the authority: whatever apiVersion it already uses for a kind is the
one that works on that cluster. This compares the working tree against it.

  scripts/lint-manifest-apiversions.py ~/pr-work/iaac-talos-flux-platform op-qa
  scripts/lint-manifest-apiversions.py ~/pr-work/iaac-talos-flux-platform op-qa --staged

Exit 1 if any file disagrees, so a PR builder can refuse to push.
"""
import subprocess, sys, os, collections

def sh(*a, cwd=None):
    return subprocess.run(a, cwd=cwd, capture_output=True, text=True).stdout

def kinds_in(text):
    """(apiVersion, kind) per document. Deliberately not a YAML parse: these files
    contain Helm/Flux templating that a strict parser rejects, and a linter that
    crashes on the file it is meant to check is worse than no linter."""
    out, api, kind = [], None, None
    for line in text.splitlines():
        s = line.strip()
        if s == "---":
            if api and kind: out.append((api, kind))
            api = kind = None
        elif s.startswith("apiVersion:") and api is None and not line.startswith(" "):
            api = s.split(":", 1)[1].strip()
        elif s.startswith("kind:") and kind is None and not line.startswith(" "):
            kind = s.split(":", 1)[1].strip()
    if api and kind: out.append((api, kind))
    return out

def main():
    if len(sys.argv) < 3:
        print(__doc__); return 2
    repo, branch = sys.argv[1], sys.argv[2]
    staged = "--staged" in sys.argv
    if not os.path.isdir(os.path.join(repo, ".git")):
        print("!! not a git repo: %s" % repo); return 2

    # what the branch already uses, per kind
    known = collections.defaultdict(set)
    files = sh("git", "ls-tree", "-r", "--name-only", "origin/%s" % branch, cwd=repo).split()
    for f in files:
        if not f.endswith((".yaml", ".yml")): continue
        for api, kind in kinds_in(sh("git", "show", "origin/%s:%s" % (branch, f), cwd=repo)):
            known[kind].add(api)

    # what is about to be added
    if staged:
        changed = sh("git", "diff", "--cached", "--name-only", "--diff-filter=ACM", cwd=repo).split()
    else:
        changed = sh("git", "diff", "--name-only", "--diff-filter=ACM", "origin/%s" % branch, cwd=repo).split()
        changed += [l[3:] for l in sh("git", "status", "--short", cwd=repo).splitlines()
                    if l.startswith("?? ")]

    bad = 0
    checked = 0
    for f in sorted(set(changed)):
        if not f.endswith((".yaml", ".yml")): continue
        p = os.path.join(repo, f)
        if not os.path.exists(p): continue
        for api, kind in kinds_in(open(p, encoding="utf-8", errors="replace").read()):
            if kind not in known:
                continue                      # first of its kind on this branch; nothing to compare
            checked += 1
            if api not in known[kind]:
                bad += 1
                print("!! %s" % f)
                print("   %s uses  %s" % (kind, api))
                print("   %s serves %s" % (branch, ", ".join(sorted(known[kind]))))
    if bad:
        print("\n%d apiVersion disagreement(s). The branch is the authority -- it is what"
              "\nthat cluster's CRDs actually serve." % bad)
        return 1
    print("apiVersions: %d checked against origin/%s, all agree" % (checked, branch))
    return 0

if __name__ == "__main__":
    sys.exit(main())
