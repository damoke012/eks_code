#!/usr/bin/env bash
# INFRA-1689, second half — op-usxpress-prod's Grafana is CONFIGURED to be the dev instance.
#
# The VirtualService was corrected on 2026-09-03 and prod now answers on
# grafana.op-prod.usxpress.io. But infrastructure/grafana/helm-values-configmap.yaml still
# sets Grafana's own idea of where it lives:
#
#     domain:   grafana.op-dev.usxpress.io
#     root_url: https://grafana.op-dev.usxpress.io/
#
# server.root_url is what Grafana builds absolute URLs from: the redirect after login, links
# in alert notifications, and the OAuth callback. So a user reaches the prod hostname and is
# then sent to dev. The route being right makes this MORE visible, not less.
#
# Found by grepping the branch for the hostname while diagnosing something else. The first
# PR searched for a VirtualService and therefore only ever found one of the two.
#
#   scripts/pr-fix-prod-grafana-rooturl.sh          # dry run, prints the diff
#   scripts/pr-fix-prod-grafana-rooturl.sh --push
set -euo pipefail

REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
PUSH="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH="yes"; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }
cd "$REPO"
if [ -n "$(git status --porcelain)" ]; then
  echo "!! $REPO has uncommitted changes. Commit or stash them first." >&2
  git --no-pager status --short >&2; exit 2
fi
git fetch -q origin

BR="op-prod"; TOPIC="infra-1689-prod-grafana-rooturl"
CM="infrastructure/grafana/helm-values-configmap.yaml"

git checkout -q -B "$TOPIC" "origin/$BR"
[ -f "$CM" ] || { echo "!! $CM missing on $BR" >&2; exit 1; }

python3 - "$CM" <<'PY'
import re, sys
path = sys.argv[1]
s = open(path).read()

assert "grafana.op-dev.usxpress.io" in s, "no dev hostname in %s -- already fixed?" % path
s2, n1 = re.subn(r'(domain:[ \t]*)grafana\.op-dev\.usxpress\.io', r'\g<1>grafana.op-prod.usxpress.io', s)
s2, n2 = re.subn(r'(root_url:[ \t]*)https://grafana\.op-dev\.usxpress\.io/', r'\g<1>https://grafana.op-prod.usxpress.io/', s2)
assert n1 == 1, "expected exactly one domain: line, changed %d" % n1
assert n2 == 1, "expected exactly one root_url: line, changed %d" % n2
assert "op-dev" not in s2, "a dev reference survived: %r" % [l for l in s2.splitlines() if "op-dev" in l]
open(path, "w").write(s2)
print("   domain and root_url -> grafana.op-prod.usxpress.io")
PY

# Build the directory the way Flux does, and assert the RENDERED output. The first INFRA-1689
# PR verified the file it edited and never that the edit reached what prod renders.
if command -v kubectl >/dev/null 2>&1; then
  if out=$(kubectl kustomize infrastructure/grafana 2>/dev/null); then
    printf '%s' "$out" | grep -q "grafana.op-prod.usxpress.io" \
      && echo "   rendered build contains the prod hostname" \
      || { echo "!! the built kustomization does NOT contain the prod hostname" >&2; exit 1; }
    if printf '%s' "$out" | grep -q "op-dev"; then
      echo "!! the built kustomization still contains op-dev:" >&2
      printf '%s' "$out" | grep -n "op-dev" | sed 's/^/     /' >&2
      exit 1
    fi
    echo "   rendered build contains no op-dev reference"
  else
    echo "   (kubectl kustomize could not build this dir -- rendered check skipped)"
  fi
fi

git add -A infrastructure/grafana
echo
echo "-------- git diff origin/$BR --------"
git --no-pager diff --cached "origin/$BR"
echo "-------- end --------"

git commit -q -F - <<'COMMIT'
op-prod: Grafana was configured to be the dev instance

The VirtualService was corrected earlier today and prod now answers on
grafana.op-prod.usxpress.io. helm-values-configmap.yaml still told Grafana
itself that it lives at grafana.op-dev.usxpress.io.

server.root_url is what Grafana builds every absolute URL from: the redirect
after login, links in alert notifications, and the OAuth callback. A user
reaching the prod hostname was sent to dev. Fixing the route made this more
visible rather than less.

Found by grepping the branch for the hostname while diagnosing something else.
The first PR went looking for a VirtualService, so it could only ever find one
of the two places the dev name was written.

AFTER MERGE: the ConfigMap is consumed as Helm values, so confirm the Grafana
pod actually picked it up -- a rendered value only reaches the process when the
pod is recreated. Check with:
  kubectl -n grafana get pod
  curl -sI https://grafana.op-prod.usxpress.io/login | grep -i location
COMMIT

if [ "$PUSH" = "yes" ]; then
  git push -q -u origin "$TOPIC" --force-with-lease
  echo "   pushed $TOPIC"
  echo
  echo "   Open the PR with the base pinned:"
  echo "     gh pr create --base $BR --head $TOPIC --fill"
else
  echo "   committed to local $TOPIC (not pushed). Re-run with --push."
fi
