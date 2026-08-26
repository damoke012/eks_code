#!/usr/bin/env bash
# INFRA-1650 -- Argo CD Git credential + ApplicationSet on op-usxpress-prod.
#
# Why not the packaged version. wip/onprem-app-cicd/platform/argocd-config/op-prod/
# carries the GitHub App variant, which is blocked: the org App needs a variant-inc
# OWNER and dare-x is only a member (INFRA-1650's sibling, P3). Meanwhile
# applicationset-prod.yaml points at https://... So prod as packaged cannot
# authenticate, and has not been able to since the cluster came up.
#
# QA does not use the App. QA uses a repository DEPLOY KEY -- owned by the repo, no
# expiry, unaffected by offboarding, and creating one needs admin on that one repo
# rather than ownership of the org. Proven end to end on 2026-08-20. This mirrors it.
#
# THE TRAP THIS SCRIPT EXISTS TO PREVENT. A `secret-type: repository` credential
# matches an Application on the EXACT url. On 2026-08-20 a PR reverted the
# ApplicationSet's repoURL from ssh:// to https:// and nothing matched -- GitHub
# answers "Repository not found" for a private repo, which reads like deletion
# rather than auth, and Argo showed sync=Unknown health=Healthy from the previous
# day. 18 hours. So this asserts the two URLs are byte-identical before pushing.
#
#   scripts/pr-argocd-git-credential-prod.sh
#   scripts/pr-argocd-git-credential-prod.sh --push
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSH="${1:-}"
BR=op-prod
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
SSH_URL="ssh://git@github.com/variant-inc/risingwave-pipeline.git"
SM_KEY="op-usxpress-prod/platform/argocd"
SM_PROP="repo.risingwave-pipeline.sshPrivateKey"
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

cd "$REPO"
git fetch -q origin
TOPIC="infra-1650-argocd-git-credential-$BR"
git checkout -q HEAD -- infrastructure 2>/dev/null || true
git clean -qfd infrastructure 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure
git clean -qfd infrastructure

python3 - "$SSH_URL" "$SM_KEY" "$SM_PROP" <<'PY'
import glob, os, sys, yaml
SSH_URL, SM_KEY, SM_PROP = sys.argv[1:4]
BR = "op-prod"

def load_all(p):
    txt = open(p, encoding="utf-8", errors="replace").read()
    if "{{" in txt and "kind: ExternalSecret" not in txt:
        return []
    try:
        return [d for d in yaml.safe_load_all(txt) if isinstance(d, dict)]
    except yaml.YAMLError:
        return []

# ---------------------------------------------------- derive everything from the branch
es_files = [f for f in glob.glob("infrastructure/**/*.yaml", recursive=True)
            if "kind: ExternalSecret" in open(f, encoding="utf-8", errors="replace").read()]
assert es_files, "no ExternalSecret under infrastructure/ on %s" % BR
import collections
vers, stores = collections.Counter(), collections.Counter()
for f in es_files:
    for d in load_all(f):
        if d.get("kind") != "ExternalSecret": continue
        vers[d["apiVersion"]] += 1
        ref = (d.get("spec") or {}).get("secretStoreRef") or {}
        if ref.get("name"): stores[(ref.get("kind","ClusterSecretStore"), ref["name"])] += 1
ES_API = vers.most_common(1)[0][0]
ST_KIND, ST_NAME = stores.most_common(1)[0][0]
argocd_es = sorted(f for f in es_files if f.startswith("infrastructure/argocd"))
assert argocd_es, "no ExternalSecret under infrastructure/argocd* on %s" % BR
ES_DIR = os.path.dirname(argocd_es[0])
print("   ExternalSecrets: %s, %s, store %s/%s" % (ES_DIR, ES_API, ST_KIND, ST_NAME))

