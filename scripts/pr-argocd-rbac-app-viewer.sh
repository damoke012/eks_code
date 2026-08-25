#!/usr/bin/env bash
# INFRA-1639 -- give an application team a read-only (dev/QA: syncable) view of its
# own Argo CD project, without giving it the cluster.
#
# Today policy.csv on op-dev and op-qa maps exactly one subject -- the platform admin
# group -- to role:admin, and policy.default is "". An app-team member who authenticates
# through Entra therefore lands on an empty Applications screen. That is the whole of
# what the RisingWave team sees.
#
# THIS PR IS INERT UNTIL ENTRA EMITS A groups CLAIM. It is still worth landing first:
# when the claim starts arriving the view is already there, and nobody has to guess
# whether the silence is authentication or authorisation. See
# wip/onprem-argocd/FINDINGS-2026-08-25-entra-oidc.md.
#
#   scripts/pr-argocd-rbac-app-viewer.sh --group 00000000-0000-0000-0000-000000000000
#   scripts/pr-argocd-rbac-app-viewer.sh --group <objectId> --push
set -euo pipefail
# Resolve before ANY cd -- three scripts have looked up a sibling relatively after
# cd-ing into the platform repo, and each failure read as "the cluster is unreachable".
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
GROUP=""; PUSH="no"; ONLY=""; PROJECT=""; ROLE_VALUE=""
# When the subject is a role value, the EXISTING admin line -- keyed on a group
# object ID -- matches nothing, because this tenant emits no groups claim. Shipping
# it would leave a policy.csv where one of two subjects is silently dead, which is
# the failure this whole exercise has been about. So it is rekeyed, not optional:
# an opt-out flag existed briefly and could only ever produce a config the
# same-kind invariant below rejects.
ADMIN_ROLE_VALUE="platform-admin"
while [ $# -gt 0 ]; do
  case "$1" in
    --group)   GROUP="$2";   shift 2 ;;
    # If the groups claim never arrives and we go the app-role route instead
    # (scripts/entra-argocd-app-roles.sh), the subject is the role VALUE, not an
    # object ID, and scopes has to name the roles claim or Argo never looks there.
    --role-value) ROLE_VALUE="$2"; shift 2 ;;
    --admin-role-value) ADMIN_ROLE_VALUE="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --only)    ONLY="$2";    shift 2 ;;
    --repo)    REPO="$2";    shift 2 ;;
    --push)    PUSH="yes";   shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# The subject must be an object ID, and this is the third system in which an
