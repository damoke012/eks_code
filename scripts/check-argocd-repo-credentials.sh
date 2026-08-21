#!/usr/bin/env bash
# Does every Argo CD Application have a credential that MATCHES its repoURL?
#
# Written 2026-08-21 after PR #100 reverted an ApplicationSet element from
# ssh:// to https:// on op-usxpress-qa. The credential is a deploy key --
# secret-type `repository`, bound to one EXACT url -- so the https:// element
# matched nothing, and GitHub answers an unauthenticated request for a private
# repo with "Repository not found". The Application sat at Sync=Unknown,
# Health=Healthy, with operationState still showing yesterday's Succeeded.
# Delivery was down for 18 hours and every status field looked survivable.
#
# Matching rules this encodes (Argo CD):
#   secret-type: repository  -> the url must match the Application's repoURL EXACTLY
#   secret-type: repo-creds  -> the url is a PREFIX for any repo beneath it
# ssh:// and https:// forms of the same repository are NOT interchangeable.
#
# READ ONLY.
#
#   scripts/check-argocd-repo-credentials.sh --context op-usxpress-qa-sso
set -uo pipefail

CTX=""; KCFG=""; NS=argocd
while [ $# -gt 0 ]; do
  case "$1" in
    --context)    CTX="$2";  shift 2 ;;
    --kubeconfig) KCFG="$2"; shift 2 ;;
    --namespace)  NS="$2";   shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CTX" ] || { echo "usage: $0 --context <ctx> [--kubeconfig P] [--namespace argocd]" >&2; exit 2; }

k() { kubectl ${KCFG:+--kubeconfig="$KCFG"} --context "$CTX" "$@"; }
command -v jq >/dev/null || { echo "!! jq not installed" >&2; exit 2; }

SECRETS=$(k -n "$NS" get secret -l argocd.argoproj.io/secret-type -o json 2>/dev/null)
[ -n "$SECRETS" ] || { echo "!! cannot read secrets in $NS on $CTX" >&2; exit 1; }

echo "Argo CD credentials in $NS on $CTX"
CREDS=$(echo "$SECRETS" | jq -r '
  .items[] | [ .metadata.name,
               (.metadata.labels["argocd.argoproj.io/secret-type"]),
               (.data.url // "" | @base64d) ] | @tsv')
if [ -z "$CREDS" ]; then echo "  (none — every private repo will fail)"; else
  printf '%s\n' "$CREDS" | awk -F'\t' '{printf "  %-34s %-12s %s\n", $1, $2, $3}'
fi

echo
echo "Applications and whether a credential matches"
FAIL=0
APPS=$(k -n "$NS" get application -o json 2>/dev/null | jq -r '.items[] | [.metadata.name, .spec.source.repoURL] | @tsv')
ASETS=$(k -n "$NS" get applicationset -o json 2>/dev/null | jq -r '
  .items[] | .metadata.name as $n
  | (.spec.generators[]?.list.elements[]? | [$n + " (set)", .repoURL] | @tsv) // empty')
ALL=$(printf '%s\n%s\n' "$APPS" "$ASETS" | grep -v '^$' | sort -u)
[ -n "$ALL" ] || { echo "  (no Applications or ApplicationSets)"; exit 0; }

while IFS=$'\t' read -r NAME URL; do
  MATCH=""
  while IFS=$'\t' read -r SNAME STYPE SURL; do
    [ -n "$SURL" ] || continue
    case "$STYPE" in
      repository) [ "$SURL" = "$URL" ] && MATCH="$SNAME (exact)" ;;
      repo-creds) case "$URL" in "$SURL"*) MATCH="$SNAME (prefix)" ;; esac ;;
    esac
    [ -n "$MATCH" ] && break
  done <<< "$CREDS"

  if [ -n "$MATCH" ]; then
    printf '  %-26s %-58s ok  %s\n' "$NAME" "$URL" "$MATCH"
  else
    printf '  %-26s %-58s NO CREDENTIAL MATCHES\n' "$NAME" "$URL"
    ALT=$(printf '%s\n' "$CREDS" | awk -F'\t' -v u="$URL" '
      { n=$3; gsub(/^ssh:\/\/git@/,"",n); gsub(/^https:\/\//,"",n); gsub(/\.git$/,"",n);
        v=u;  gsub(/^ssh:\/\/git@/,"",v); gsub(/^https:\/\//,"",v); gsub(/\.git$/,"",v);
        if (n == v) print "      a credential exists for the SAME repo in the other URL form: " $3 }')
    [ -n "$ALT" ] && printf '%s\n' "$ALT"
    FAIL=1
  fi
done <<< "$ALL"

echo
echo "Live comparison status (a stale Succeeded can hide a broken Application)"
k -n "$NS" get application -o json 2>/dev/null | jq -r '
  .items[] | "  \(.metadata.name)  sync=\(.status.sync.status // "?")  health=\(.status.health.status // "?")"
  + ((.status.conditions // []) | map(select(.type|test("Error"))) | if length>0 then "\n      " + (.[0].message) else "" end)'

exit "$FAIL"
