#!/usr/bin/env bash
# Which Sprint 4 tickets can actually be closed? Ask the clusters, not the board.
#
# READ-ONLY. get/describe only, no mutations, safe against prod (CLAUDE.md rules 1 and 3).
#
# Several tickets have sat TO DO for weeks while the work quietly landed, and others read as
# in-flight when they are blocked. Neither is visible from Jira. This checks the ones whose
# acceptance criteria can be settled by looking, and prints CLOSE / KEEP / UNKNOWN per ticket.
#
# UNKNOWN is a real answer: a cluster we could not reach is not a ticket we can close.
#
#   bash scripts/close-candidates.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib-onprem-ctx.sh"

close=0; keep=0; unknown=0
ERRF=$(mktemp); trap 'rm -f "$ERRF"' EXIT

t()   { printf '\n== %s\n   %s\n' "$1" "$2"; }
CLOSE(){ printf '   CLOSE    %s\n' "$*"; close=$((close+1)); }
KEEP() { printf '   KEEP     %s\n' "$*"; keep=$((keep+1)); }
HUH()  { printf '   UNKNOWN  %s\n' "$*"; unknown=$((unknown+1)); }

# Resolve each cluster once. NOT in a pipeline or $() -- the function exports variables and
# a subshell would discard them (cost a broken script earlier today).
declare -A KC CTX
for c in op-dev op-qa op-prod; do
  ONPREM_KC=""; ONPREM_CTX=""
  onprem_resolve_ctx "$c" 2>"$ERRF"
  if [ -n "$ONPREM_KC" ]; then
    KC[$c]="$ONPREM_KC"; CTX[$c]="$ONPREM_CTX"
    printf '   %-8s reachable (%s)\n' "$c" "$ONPREM_NODE"
  else
    printf '   %-8s UNREACHABLE -- findings below will say UNKNOWN, not "absent"\n' "$c"
  fi
done

k() { # k <cluster> <kubectl args...>
  local c="$1"; shift
  [ -n "${KC[$c]:-}" ] || return 3
  kubectl --kubeconfig="${KC[$c]}" --context="${CTX[$c]}" "$@" 2>/dev/null
}

# ── INFRA-1586: Wiz sensor on op-dev ─────────────────────────────────────────
t "INFRA-1586" "Wiz sensor deploy to op-usxpress-dev"
if st=$(k op-dev -n wiz get helmrelease wiz-sensor -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'); then
  if [ "$st" = "True" ]; then
    n=$(k op-dev -n wiz get pods --no-headers | grep -c Running)
    CLOSE "HelmRelease wiz-sensor Ready=True, $n pod(s) Running"
  else
    KEEP "HelmRelease wiz-sensor Ready=$st -- flux-revision-drift shows it has NEVER applied"
  fi
else
  HUH "cannot read HelmRelease wiz-sensor on op-dev"
fi

# ── INFRA-1636: ApplicationSet for op-usxpress-prod ──────────────────────────
t "INFRA-1636" "ApplicationSet for op-usxpress-prod"
if out=$(k op-prod -n argocd get applicationset -o name); then
  if [ -n "$out" ]; then
    apps=$(k op-prod -n argocd get applications -o name | wc -l)
    CLOSE "ApplicationSet present ($(printf '%s' "$out" | tr '\n' ' ')), $apps Application(s)"
  else
    KEEP "no ApplicationSet in argocd on op-prod"
  fi
else
  HUH "cannot read ApplicationSets on op-prod"
fi

# ── INFRA-1654: ghostunnel-rw-postgres listens on 4567, not 5432 ─────────────
t "INFRA-1654" "ghostunnel-rw-postgres listens on 4567, not 5432"
if ports=$(k op-dev -n risingwave get svc ghostunnel-rw-postgres -o jsonpath='{range .spec.ports[*]}{.port}{" "}{end}'); then
  if printf '%s' "$ports" | grep -qw 5432; then
    CLOSE "service exposes 5432 (ports: $ports)"
  else
    KEEP "service exposes [$ports] -- still no 5432, eleven weeks and counting"
  fi
else
  HUH "cannot read svc ghostunnel-rw-postgres on op-dev"
fi

# ── INFRA-1659: on-prem alerts reach a human (Alertmanager) ──────────────────
t "INFRA-1659" "Deliver on-prem alerts to somewhere a human looks"
have=""; miss=""
for c in op-dev op-qa op-prod; do
  if out=$(k "$c" get pods -A -l app.kubernetes.io/name=alertmanager -o name); then
    [ -n "$out" ] && have="$have $c" || miss="$miss $c"
  else
    miss="$miss $c(unreachable)"
  fi
done
if [ -n "$miss" ]; then
  KEEP "Alertmanager present on:${have:- none}; MISSING on:$miss"
else
  CLOSE "Alertmanager present on all three:$have"
fi

# ── INFRA-1558: Grafana on-prem SSO through Azure AD ─────────────────────────
t "INFRA-1558" "Azure AD OAuth app registration for Grafana on-prem SSO"
found=""
for c in op-dev op-prod; do
  ini=$(k "$c" -n grafana get cm grafana -o jsonpath='{.data.grafana\.ini}')
  if [ -z "$ini" ]; then found="$found $c(unreadable)"; continue; fi
  printf '%s' "$ini" | grep -q '\[auth\.azuread\]' \
    && found="$found $c(configured)" || found="$found $c(NOT configured)"
done
case "$found" in
  *"NOT configured"*) KEEP "grafana.ini has no [auth.azuread] section:$found" ;;
  *unreadable*)       HUH "could not read grafana.ini:$found" ;;
  *)                  CLOSE "[auth.azuread] configured:$found" ;;
esac

# ── INFRA-1555: rw-2 postgres local-path -> ceph-block ───────────────────────
t "INFRA-1555" "Postgres rw-2: local-path -> ceph-block migration"
if sc=$(k op-dev -n risingwave-2 get pvc data-postgres-postgresql-0 -o jsonpath='{.spec.storageClassName}'); then
  [ "$sc" = "ceph-block" ] && CLOSE "PVC is on ceph-block" \
                           || KEEP "PVC is still on '$sc' -- needs Tim's window"
else
  HUH "cannot read PVC data-postgres-postgresql-0 on op-dev"
fi

# ── INFRA-1642: Flux Git credential off a PAT, onto a deploy key ─────────────
t "INFRA-1642" "Fix the Flux Git credential at source: PAT -> deploy key"
res=""
for c in op-dev op-qa op-prod; do
  keys=$(k "$c" -n flux-system get secret flux-system -o jsonpath='{range .data}{end}{.data}' )
  if [ -z "$keys" ]; then res="$res $c(unreadable)"; continue; fi
  printf '%s' "$keys" | grep -q 'identity' \
    && res="$res $c(ssh key)" || res="$res $c(PAT/username)"
done
case "$res" in
  *"PAT/username"*) KEEP "flux-system secret still holds a username/password:$res" ;;
  *unreadable*)     HUH "could not read the flux-system secret:$res" ;;
  *)                CLOSE "all clusters authenticate with an ssh deploy key:$res" ;;
esac

printf '\n== CANDIDATES  %d closeable, %d keep open, %d unknown\n' "$close" "$keep" "$unknown"
echo "Evidence above is from the live clusters. An UNKNOWN is not a close."