# ------------------------------------------------------------------ 1. the credential
ES_PATH = os.path.join(ES_DIR, "repo-ssh-externalsecret.yaml")
open(ES_PATH, "w").write("""# INFRA-1650 -- the Git credential Argo CD on op-prod reads variant-inc repositories
# with. Until this landed, prod held NO credential carrying the
# argocd.argoproj.io/secret-type label at all, so every Application pointing at an
# internal repository failed with `ComparisonError: authentication required`.
#
# DEPLOY KEY, not the org GitHub App. The App needs a variant-inc owner we do not
# have; a deploy key belongs to the REPOSITORY, never expires, survives offboarding,
# and needs admin on one repo rather than ownership of the org. This is the shape
# proven end to end on op-qa on 2026-08-20.
#
# The trade is scope: a deploy key is per-repository, so this is
# `secret-type: repository` with an EXACT url -- not `repo-creds` with a prefix.
# Onboarding application number two means another key and another file. The org App
# remains the target because it collapses that back to one object.
#
# The label is REQUIRED and ESO does not copy labels from the ExternalSecret to the
# Secret it creates -- set here, or the credential is created correctly and ignored.
#
# github.com's host key ships in the chart's argocd-ssh-known-hosts-cm; no
# known-hosts change is needed.
apiVersion: %s
kind: ExternalSecret
metadata:
  name: argocd-repo-risingwave-pipeline
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: %s
    name: %s
  target:
    name: argocd-repo-risingwave-pipeline
    creationPolicy: Owner
    template:
      engineVersion: v2
      metadata:
        labels:
          argocd.argoproj.io/secret-type: repository
      data:
        type: git
        url: %s
        sshPrivateKey: "{{ .sshPrivateKey }}"
  data:
    - secretKey: sshPrivateKey
      remoteRef:
        key: %s
        property: %s
""" % (ES_API, ST_KIND, ST_NAME, SSH_URL, SM_KEY, SM_PROP))
print("   added %s" % ES_PATH)

# ------------------------------------------------------- 2. the ApplicationSet repoURL
appsets = [f for f in glob.glob("infrastructure/**/*.yaml", recursive=True)
           if any(d.get("kind") == "ApplicationSet" for d in load_all(f))]
if not appsets:
    print("   !! no ApplicationSet on %s -- prod cannot generate Applications yet." % BR)
    print("      This PR delivers the credential only; the ApplicationSet is separate.")
    APPSET = None
else:
    APPSET = appsets[0]
    lines = open(APPSET).readlines()
    changed = 0
    for i, ln in enumerate(lines):
        if "repoURL:" in ln and "risingwave-pipeline" in ln and "ssh://" not in ln:
            ind = ln[:len(ln) - len(ln.lstrip())]
            key = "repoURL:" if "- repoURL:" not in ln else "- repoURL:"
            lines[i] = "%s%s %s\n" % (ind, key, SSH_URL)
            changed += 1
    if changed:
        open(APPSET, "w").writelines(lines)
        print("   %s: rewrote %d repoURL to ssh://" % (APPSET, changed))
    else:
        print("   %s: repoURL already ssh:// or not present" % APPSET)

# ------------------------------------------------------------------ 3. kustomization
KU = os.path.join(ES_DIR, "kustomization.yaml")
assert os.path.exists(KU), "no kustomization.yaml in %s" % ES_DIR
k = open(KU).read()
base = os.path.basename(ES_PATH)
if base not in k:
    assert "resources:" in k, "no resources: list in %s" % KU
    out = []
    for ln in k.split("\n"):
        out.append(ln)
        if ln.strip() == "resources:":
            out.append("  - %s" % base)
    open(KU, "w").write("\n".join(out))
    print("   listed %s in %s" % (base, KU))
else:
    print("   %s already listed" % base)

# ------------------------------------------------------------------------- assertions
e = yaml.safe_load(open(ES_PATH))
assert e["apiVersion"] == ES_API, e["apiVersion"]
lab = e["spec"]["target"]["template"]["metadata"]["labels"]
assert lab.get("argocd.argoproj.io/secret-type") == "repository", lab
cred_url = e["spec"]["target"]["template"]["data"]["url"]
assert cred_url == SSH_URL, cred_url
assert e["spec"]["data"][0]["remoteRef"]["key"] == SM_KEY

if APPSET:
    docs = [d for d in load_all(APPSET) if d.get("kind") == "ApplicationSet"]
    for d in docs:
        # THE assertion. A `repository` credential matches on the EXACT url; an
        # https:// Application against an ssh:// secret fails with `authentication
        # required`, which is indistinguishable from having no credential at all.
        for gen in d["spec"]["generators"]:
            for el in (gen.get("list") or {}).get("elements", []):
                u = el.get("repoURL")
                if u and "risingwave-pipeline" in u:
                    assert u == cred_url, (
                        "ApplicationSet repoURL %r does not byte-match the credential url %r "
                        "-- this is the 18-hour outage of 2026-08-20" % (u, cred_url))
        # prod must never sync itself.
        sp = d["spec"]["template"]["spec"].get("syncPolicy") or {}
        assert "automated" not in sp, \
            "op-prod ApplicationSet must have NO automated sync policy: %r" % sp
    print("   asserted: repoURL byte-matches the credential, and prod has no automated sync")