# identity NAME has failed to cross a boundary. Entra emits a group's display
# name only for AD-synced groups (and only when optionalClaims asks for
# sam_account_name); for a cloud-only group the object ID is the ONLY thing that
# can ever appear in the claim. usx-cloud-admin is cloud-only, which is why
# PR #132 rekeyed policy.csv to a GUID.
# ---------------------------------------------------------------------------
GUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [ -n "$ROLE_VALUE" ]; then
  [ -z "$GROUP" ] || { echo "!! --group and --role-value are alternatives, not both" >&2; exit 2; }
  [[ "$ROLE_VALUE" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "!! '$ROLE_VALUE' is not a plausible app-role value" >&2; exit 2; }
  echo "   subject: app-role value '$ROLE_VALUE' (scopes will be set to [roles, groups])"
  echo "   admin subject: rekeyed to app-role value '$ADMIN_ROLE_VALUE'"
  GROUP="$ROLE_VALUE"
elif [ -z "$GROUP" ]; then
  cat >&2 <<'MSG'
!! --group is required: the Entra object ID of the application team's group.

   A display name will NOT do. Entra emits display names only for AD-synced
   groups; for a cloud-only group the object ID is the only subject that can
   appear in the claim, and a policy.csv line that never matches produces a
   successful login with no permissions -- indistinguishable from the bug we
   are already chasing.

   Find it with:
     az ad group list --display-name 'RisingWave Platform' \
       --query '[].{name:displayName,id:id,synced:onPremisesSyncEnabled}' --output table
MSG
  exit 2
fi
[ -n "$ROLE_VALUE" ] || [[ "$GROUP" =~ $GUID_RE ]] || {
  echo "!! '$GROUP' is not an object ID. See --group above." >&2; exit 2; }

# Prove the group exists before writing a policy that maps it.
if [ -z "$ROLE_VALUE" ] && command -v az >/dev/null 2>&1; then
  INFO=$(az ad group show --group "$GROUP" \
           --query '{name:displayName,synced:onPremisesSyncEnabled}' --output json 2>&1) || {
    echo "!! az could not read group $GROUP:" >&2
    printf '   %s\n' "$(printf '%s' "$INFO" | head -2)" >&2
    echo "   Refusing to map a group that cannot be read." >&2; exit 1; }
  NAME=$(printf '%s' "$INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
  SYNCED=$(printf '%s' "$INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin)["synced"])')
  echo "   group verified: $NAME ($GROUP)  onPremisesSyncEnabled=$SYNCED"
  [ "$SYNCED" = "True" ] && cat <<'NOTE'
   note: this group IS AD-synced, so Entra COULD emit its on-prem name instead of
         the object ID if optionalClaims asked for sam_account_name. It does not
         today, and the object ID is emitted for every group type -- so the GUID
         is the safe subject either way.
NOTE
elif [ -z "$ROLE_VALUE" ]; then
  echo "   (az not on PATH -- NOT verifying the group exists. Run this on WSL.)"
fi

[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }
cd "$REPO"
git fetch -q origin

BRANCHES="op-dev op-qa op-prod"
[ -z "$ONLY" ] || BRANCHES="$ONLY"

clean() { git checkout -q HEAD -- infrastructure 2>/dev/null || true
          git clean -qfd infrastructure 2>/dev/null || true; }
trap clean EXIT

for BR in $BRANCHES; do
  echo; echo "################ $BR ################"
  clean
  TOPIC="infra-1639-argocd-app-viewer-$BR"
  git checkout -q -B "$TOPIC" "origin/$BR"
  git checkout -q "origin/$BR" -- infrastructure
  git clean -qfd infrastructure

  HR="infrastructure/argocd/helmrelease.yaml"
  [ -f "$HR" ] || { echo "!! $HR missing on $BR -- skipping" >&2; continue; }

  # The rbac block has to exist already. On op-prod it arrives with
  # pr-argocd-entra-prod.sh; running this first would either no-op silently or
  # invent a block whose surrounding values (url, admin.enabled) were never set.
  if ! python3 -c "
import yaml,sys
d=yaml.safe_load(open('$HR'))
sys.exit(0 if 'rbac' in d['spec']['values']['configs'] else 1)"; then
    echo "!! $BR has no configs.rbac yet -- land the Entra OIDC PR for this branch first." >&2
    echo "   (op-prod: scripts/pr-argocd-entra-prod.sh)" >&2
    continue
  fi

  # Derive the project from the branch. 'apps' is what op-qa uses, but PLATFORM-CICD-FOR-APPS
  # already flags that prod may not have the same AppProject, and hard-coding it is exactly
  # the class of copy that froze op-qa delivery.
  if [ -n "$PROJECT" ]; then PROJ="$PROJECT"
  else
    PROJ=$(python3 - "$BR" <<'PY'
import glob, sys, yaml
names = []
for p in glob.glob("infrastructure/**/appprojects.yaml", recursive=True):
    for d in yaml.safe_load_all(open(p)):
        if d and d.get("kind") == "AppProject":
            n = d["metadata"]["name"]
            if n != "default":
                names.append(n)
if len(names) != 1:
    sys.stderr.write("!! expected exactly one non-default AppProject on %s, found %r\n"
                     % (sys.argv[1], sorted(set(names))))
    sys.stderr.write("   pass --project <name> to pin it.\n")
    sys.exit(1)
print(names[0])
PY
) || continue
  fi
  echo "   project: $PROJ"

  # dev and QA: the team may sync. prod: read-only -- promotion to prod is
  # human-initiated by the platform, by design (CICD-STANDARD-AND-STATE-2026-08-25 §1).
  case "$BR" in
    op-prod) SYNC="no" ;;
    *)       SYNC="yes" ;;
  esac
  echo "   sync permission: $SYNC"

  python3 - "$HR" "$GROUP" "$PROJ" "$SYNC" "$BR" "$ROLE_VALUE" "$ADMIN_ROLE_VALUE" <<'PY'
import sys, yaml, re
path, group, proj, sync, br, role_value, admin_role_value = sys.argv[1:8]
GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

lines = open(path).readlines()

# locate the policy.csv block scalar and its content indent
key = None
for i, ln in enumerate(lines):
    if ln.strip().startswith("policy.csv:") and ln.rstrip().endswith("|"):
        key = i; break
assert key is not None, "no 'policy.csv: |' block in %s" % path
key_indent = len(lines[key]) - len(lines[key].lstrip())

end = len(lines)
for j in range(key + 1, len(lines)):
    s = lines[j]
    if not s.strip():
        continue
    if len(s) - len(s.lstrip()) <= key_indent:
        end = j; break
body_indent = None
for j in range(key + 1, end):
    if lines[j].strip():
        body_indent = len(lines[j]) - len(lines[j].lstrip()); break
assert body_indent is not None, "policy.csv block is empty in %s" % path

existing = "".join(lines[key + 1:end])
if "role:app-viewer" in existing:
    print("   role:app-viewer already present, leaving alone"); sys.exit(3)

pad = " " * body_indent
add = [
    "# INFRA-1639 -- the application-team view. Scoped to the %s project, not */*:\n" % proj,
    "# a team sees its own Applications and nothing else on the cluster.\n",
    "p, role:app-viewer, applications, get,  %s/*, allow\n" % proj,
    "p, role:app-viewer, logs,         get,  %s/*, allow\n" % proj,
]
if sync == "yes":
    add.append("p, role:app-viewer, applications, sync, %s/*, allow\n" % proj)
else:
    add.append("# no sync on prod: promotion is human-initiated by the platform, by design.\n")
add += [
]
if role_value:
    add += [
        "# Subject is an Entra APP ROLE value, not a group. The roles claim is issued\n",
        "# from appRoleAssignments, a different path from directory group membership --\n",
        "# which is why it survives whatever suppresses the groups claim in this tenant.\n",
        "g, %s, role:app-viewer\n" % group,
    ]
else:
    add += [
        "# Subject is an Entra OBJECT ID. A display name is emitted only for AD-synced\n",
        "# groups, so a name here would silently match nothing.\n",
        "g, %s, role:app-viewer\n" % group,
    ]

out = lines[:end] + [pad + a for a in add] + lines[end:]

if role_value:
    rekeyed = 0
    for i, ln in enumerate(out):
        st = ln.strip()
        if not st.startswith("g,"):
            continue
        parts = [x.strip() for x in st.split(",")]
        if len(parts) == 3 and parts[2] == "role:admin" and GUID.match(parts[1]):
            ind = " " * (len(ln) - len(ln.lstrip()))
            out[i] = (ind + "# was the group object ID %s. Rekeyed 2026-08-25: this\n" % parts[1]
                      + ind + "# tenant emits no groups claim, so that subject matched nothing.\n"
                      + ind + "g, %s, role:admin\n" % admin_role_value)
            rekeyed += 1
    # 0 is the ALREADY-CORRECT state, not a failure. op-prod's Entra PR emits the
    # app-role subject directly, so there is nothing to rekey there -- while op-dev
    # and op-qa, built before we knew the tenant emits no groups claim, each have
    # exactly one. Demanding 1 made the finished state look broken.
    # More than one is genuinely ambiguous and still refuses.
    assert rekeyed <= 1, ("found %d group-keyed admin lines -- resolve by hand rather "
                          "than guessing which is authoritative" % rekeyed)
    print("   admin line: %s" % ("rekeyed to %s" % admin_role_value if rekeyed
                                 else "already an app-role value, nothing to rekey"))

if role_value:
    # Argo only looks in the claims that scopes names. Leaving it '[groups]' while
    # the subject is a role value is a policy that can never match -- the exact
    # failure we are already routing around.
    for i, ln in enumerate(out):
        if ln.strip().startswith("scopes:"):
            ind = " " * (len(ln) - len(ln.lstrip()))
            out[i] = ind + 'scopes: "[roles, groups]"\n'
            break
open(path, "w").writelines(out)

# --- parse back -------------------------------------------------------------
d = yaml.safe_load(open(path))
cfg = d["spec"]["values"]["configs"]
csv = cfg["rbac"]["policy.csv"]
assert "g, %s, role:app-viewer" % group in csv, csv
assert "p, role:app-viewer, applications, get,  %s/*, allow" % proj in csv, csv
assert "p, role:app-viewer, logs,         get,  %s/*, allow" % proj in csv, csv
# Count the actual grants rather than substring-testing the text we just wrote.
# The first version of this assertion could only ever pass -- it tested the string
# in the branch that never produces it, which is the adjacent-step green signal
# this repo keeps logging.
viewer_sync = [l for l in csv.splitlines()
               if l.strip().startswith("p,") and "role:app-viewer" in l and ", sync," in l]
if sync == "yes":
    assert len(viewer_sync) == 1, "expected exactly one sync grant, got %r" % viewer_sync
else:
    assert not viewer_sync, "%s must not grant sync to role:app-viewer: %r" % (br, viewer_sync)

# policy.default must NOT have been widened -- the whole point is that merely
# authenticating grants nothing.
assert cfg["rbac"]["policy.default"] == "", repr(cfg["rbac"]["policy.default"])
# and the admin mapping that was already there must survive this edit
assert "role:admin" in csv, "the existing admin mapping was lost: %r" % csv
# Every `g,` subject must be the same KIND. A policy.csv holding both a group
# object ID and an app-role value means one of them can never match, and which one
# is invisible from the file. Two subjects, one silently dead, is the failure this
# whole exercise has been about.
subjects = [l.strip().split(",")[1].strip() for l in csv.splitlines()
            if l.strip().startswith("g,") and len(l.strip().split(",")) >= 3]
kinds = {("guid" if GUID.match(x) else "role-value") for x in subjects}
assert len(kinds) == 1, (
    "policy.csv mixes subject kinds %s across %r -- one of them matches nothing"
    % (sorted(kinds), subjects))
print("   subjects: %s, all %s" % (", ".join(subjects), kinds.pop()))

want_scopes = "[roles, groups]" if role_value else "[groups]"
assert cfg["rbac"].get("scopes") == want_scopes, \
    "scopes must be %r or the subject is never read: %r" % (want_scopes, cfg["rbac"].get("scopes"))
print("   parsed back: role:app-viewer on %s/* | admin mapping intact | policy.default ''" % proj)
PY
  rc=$?
  [ $rc -eq 3 ] && continue
  [ $rc -eq 0 ] || exit $rc

  git add -A infrastructure/argocd
  echo; echo "-------- git diff origin/$BR --------"
  git --no-pager diff --cached "origin/$BR"
  echo "-------- end --------"

  if [ "$PUSH" != "yes" ]; then
    git reset -q; echo "   DRY RUN -- re-run with --push"; continue
  fi

  git commit -q -m "INFRA-1639: an application-team view in Argo CD on $BR

policy.csv maps one subject today -- the platform admin group -- and policy.default
is \"\", so an application-team member who authenticates through Entra lands on an
empty Applications screen with no way to tell authentication from authorisation.

Adds role:app-viewer scoped to the $PROJ project: get on applications and logs,
$( [ "$SYNC" = yes ] && echo "plus sync" || echo "and deliberately NOT sync -- promotion to prod stays human-initiated by the platform" ).

The subject is an Entra object ID. Entra emits a display name only for AD-synced
groups, so a name would match nothing while looking correct.

Inert until Entra emits a groups claim at all, which it currently does not for this
application -- see wip/onprem-argocd/FINDINGS-2026-08-25-entra-oidc.md. Landing it
first means that when the claim arrives the view is already there."
  git push -q -u origin "$TOPIC" --force-with-lease
  echo "   pushed $TOPIC"
  gh pr create --base "$BR" --head "$TOPIC" \
    --title "INFRA-1639: an application-team view in Argo CD on $BR" \
    --body "See the commit message. Inert until Entra emits a \`groups\` claim; landing it first means the view exists the moment the claim arrives." \
    || echo "   (PR may already exist)"
done
