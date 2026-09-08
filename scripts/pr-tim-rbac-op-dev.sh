#!/usr/bin/env bash
# Land Tim's namespace RoleBindings on the op-dev branch.
#
# scripts/wizard-onboard-tim-op-dev.sh applied them live so he is unblocked. They are
# not in Git, and op-usxpress-dev is rebuilt to validate -- a hand-applied binding does
# not survive that. This is the INFRA-1589 lesson and it has cost us before.
#
# Builds the PR FROM THE BRANCH, never from a wip/ copy (CLAUDE.md rule 7): on
# 2026-08-20 a PR assembled by copying a stale wip/ file over the branch silently
# reverted an ApplicationSet's Git URL and broke delivery for 18 hours, green throughout.
#
#   scripts/pr-tim-rbac-op-dev.sh              # dry run, prints the diff
#   scripts/pr-tim-rbac-op-dev.sh --push
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # resolve before any cd

REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
FROM="${FROM:-$HOME/onprem-access/timothy-preble/rolebindings-timothy-preble.yaml}"
CN="timothy-preble"; DIR=""; PUSH="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --dir)  DIR="$2";  shift 2 ;;
    --push) PUSH="yes"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f "$FROM" ] || { echo "!! no manifest at $FROM -- run the wizard first" >&2; exit 2; }
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

# ---- validate the SOURCE before touching the branch -------------------------
# The point of this grant is its boundary. A ClusterRoleBinding here would hand Tim
# the cluster while every message about it still said "namespace only".
python3 - "$FROM" "$CN" <<'PY'
import sys, yaml
path, cn = sys.argv[1], sys.argv[2]
docs = [d for d in yaml.safe_load_all(open(path)) if d]
kinds = {d.get("kind") for d in docs}
assert kinds == {"RoleBinding"}, \
    "expected only RoleBinding, found %s -- refusing to widen the grant" % sorted(kinds)
ns = sorted(d["metadata"]["namespace"] for d in docs)
assert ns == ["risingwave", "risingwave-2"], "unexpected namespaces: %s" % ns
for d in docs:
    r = d["roleRef"]
    assert (r["kind"], r["name"]) == ("ClusterRole", "admin"), r
    subs = d["subjects"]
    assert len(subs) == 1 and subs[0]["kind"] == "User" and subs[0]["name"] == cn, subs
print("   source ok: 2 RoleBindings, User %s, ClusterRole admin, namespaces %s" % (cn, ns))
PY

cd "$REPO"
if [ -n "$(git status --porcelain)" ]; then
  echo "!! $REPO has uncommitted changes. Commit or stash them first." >&2
  git --no-pager status --short >&2; exit 2
fi
git fetch -q origin
BR=op-dev                              # branch-per-cluster; op-dev is this cluster's
git rev-parse --verify -q "origin/$BR" >/dev/null || {
  echo "!! origin/$BR does not exist -- is $REPO really iaac-talos-flux-platform?" >&2; exit 1; }
TOPIC="tim-rbac-op-dev"
git checkout -q -B "$TOPIC" "origin/$BR"

# ---- find where RBAC already lives, rather than guessing a path -------------
if [ -z "$DIR" ]; then
  CANDS=$(grep -rl --include='*.yaml' -e 'kind: RoleBinding' -e 'kind: ClusterRoleBinding' . \
          | grep -v '^./.git' | xargs -r -n1 dirname | sort -u)
  N=$(printf '%s\n' "$CANDS" | grep -c . || true)
  if [ "$N" = "1" ]; then
    DIR="$CANDS"
  else
    # Listing nine paths and saying "pick one" leaves the operator guessing, which is
    # the thing this refusal exists to prevent. Show the evidence that distinguishes
    # them: a component's own RBAC binds ServiceAccounts, a people directory binds
    # Users and Groups. Ours is a User binding.
    echo "!! found $N directories already holding RBAC on origin/$BR." >&2
    echo "   Ours binds a User, so the directory that already binds Users/Groups is" >&2
    echo "   the one to join; the rest are each a component's own ServiceAccount RBAC." >&2
    echo >&2
    printf '   %-42s %6s %6s\n' "directory" "user" "svcacct" >&2
    while read -r d; do
      [ -n "$d" ] || continue
      u=$(grep -rl --include='*.yaml' -e 'kind: User' -e 'kind: Group' "$d" 2>/dev/null | wc -l | tr -d ' ')
      a=$(grep -rl --include='*.yaml' 'kind: ServiceAccount' "$d" 2>/dev/null | wc -l | tr -d ' ')
      mark=" "; [ "$u" -gt 0 ] && [ "$a" -eq 0 ] && mark="*"
      printf ' %s %-42s %6s %6s\n' "$mark" "$d" "$u" "$a" >&2
    done <<< "$CANDS"
    echo >&2
    echo "   * = binds people and no ServiceAccounts. Re-run with --dir <path>." >&2
    exit 1
  fi
