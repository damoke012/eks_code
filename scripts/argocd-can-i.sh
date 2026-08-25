#!/usr/bin/env bash
# INFRA-1639 -- prove AUTHORISATION for the signed-in identity, without needing an
# Application to look at.
#
# Why this exists: a sign-in proves authentication. The Applications screen proves
# authorisation only if there is something on it to be denied -- and op-dev and op-prod
# have NO Applications (no ApplicationSet yet, INFRA-1650). An admin and a user with zero
# permissions see the identical empty page there, so "I logged in and saw the UI" is not
# evidence of anything. Only op-qa has a real Application.
#
# `argocd account can-i` asks the server for the RBAC decision itself, so it works on an
# empty cluster. The NEGATIVE cases matter as much as the positive ones: a policy that
# grants everything would pass every allow-check and still be wrong.
#
#   argocd login argocd.op-qa.usxpress.io --sso     # then:
#   scripts/argocd-can-i.sh op-qa
#   scripts/argocd-can-i.sh op-prod --role app-viewer
set -uo pipefail
BR="${1:-}"; ROLE="${3:-platform-admin}"
[ "${2:-}" = "--role" ] && ROLE="${3:-}"
case "$BR" in op-dev|op-qa|op-prod) : ;; *)
  echo "!! usage: $0 <op-dev|op-qa|op-prod> [--role platform-admin|app-viewer]" >&2; exit 2 ;; esac
HOST="argocd.${BR}.usxpress.io"
command -v argocd >/dev/null 2>&1 || {
  echo "!! the argocd CLI is not on PATH." >&2
  echo "   curl -sSL -o ~/.local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && chmod +x ~/.local/bin/argocd" >&2
  exit 2; }

WHO=$(argocd account get-user-info --server "$HOST" --grpc-web 2>/dev/null)
printf '%s' "$WHO" | grep -qi 'logged in: *true' || {
  echo "!! not signed in to $HOST. Run:  argocd login $HOST --sso --grpc-web" >&2
  exit 1; }
echo "== $BR as: $(printf '%s' "$WHO" | tr '\n' ' ')"
echo "   expecting the permissions of: $ROLE"
echo

FAIL=0
# want=yes -> a granted permission that must work. want=no -> a boundary that must hold.
probe() { # want action resource subresource why
  local want="$1" act="$2" res="$3" sub="$4" why="$5" got
  got=$(argocd account can-i "$act" "$res" "$sub" --server "$HOST" --grpc-web 2>/dev/null | tr -d '[:space:]')
  case "$got" in yes|no) : ;; *) echo "  ????  $act $res $sub -- unreadable answer '$got'" >&2; FAIL=1; return ;; esac
  if [ "$got" = "$want" ]; then printf '  ok    %-34s %-3s  %s\n' "$act $res $sub" "$got" "$why"
  else printf '  FAIL  %-34s %-3s  expected %s -- %s\n' "$act $res $sub" "$got" "$want" "$why" >&2; FAIL=1; fi
}

case "$ROLE" in
  platform-admin)
    probe yes get         applications 'apps/*'    "sees the project's Applications"
    probe yes sync        applications 'apps/*'    "can sync"
    probe yes get         clusters     '*'         "admin sees cluster config"
    probe yes create      projects     '*'         "admin manages projects"
    ;;
  app-viewer)
    probe yes get         applications 'apps/*'    "sees the project's Applications"
    probe yes get         logs         'apps/*'    "reads the sync-hook Job's logs -- the day-to-day value"
    # The boundaries. These are the reason the role is scoped, and a policy that
    # granted everything would sail through the checks above.
    probe no  create      applications 'apps/*'    "must NOT create Applications"
    probe no  delete      applications 'apps/*'    "must NOT delete Applications"
    probe no  get         clusters     '*'         "must NOT see cluster config"
    probe no  create      projects     '*'         "must NOT manage projects"
    case "$BR" in
      op-prod) probe no  sync applications 'apps/*' "prod promotion is human-initiated by the platform -- NO sync" ;;
      *)       probe yes sync applications 'apps/*' "may sync on $BR" ;;
    esac
    ;;
  *) echo "!! unknown role '$ROLE'" >&2; exit 2 ;;
esac

echo
[ "$FAIL" -eq 0 ] && echo "  AUTHORISATION CONFIRMED for $ROLE on $BR, allow and deny both." \
                  || { echo "  $BR does NOT match the intended policy for $ROLE." >&2; exit 1; }
