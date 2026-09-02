#!/usr/bin/env bash
# Add role:app-operator to Argo CD's policy.csv on all three on-prem cluster branches.
#
# WHY a second role. role:app-viewer is read + logs, plus sync on dev/QA only. Doke's
# call on 2026-09-02: the application team operates its own pipeline everywhere, so
# app-operator adds sync on PROD as well, plus the two permissions a pod restart
# actually needs:
#
#   applications, action/*  -- the Restart button on a Deployment/StatefulSet
#   applications, delete    -- deleting a Pod resource, which is the other way people
#                              restart something, and is a DIFFERENT verb from the
#                              application-level delete. Scoped to the project, so it
#                              cannot delete an Application, only resources inside one.
#
# Subjects are Entra app-role VALUES, not group object IDs — this tenant emits no
# groups claim. usx-argocd-operator is assigned to the app-operator role, so every
# member of that group carries `app-operator` in the roles claim.
#
#   scripts/pr-argocd-rbac-operator.sh              # write branches locally, no push
#   scripts/pr-argocd-rbac-operator.sh --push       # push and open PRs
#   scripts/pr-argocd-rbac-operator.sh --only op-dev
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
ROLE_VALUE="app-operator"
PUSH="no"; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH="yes"; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --role-value) ROLE_VALUE="$2"; shift 2 ;;
    *) echo "usage: $0 [--push] [--only op-dev|op-qa|op-prod]" >&2; exit 2 ;;
  esac
done

[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO   (set REPO=)" >&2; exit 2; }
cd "$REPO"
git fetch -q origin

BRANCHES="op-dev op-qa op-prod"
[ -z "$ONLY" ] || BRANCHES="$ONLY"
TOPIC_BASE="feat/argocd-rbac-app-operator"

for BR in $BRANCHES; do
  echo "== $BR"
  TOPIC="$TOPIC_BASE-$BR"
  git checkout -q -B "$TOPIC" "origin/$BR"

  HR="infrastructure/argocd/helmrelease.yaml"
  [ -f "$HR" ] || { echo "   !! $HR not found on $BR — skipping" >&2; continue; }

  python3 - "$HR" "$ROLE_VALUE" <<'PY'
import re, sys
path, role = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(keepends=True)

key = None
for i, ln in enumerate(lines):
    if ln.strip().startswith("policy.csv:") and ln.rstrip().endswith("|"):
        key = i; break
assert key is not None, "no 'policy.csv: |' block in %s" % path

body_indent = None
end = key + 1
for i in range(key + 1, len(lines)):
    ln = lines[i]
    if not ln.strip():
        end = i + 1; continue
    ind = len(ln) - len(ln.lstrip())
    if body_indent is None:
        body_indent = ind
    if ind < body_indent:
        break
    end = i + 1
assert body_indent is not None, "policy.csv block is empty in %s" % path

existing = "".join(lines[key + 1:end])
if "role:%s" % role in existing:
    print("   role:%s already present, leaving alone" % role); sys.exit(3)

# The project must be the SAME one app-viewer is scoped to. Read it off this branch
# rather than assuming a name — the branches are not identical.
m = re.search(r"role:app-viewer,\s*applications,\s*get,\s*([^/]+)/\*", existing)
assert m, ("no role:app-viewer line to read the AppProject from in %s -- land the "
           "viewer role first so both roles are scoped the same way" % path)
proj = m.group(1).strip()

pad = " " * body_indent
add = [
    "# The application-team OPERATOR role. Same project as app-viewer (%s), and\n" % proj,
    "# deliberately wider: sync on every environment including prod, plus the two\n",
    "# permissions a pod restart needs. Doke's call, 2026-09-02.\n",
    "p, role:%s, applications, get,      %s/*, allow\n" % (role, proj),
    "p, role:%s, logs,         get,      %s/*, allow\n" % (role, proj),
    "p, role:%s, applications, sync,     %s/*, allow\n" % (role, proj),
    "# action/* is the Restart button; delete here is RESOURCE delete (a Pod), scoped\n",
    "# to this project -- it cannot delete an Application.\n",
    "p, role:%s, applications, action/*, %s/*, allow\n" % (role, proj),
    "p, role:%s, applications, delete,   %s/*, allow\n" % (role, proj),
    "# Subject is an Entra APP ROLE value. usx-argocd-operator is assigned to it, so\n",
    "# group membership is what actually grants this.\n",
    "g, %s, role:%s\n" % (role, role),
]
out = lines[:end] + [pad + a for a in add] + lines[end:]
open(path, "w").write("".join(out))

# Read back. Every subject in a `g,` line must be the same KIND -- a file mixing a
# group object ID with a role value has one subject that can never match, and which
# one is invisible from the file.
import yaml
cfg = yaml.safe_load(open(path))
csv = None
def find(d):
    global csv
    if isinstance(d, dict):
        for k, v in d.items():
            if k == "policy.csv": csv = v
            else: find(v)
    elif isinstance(d, list):
        for v in d: find(v)
find(cfg)
assert csv, "policy.csv not readable after edit"
assert "g, %s, role:%s" % (role, role) in csv
assert "p, role:%s, applications, action/*, %s/*, allow" % (role, proj) in csv
GUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
kinds = set()
for ln in csv.splitlines():
    st = ln.strip()
    if not st.startswith("g,"): continue
    parts = [x.strip() for x in st.split(",")]
    if len(parts) == 3:
        kinds.add("guid" if GUID.match(parts[1]) else "value")
assert len(kinds) <= 1, ("policy.csv mixes subject kinds %s -- one of them matches "
                         "nothing and the file does not say which" % kinds)
print("   added role:%s scoped to %s" % (role, proj))
PY
  rc=$?
  [ $rc -eq 3 ] && { echo "   nothing to do"; continue; }
  [ $rc -eq 0 ] || { echo "   !! edit failed on $BR" >&2; exit 1; }

  git add "$HR"
  git commit -q -m "argocd: add role:app-operator (sync + pod restart) on $BR

The application team operates its own pipeline on every environment, production
included. app-viewer stays read-only plus dev/QA sync for people who only need
visibility.

Subject is the Entra app-role value; usx-argocd-operator
(984faf3e-e280-490e-8ff4-a71101a73a95) is assigned to it, so membership of that group
is what grants this.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
  echo "   committed on $TOPIC"

  if [ "$PUSH" = "yes" ]; then
    git push -q -u origin "$TOPIC"
    gh pr create --base "$BR" --head "$TOPIC" \
      --title "argocd: role:app-operator — sync and pod restart for the app team ($BR)" \
      --body-file <(printf '%s\n' \
        "Adds \`role:app-operator\` to Argo CD's policy.csv on \`$BR\`." \
        "" \
        "Read, logs, sync, \`action/*\` (the Restart button) and resource-level delete," \
        "all scoped to the same AppProject \`role:app-viewer\` already uses." \
        "" \
        "Subject is the Entra app-role value, not a group object ID — this tenant emits" \
        "no groups claim. The group \`usx-argocd-operator\` is assigned to the" \
        "\`app-operator\` app role, so membership of that group is the access." \
        "" \
        "Members today: Timothy Preble, Pujit Koirala." \
        "" \
        "🤖 Generated with [Claude Code](https://claude.com/claude-code)") \
      && echo "   PR opened" || echo "   !! gh pr create failed"
  fi
done

git checkout -q - 2>/dev/null || true
[ "$PUSH" = "yes" ] || echo
[ "$PUSH" = "yes" ] || echo "Branches written locally, nothing pushed. Re-run with --push to open PRs."
