#!/usr/bin/env bash
# INFRA-1636 -- the ApplicationSet on op-usxpress-prod.
#
# op-prod has NO ApplicationSet and no argocd-apps Kustomization, so it cannot
# generate an Application at all. INFRA-1650 delivers the Git credential; this
# delivers the thing that would use it. Both are needed and neither is sufficient.
#
# argocd-apps is kept SEPARATE from argocd-config on purpose: config is platform
# policy (AppProjects, the admin secret) and rarely changes, while apps churn as
# teams onboard. Separate Kustomizations mean an app mistake cannot roll back the
# guardrails. QA is wired this way; matching it is the point.
#
# That means TWO pull requests, in two repositories, and this script builds the
# first and prints the second. It does not pretend one is enough.
#
#   scripts/pr-argocd-applicationset-prod.sh
#   scripts/pr-argocd-applicationset-prod.sh --push
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSH="${1:-}"
BR=op-prod
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

# ---- what does the LIVE cluster already have? dependsOn that never satisfies is
# ---- a Kustomization stuck at "dependency not ready" forever, reported as a
# ---- reason about the dependency rather than about the wiring.
source "$SCRIPT_DIR/lib-onprem-ctx.sh"
if onprem_resolve_ctx "$BR" 2>/dev/null; then
  EXISTING=$(kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" -n flux-system \
             get kustomization -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort)
  echo "   flux Kustomizations live on $BR:"
  printf '%s\n' "$EXISTING" | sed 's/^/     /'
  for need in argocd-config app-namespaces; do
    printf '%s\n' "$EXISTING" | grep -qx "$need" \
      && echo "   ok   dependsOn '$need' exists" \
      || echo "   !!   dependsOn '$need' does NOT exist on $BR -- argocd-apps would sit at 'dependency not ready' forever"
  done
  printf '%s\n' "$EXISTING" | grep -qx "argocd-apps" \
    && echo "   note argocd-apps ALREADY exists -- the cluster-wiring PR may be unnecessary" \
    || echo "   note argocd-apps is absent -- the cluster-wiring PR below IS required"
else
  echo "   (cluster unreachable -- cannot check what argocd-apps will depend on)"
fi
echo

cd "$REPO"
git fetch -q origin
TOPIC="infra-1636-argocd-applicationset-$BR"
git checkout -q HEAD -- infrastructure 2>/dev/null || true
git clean -qfd infrastructure 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure
git clean -qfd infrastructure

python3 - <<'PY'
import glob, os, sys, yaml

BR="op-prod"; DIR="infrastructure/argocd-apps"

def load_all(p):
    t=open(p,encoding="utf-8",errors="replace").read()
    if "{{" in t and "kind: ExternalSecret" not in t: return []
    try: return [d for d in yaml.safe_load_all(t) if isinstance(d,dict)]
    except yaml.YAMLError: return []

# The Application's repoURL must byte-match whatever credential this branch carries.
# A `repository` credential matches on the EXACT url; an https:// Application against
# an ssh:// secret fails with `authentication required`, indistinguishable from having
# no credential -- 18 hours of dead QA delivery on 2026-08-20.
cred_url=None
for f in glob.glob("infrastructure/**/*.yaml", recursive=True):
    for d in load_all(f):
        if d.get("kind")!="ExternalSecret": continue
        tpl=((d.get("spec") or {}).get("target") or {}).get("template") or {}
        lab=(tpl.get("metadata") or {}).get("labels") or {}
        if lab.get("argocd.argoproj.io/secret-type")=="repository":
            u=(tpl.get("data") or {}).get("url")
            if u: cred_url=u; print("   credential on this branch: %s (%s)" % (u, f))
if not cred_url:
    cred_url="ssh://git@github.com/variant-inc/risingwave-pipeline.git"
    print("   no `repository` credential on %s yet -- INFRA-1650 has not landed." % BR)
    print("   using %s, which is what that PR will write. If 1650 lands with a" % cred_url)
    print("   different url, this ApplicationSet must be updated to match it EXACTLY.")

os.makedirs(DIR, exist_ok=True)
APPSET=os.path.join(DIR,"applicationset.yaml")
open(APPSET,"w").write("""# Every on-prem application delivered by Argo CD on PRODUCTION.
#
# Onboarding an app is four lines in `elements` below -- not a new file and not a
# new Kustomization. The ApplicationSet controller ships with the Argo CD stack.
#
# The `apps` AppProject restricts destinations to `app-*`, so nothing added here
# can target a platform namespace even by mistake.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: onprem-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - list:
        elements:
          # ---- onboard here ------------------------------------------------
          - name: risingwave-etl
            namespace: app-risingwave
            # MUST byte-match the `repository` credential's url. Argo matches a
            # per-repo credential on the exact string; an https:// Application
            # against an ssh:// secret fails with `authentication required`,
            # which is indistinguishable from having no credential at all.
            repoURL: %s
            path: deploy/overlays/prod
          # ------------------------------------------------------------------
  template:
    metadata:
      name: '{{.name}}'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: apps
      source:
        repoURL: '{{.repoURL}}'
        # The repository's ACTUAL default branch. risingwave-pipeline is `master`;
        # several variant-inc repos are. A wrong revision fails BEFORE
        # authentication, which masked a missing Git credential for a full day.
        targetRevision: master
        path: '{{.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.namespace}}'
      syncPolicy:
        syncOptions:
          - CreateNamespace=false     # the platform owns app-* namespaces
# NO `automated:` block, deliberately. Production syncs only when a human presses
# Sync, after the promotion PR bumping the digest has merged. Two gates, both
# recorded: the pull request, and the person who pressed it.
""" % cred_url)

open(os.path.join(DIR,"kustomization.yaml"),"w").write(
"apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - applicationset.yaml\n")
print("   added %s and its kustomization.yaml" % APPSET)

# ---------------------------------------------------------------------- assertions
d=[x for x in load_all(APPSET) if x.get("kind")=="ApplicationSet"][0]
sp=d["spec"]["template"]["spec"].get("syncPolicy") or {}
assert "automated" not in sp, "op-prod must have NO automated sync policy: %r" % sp
assert d["spec"]["template"]["spec"]["project"]=="apps", "project must be apps"
assert "CreateNamespace=false" in sp.get("syncOptions",[]), sp
for gen in d["spec"]["generators"]:
    for el in (gen.get("list") or {}).get("elements",[]):
        assert el["repoURL"]==cred_url, (el["repoURL"], cred_url)
        assert el["namespace"].startswith("app-"), el["namespace"]
        assert el["path"].endswith("/prod"), "prod ApplicationSet must use the prod overlay: %s" % el["path"]
print("   asserted: no automated sync, project=apps, CreateNamespace=false,")
print("             repoURL byte-matches the credential, destination is app-*, overlay is prod")
PY

LINT="$SCRIPT_DIR/lint-manifest-apiversions.py"
[ -f "$LINT" ] && { echo; python3 "$LINT" "$REPO" "$BR" || { echo "!! apiVersion disagreement" >&2; exit 1; }; }

echo
git add -A -- infrastructure
git --no-pager diff --cached -- infrastructure
if [ "$PUSH" != "--push" ]; then
  git reset -q -- infrastructure
  cat <<'NEXT'

   DRY RUN -- re-run with --push

   THE SECOND PULL REQUEST. This directory is inert until Flux is told to
   reconcile it. Add to iaac-talos-flux-cluster, master, the op-prod cluster's
   flux-system directory -- the block is in
   wip/onprem-app-cicd/platform/cluster-wiring-block.yaml:

     Kustomization/argocd-apps  path ./infrastructure/argocd-apps
       dependsOn: argocd-config (AppProjects must exist first)
                  app-namespaces (the destination namespace must exist first)

   If app-namespaces does not exist on op-prod, add that block too -- otherwise
   argocd-apps sits at "dependency not ready" indefinitely, and Flux reports that
   as a fact about the dependency rather than about the wiring.
NEXT
  exit 0
fi

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<'MD'
`op-usxpress-prod` has no ApplicationSet, so Argo CD there cannot generate an Application
at all. INFRA-1650 delivers the Git credential; this delivers the thing that would use it.
Neither is sufficient alone.

`argocd-apps` is deliberately separate from `argocd-config`: config is platform policy
(AppProjects, the admin secret) and rarely changes, while apps churn as teams onboard.
Separate Kustomizations mean an app mistake cannot roll back the guardrails. QA is wired
this way.

### Two things asserted before push

**No `automated:` block.** Production syncs only when a person presses Sync, after the
promotion pull request bumping the digest has merged. Two gates, both recorded: the PR and
the person.

**`repoURL` byte-matches the credential.** Argo CD matches a `secret-type: repository`
credential on the *exact* URL. An `https://` Application against an `ssh://` secret fails
with `authentication required` — indistinguishable from having no credential. That exact
reversion killed QA delivery for 18 hours on 2026-08-20 with every status field green.

### This PR is inert on its own

The directory needs a Flux Kustomization in `iaac-talos-flux-cluster` before anything
reconciles it, with `dependsOn: argocd-config, app-namespaces`. That is the companion PR.
MD
git commit -qm "INFRA-1636: ApplicationSet on op-usxpress-prod

op-prod had no ApplicationSet and no argocd-apps Kustomization, so Argo CD there could not
generate an Application at all. Kept separate from argocd-config deliberately, matching QA:
config is platform policy and rarely changes, apps churn, and separate Kustomizations mean
an app mistake cannot roll back the guardrails.

Asserted: no automated sync policy on prod, project=apps, CreateNamespace=false, the
destination is app-*, the overlay is prod, and the repoURL byte-matches the repository
credential on the branch -- a per-repo credential matches on the exact string, and the
https/ssh mismatch is what killed QA delivery for 18 hours on 2026-08-20.

Inert until the companion Kustomization lands in iaac-talos-flux-cluster."
git push -q -u origin "$TOPIC" --force-with-lease
gh pr create --base "$BR" --head "$TOPIC" \
  --title "INFRA-1636: ApplicationSet on op-usxpress-prod" --body-file "$BODY"