PY

LINT="$SCRIPT_DIR/lint-manifest-apiversions.py"
[ -f "$LINT" ] && { echo; python3 "$LINT" "$REPO" "$BR" || {
  echo "!! apiVersion disagreement -- not pushing." >&2; exit 1; }; }

echo
git add -A -- infrastructure
git --no-pager diff --cached -- infrastructure
if [ "$PUSH" != "--push" ]; then
  git reset -q -- infrastructure
  echo; echo "   DRY RUN -- re-run with --push"
  echo "   The credential VALUE must exist first:"
  echo "     aws secretsmanager get-secret-value --profile ops-controller --region us-east-2 \\"
  echo "       --secret-id $SM_KEY --query SecretString --output text | python3 -c 'import json,sys; print(\"$SM_PROP\" in json.load(sys.stdin))'"
  exit 0
fi

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<'MD'
Argo CD on `op-usxpress-prod` holds **no Git credential at all** — no secret in the
`argocd` namespace carries the `argocd.argoproj.io/secret-type` label. Every Application
pointing at an internal `variant-inc` repository therefore fails with
`ComparisonError: authentication required`.

### Deploy key, not the org GitHub App

The packaged prod manifests assume the org GitHub App. That App is still blocked — it needs
a `variant-inc` **owner**, and we only have member access. Meanwhile `applicationset-prod.yaml`
pointed at `https://`, so prod could not have authenticated even if the App existed.

A repository deploy key belongs to the **repository**: no expiry, unaffected by offboarding,
and creating one needs admin on that one repo rather than ownership of the org. This is the
shape proven end to end on op-qa on 2026-08-20.

The trade is scope — a deploy key is per-repository, so this is `secret-type: repository`
with an exact URL rather than `repo-creds` with a prefix. Application number two needs
another key. The org App remains the target because it collapses that back to one object.

### The `ssh://` change is the point, not incidental

A `repository` credential matches an Application on the **exact** URL. On 2026-08-20 a PR
reverted the QA ApplicationSet's `repoURL` from `ssh://` to `https://`; nothing matched,
GitHub answered *"Repository not found"* for a private repo — which reads like deletion
rather than auth — and Argo CD showed `sync=Unknown`, `health=Healthy` and
`operationState=Succeeded` from the previous day. QA delivery was dead for 18 hours with
every status field green.

The builder asserts the two URLs are byte-identical before pushing, and that the prod
ApplicationSet carries **no** `automated:` block — production syncs only when a person
presses Sync, after the promotion PR has merged.

### Before this can work

The deploy key must exist in Secrets Manager at `op-usxpress-prod/platform/argocd`,
property `repo.risingwave-pipeline.sshPrivateKey`, and its public half registered as a
**read-only** deploy key on `variant-inc/risingwave-pipeline`. A separate key from QA's, so
revoking one does not take the other down.

`SecretSynced` on the ExternalSecret proves the sync ran, not that the key works — confirm
the Application leaves `authentication required`.
MD
git commit -qm "INFRA-1650: Argo CD Git credential on op-prod, by deploy key

op-prod held no Git credential carrying the argocd.argoproj.io/secret-type label, so every
Application pointing at an internal variant-inc repository failed with 'authentication
required'.

Uses a repository deploy key rather than the org GitHub App, which is still blocked on a
variant-inc owner. Mirrors the shape proven on op-qa on 2026-08-20.

The ApplicationSet's repoURL moves to ssh:// to byte-match the credential. A 'repository'
credential matches on the EXACT url, and an https:// Application against an ssh:// secret
fails indistinguishably from having no credential -- that reversion cost QA 18 hours on
2026-08-20 with every status field green. Asserted before push, along with the absence of
an automated sync policy on prod."
git push -q -u origin "$TOPIC" --force-with-lease
gh pr create --base "$BR" --head "$TOPIC" \
  --title "INFRA-1650: Argo CD Git credential on op-prod, by deploy key" --body-file "$BODY"
