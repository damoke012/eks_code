#!/usr/bin/env python3
"""Flag a manifest whose apiVersion disagrees with what its branch already uses.

On 2026-08-25 a new ExternalSecret was written with `external-secrets.io/v1beta1`
because that is what the author remembered. op-qa serves `external-secrets.io/v1`.
Flux rejected it at dry-run, which held the argocd Kustomization not-ready, and
argocd-config and argocd-apps depend on it -- so QA delivery froze on one string.

The branch is the authority: whatever apiVersion it already uses for a kind is the
one that works on that cluster. This compares the working tree against it.

Two failure modes this had to survive, both found by self-testing it against the
real defect rather than trusting it:

  * a merged defect AUTHORIZES ITSELF. The first version asked "does anything on the
    branch use this apiVersion?" -- and by then the bad file was on the branch, so it
    was its own precedent. Files under test are excluded from the baseline.
  * a lone dissenter is not agreement. 11 ExternalSecrets used v1 and exactly one used
    v1beta1; "it appears somewhere" passed it. The dominant version wins, and a
    minority is reported with its counts.

  scripts/lint-manifest-apiversions.py ~/pr-work/iaac-talos-flux-platform op-qa
  scripts/lint-manifest-apiversions.py ~/pr-work/iaac-talos-flux-platform op-qa --staged
  scripts/lint-manifest-apiversions.py ~/pr-work/iaac-talos-flux-platform op-qa --base 4b03212

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
    # --base pins the baseline to a ref BEFORE the change under test. Without it a
    # defect already merged to the branch becomes its own precedent.
    base = "origin/%s" % branch
    if "--base" in sys.argv:
        base = sys.argv[sys.argv.index("--base") + 1]
    if not os.path.isdir(os.path.join(repo, ".git")):
        print("!! not a git repo: %s" % repo); return 2

    # what is about to be added -- computed first, so those files can be excluded
    # from the baseline below.
    if staged:
        changed = sh("git", "diff", "--cached", "--name-only", "--diff-filter=ACM", cwd=repo).split()
    else:
        changed = sh("git", "diff", "--name-only", "--diff-filter=ACM", base, cwd=repo).split()
        changed += [l[3:] for l in sh("git", "status", "--short", cwd=repo).splitlines()
                    if l.startswith("?? ")]
    under_test = set(changed)

    # how often the branch uses each apiVersion per kind, EXCLUDING the files under
    # test -- otherwise a merged defect is its own precedent.
    counts = collections.defaultdict(collections.Counter)
    files = sh("git", "ls-tree", "-r", "--name-only", base, cwd=repo).split()
    for f in files:
        if not f.endswith((".yaml", ".yml")): continue
        if f in under_test: continue
        for api, kind in kinds_in(sh("git", "show", "%s:%s" % (base, f), cwd=repo)):
            counts[kind][api] += 1

    bad = 0
    checked = 0
    for f in sorted(set(changed)):
        if not f.endswith((".yaml", ".yml")): continue
        p = os.path.join(repo, f)
        if not os.path.exists(p): continue
        for api, kind in kinds_in(open(p, encoding="utf-8", errors="replace").read()):
            if kind not in counts or not counts[kind]:
                continue                      # first of its kind here; nothing to compare
            checked += 1
            dominant, n = counts[kind].most_common(1)[0]
            if api != dominant:
                bad += 1
                mine = counts[kind].get(api, 0)
                print("!! %s" % f)
                print("   %s uses  %s  (%d other file(s) on %s use it)" % (kind, api, mine, base))
                print("   %s mostly uses %s  (%d file(s))" % (base, dominant, n))
                print("   full distribution: %s" % ", ".join(
                    "%s x%d" % (a, c) for a, c in counts[kind].most_common()))
    if bad:
        print("\n%d apiVersion disagreement(s). Confirm against the cluster before"
              "\noverriding: kubectl get crd <plural>.<group> -o "
              "jsonpath='{.spec.versions[?(@.served)].name}'" % bad)
        return 1
    print("apiVersions: %d checked against %s, all match the dominant version" % (checked, base))
    return 0

if __name__ == "__main__":
    sys.exit(main())
