#!/usr/bin/env bash
# INFRA-1639 -- unbreak op-qa. PR #135 added an ExternalSecret with the wrong
# apiVersion, into the wrong directory.
#
#   ExternalSecret/argocd/argocd-entra-oidc dry-run failed:
#   no matches for kind "ExternalSecret" in version "external-secrets.io/v1beta1"
#
# That failure holds the whole argocd Kustomization not-ready, and argocd-config
# and argocd-apps depend on it, so QA delivery is frozen until this lands.
#
# Two corrections, both taken FROM THE BRANCH rather than from dev:
#   1. apiVersion copied from op-qa's own existing ExternalSecret, not assumed.
#   2. the file moves to infrastructure/argocd-config/, where this branch already
#      keeps admin-externalsecret.yaml and repo-ssh-externalsecret.yaml. On op-dev
#      those live under infrastructure/argocd/; the branches differ, and I inferred
#      the layout from dev instead of reading op-qa.
#
#   scripts/pr-argocd-entra-fix-qa.sh
#   scripts/pr-argocd-entra-fix-qa.sh --push
set -euo pipefail
PUSH="${1:-}"
BR="op-qa"
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

cd "$REPO"
git fetch -q origin
TOPIC="infra-1639-argocd-entra-fix-$BR"
git checkout -q HEAD -- infrastructure 2>/dev/null || true
git clean -qfd infrastructure 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure
git clean -qfd infrastructure

python3 - <<'PY'
import os, yaml

OLD = "infrastructure/argocd/entra-oidc-externalsecret.yaml"
NEW = "infrastructure/argocd-config/entra-oidc-externalsecret.yaml"
REF = "infrastructure/argocd-config/admin-externalsecret.yaml"
KU_OLD = "infrastructure/argocd/kustomization.yaml"
KU_NEW = "infrastructure/argocd-config/kustomization.yaml"

assert os.path.exists(OLD), "%s not on the branch -- is #135 merged?" % OLD
assert os.path.exists(REF), "no reference ExternalSecret at %s" % REF

# The authoritative apiVersion is the one this branch already uses successfully.
ref = yaml.safe_load(open(REF))
api = ref["apiVersion"]
assert api.startswith("external-secrets.io/"), api
assert ref["kind"] == "ExternalSecret", ref["kind"]

doc = open(OLD).read()
assert "external-secrets.io/v1beta1" in doc, "expected the broken apiVersion in %s" % OLD
doc = doc.replace("apiVersion: external-secrets.io/v1beta1", "apiVersion: %s" % api)
os.makedirs(os.path.dirname(NEW), exist_ok=True)
open(NEW, "w").write(doc)
os.remove(OLD)
print("   apiVersion -> %s (copied from %s)" % (api, REF))
print("   moved to %s" % NEW)

base = os.path.basename(NEW)
# drop from the argocd kustomization
lines = [l for l in open(KU_OLD).readlines() if l.strip() != "- %s" % base]
open(KU_OLD, "w").writelines(lines)
assert base not in open(KU_OLD).read()

# add to the argocd-config kustomization
ku = open(KU_NEW).readlines()
if not any(l.strip() == "- %s" % base for l in ku):
    i = max(n for n, l in enumerate(ku) if l.startswith("  - "))
    ku.insert(i + 1, "  - %s\n" % base)
    open(KU_NEW, "w").writelines(ku)
print("   kustomization: removed from argocd, added to argocd-config")

# assert on the result
new = yaml.safe_load(open(NEW))
assert new["apiVersion"] == api, new["apiVersion"]
assert new["metadata"]["namespace"] == "argocd"
assert new["spec"]["data"][0]["remoteRef"]["key"] == "op-usxpress-qa/platform/argocd/azure-ad"
assert new["spec"]["target"]["template"]["metadata"]["labels"]["app.kubernetes.io/part-of"] == "argocd"
assert base in open(KU_NEW).read() and base not in open(KU_OLD).read()
assert not os.path.exists(OLD)

# the helmrelease reference must be untouched
hr = yaml.safe_load(open("infrastructure/argocd/helmrelease.yaml"))
o = yaml.safe_load(hr["spec"]["values"]["configs"]["cm"]["oidc.config"])
assert o["clientSecret"] == "$argocd-entra-oidc:client_secret", o.get("clientSecret")
PY

echo
git --no-pager diff -- infrastructure
git --no-pager status --short -- infrastructure
[ "$PUSH" = "--push" ] || { echo; echo "   DRY RUN -- re-run with --push"; exit 0; }

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<'MD'
Fixes the breakage introduced by #135.

```
ExternalSecret/argocd/argocd-entra-oidc dry-run failed:
no matches for kind "ExternalSecret" in version "external-secrets.io/v1beta1"
```

That holds the `argocd` Kustomization not-ready, and `argocd-config` and
`argocd-apps` both depend on it, so delivery on this cluster is frozen until this
merges.

Two mistakes, same cause — the file was written from what op-dev looks like rather
than from this branch:

* the apiVersion was assumed. It is now copied from this branch's own
  `admin-externalsecret.yaml`.
* the file was placed in `infrastructure/argocd/`. This branch keeps its
  ExternalSecrets in `infrastructure/argocd-config/`; op-dev keeps them under
  `infrastructure/argocd/`. Moved, and the two kustomizations updated.

Nothing else changes: the `$argocd-entra-oidc:client_secret` reference, the RBAC
rule and `oidc.config` are untouched.
MD
git add -A infrastructure
git commit -qm "INFRA-1639: fix the op-qa ExternalSecret apiVersion and location

#135 used external-secrets.io/v1beta1, which does not exist on this cluster, and
put the file under infrastructure/argocd where op-dev keeps its ExternalSecrets.
This branch keeps them in infrastructure/argocd-config. The apiVersion is now taken
from the branch's own working ExternalSecret."
git push -q -u origin "$TOPIC"
gh pr create --base "$BR" --head "$TOPIC" \
  --title "INFRA-1639: unbreak op-qa — ExternalSecret apiVersion and location" --body-file "$BODY"
