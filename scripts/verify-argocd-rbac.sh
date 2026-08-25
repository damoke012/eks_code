#!/usr/bin/env bash
# INFRA-1639 -- read the RBAC policy Argo CD is ACTUALLY serving.
#
# A green Kustomization proves the manifest applied. It does not prove argocd-rbac-cm
# holds what you think, and it does not prove Argo reloaded it. This repo has been
# caught by that shape twice already (Wiz, QA etcd-backup): the adjacent step reports
# success about the step next to the one that matters.
#
# What this checks, in order:
#   1. the live policy.csv and scopes in argocd-rbac-cm
#   2. that every `g,` subject is the SAME KIND -- a file holding both a group object
#      ID and an app-role value has one subject that can never match, invisibly
#   3. that scopes names the claim those subjects live in
#   4. that argocd-server has seen the ConfigMap since it was last written
#
#   scripts/verify-argocd-rbac.sh op-dev
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BR="${1:-}"
case "$BR" in op-dev|op-qa|op-prod) : ;; *)
  echo "!! usage: $0 <op-dev|op-qa|op-prod>" >&2; exit 2 ;; esac

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib-onprem-ctx.sh"
onprem_resolve_ctx "$BR" || exit 1
K=(kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" -n argocd)

CSV=$("${K[@]}" get cm argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' 2>/dev/null || true)
SCOPES=$("${K[@]}" get cm argocd-rbac-cm -o jsonpath='{.data.scopes}' 2>/dev/null || true)
DEFAULT=$("${K[@]}" get cm argocd-rbac-cm -o jsonpath='{.data.policy\.default}' 2>/dev/null || true)

if [ -z "$CSV" ]; then
  echo "!! argocd-rbac-cm has an EMPTY policy.csv on $BR." >&2
  echo "   Every authenticated user lands with policy.default ('${DEFAULT}') and nothing else." >&2
  exit 1
fi

echo
echo "--- policy.csv, live on $BR ---"
printf '%s\n' "$CSV"
echo "--- scopes: ${SCOPES:-<unset, chart default [groups]>}"
echo "--- policy.default: '${DEFAULT}'"
echo

CSV="$CSV" SCOPES="$SCOPES" DEFAULT="$DEFAULT" BR="$BR" python3 <<'PY'
import os, re, sys
csv = os.environ["CSV"]; scopes = os.environ["SCOPES"]; br = os.environ["BR"]
GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
fail = []

subjects, roles = [], set()
for ln in csv.splitlines():
    st = ln.strip()
    if st.startswith("#") or not st:
        continue
    parts = [x.strip() for x in st.split(",")]
    if parts[0] == "g" and len(parts) >= 3:
        subjects.append(parts[1]); roles.add(parts[2])
    elif parts[0] == "p" and len(parts) >= 2:
        roles.discard(None)

if not subjects:
    fail.append("policy.csv has no `g,` subject at all -- nobody is mapped to any role")

kinds = {("group object ID" if GUID.match(s) else "app-role value") for s in subjects}
print("   subjects: %s" % ", ".join(subjects))
if len(kinds) > 1:
    fail.append("policy.csv MIXES subject kinds %s -- one of them can never match, and "
                "which one is invisible from the file" % sorted(kinds))
else:
    print("   all subjects are: %s" % kinds.pop())

# scopes must name the claim the subjects live in.
declared = [s.strip() for s in scopes.strip("[] ").split(",") if s.strip()] or ["groups"]
print("   scopes searched: %s" % ", ".join(declared))
if any(not GUID.match(s) for s in subjects) and "roles" not in declared:
    fail.append("subjects are app-role values but scopes does not name `roles` (%r) -- "
                "Argo never looks in that claim, so the policy cannot match" % scopes)
if all(GUID.match(s) for s in subjects) and "groups" not in declared:
    fail.append("subjects are group object IDs but scopes does not name `groups` (%r)" % scopes)

# Every role a subject is granted must actually have permissions defined, or be built in.
BUILTIN = {"role:admin", "role:readonly"}
granted = {p[2].strip() for p in (l.strip().split(",") for l in csv.splitlines())
           if len(p) >= 3 and p[0].strip() == "g"}
defined = {p[1].strip() for p in (l.strip().split(",") for l in csv.splitlines())
           if len(p) >= 2 and p[0].strip() == "p"}
for r in sorted(granted - defined - BUILTIN):
    fail.append("role %r is granted to a subject but has no `p,` rules and is not built in "
                "-- that subject authenticates and can do nothing" % r)

if fail:
    print()
    for f in fail:
        print("!! %s" % f, file=sys.stderr)
    sys.exit(1)
print("   OK: the policy Argo is serving on %s is internally consistent." % br)
PY

echo
echo "--- has argocd-server picked it up? ---"
# Argo watches the ConfigMap and reloads RBAC without a restart, so a pod OLDER than
# the ConfigMap is normal and fine. A pod that has not become Ready is not.
"${K[@]}" get pods -l app.kubernetes.io/name=argocd-server \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,START:.status.startTime' --no-headers
echo
echo "   Argo reloads argocd-rbac-cm without restarting, so an older pod is expected."
echo "   The only proof that remains is a human signing OUT and back IN:"
echo "     scripts/argocd-token-claims.sh $BR"