fi
[ -d "$DIR" ] || { echo "!! $DIR is not a directory on origin/$BR" >&2; exit 1; }
echo "   destination: $DIR"

FILE="$DIR/rolebinding-risingwave-$CN.yaml"
cp "$FROM" "$FILE"

# ---- enumerate it, or Flux will not apply it --------------------------------
# A file dropped into a Flux directory applies only if that directory's
# kustomization.yaml lists it. velero and risingwave-routes enumerate; istio-ingress
# does not. Getting this wrong produces a merged PR that changes nothing, green.
KUS="$DIR/kustomization.yaml"
BASE=$(basename "$FILE")
if [ -f "$KUS" ]; then
  if grep -qE '^resources:' "$KUS"; then
    # Match the existing list's indentation. A hardcoded "- " at column 0 appended
    # under an INDENTED list is not a cosmetic difference -- it is invalid YAML and
    # breaks the entire kustomization. Observed doing exactly that on 2026-09-08.
    IND=$(awk '/^resources:/{f=1;next} f && /^[[:space:]]*-/{match($0,/^[[:space:]]*/); print substr($0,1,RLENGTH); exit}' "$KUS")
    [ -n "$IND" ] || IND="  "
    grep -qF "$BASE" "$KUS" || printf '%s- %s\n' "$IND" "$BASE" >> "$KUS"
    # Assert by PARSING it back, not by grepping the text we just wrote. A grep
    # passes happily on a file no YAML parser will accept.
    python3 - "$KUS" "$BASE" <<'PYK'
import sys, yaml
kus, base = sys.argv[1], sys.argv[2]
try:
    d = yaml.safe_load(open(kus))
except Exception as e:
    sys.exit("!! %s is not valid YAML after the edit: %s" % (kus, e))
res = (d or {}).get("resources") or []
if base not in res:
    sys.exit("!! %s parsed, but %s is not in resources: %s" % (kus, base, res))
print("   enumerated in %s (parsed back: %d resources)" % (kus, len(res)))
PYK
  else
    echo "   $KUS has no resources: list -- it does not enumerate; nothing to add"
  fi
else
  echo "   no kustomization.yaml in $DIR"
  echo "   ⚠ confirm the parent Kustomization reads this directory, or the file is inert."
fi

# ---- assert on the RENDERED output, not on the file we just wrote -----------
if command -v kubectl >/dev/null 2>&1 && [ -f "$KUS" ]; then
  if OUT=$(kubectl kustomize "$DIR" 2>&1); then
    C=$(printf '%s' "$OUT" | grep -c "name: risingwave-admin-$CN" || true)
    [ "$C" = "2" ] || { echo "!! rendered output contains $C of the 2 RoleBindings" >&2; exit 1; }
    echo "   rendered kustomize output contains both RoleBindings"
  else
    echo "!! kubectl kustomize cannot build $DIR after this edit:" >&2
    printf '%s\n' "$OUT" | sed 's/^/     /' >&2
    echo "   Refusing to commit a directory Flux will fail to render. Nothing was" >&2
    echo "   committed; the branch is reset on the next run." >&2
    exit 1
  fi
fi

git add -A "$DIR"
echo
echo "-------- git diff origin/$BR --------"
git --no-pager diff --cached "origin/$BR"
echo "-------- end --------"
echo "Read every line above, including any you did not mean to change."

# No AI-attribution trailer here: this commit lands in a USX corporate repository,
# where CLAUDE.md rule 8 forbids it.
git commit -q -F - <<COMMIT
risingwave: grant $CN namespace admin on op-usxpress-dev

Tim is the RisingWave consumer for Phase 2 and needs to work inside his own
namespaces. The recorded scope from the Phase 1 handoff is "super-user in the
risingwave namespace only. Not cluster-wide."

Two RoleBindings to the built-in ClusterRole admin, in risingwave-2 and
risingwave. Used in a RoleBinding that is full control inside those namespaces,
including their secrets, and nothing outside them.

His cert carries O=risingwave-users, a group with no bindings anywhere, so every
permission he holds comes from these two objects and can be read off them. The
runbook's default of O=onprem-platform-users would have granted cluster-wide
read, which the scope above rules out.

Applied live on op-dev so he is not blocked. This commit is what makes it
survive the next rebuild-to-validate.
COMMIT

if [ "$PUSH" = "yes" ]; then
  git push -q -u origin "$TOPIC" --force-with-lease
  echo "   pushed $TOPIC"
  echo
  ORIGIN=$(git remote get-url origin)
  # Strip .git FIRST: sed -E is POSIX ERE and has no lazy quantifiers, so "[^/]+?"
  # is not a lazy match and the suffix survived.
  SLUG=$(printf '%s' "$ORIGIN" | sed -E 's#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')
  echo "   Open the PR — run this from anywhere; --repo means no default remote is needed:"
  echo
  echo "     gh pr create --repo $SLUG --base $BR --head $TOPIC --fill"
else
  echo "   committed to local $TOPIC (not pushed). Re-run with --push."
fi
