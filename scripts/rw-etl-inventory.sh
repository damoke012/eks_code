#!/usr/bin/env bash
# Inventory the RisingWave ETL itself -- what SQL objects actually exist -- across
# op-dev (risingwave, risingwave-2) and op-qa (risingwave).
#
# WHY THIS AND NOT rw-pipeline-parity.sh:
#   parity looked at Kubernetes -- namespaces, pods, Argo Applications. That tells you
#   whether the DELIVERY MACHINERY is in place. It cannot tell you whether Tim's ETL is
#   there, because the ETL is not a workload: it is rows in RisingWave's catalog, created
#   by SQL. A namespace can be green, an Argo Application Synced/Healthy, and the catalog
#   empty. That is exactly the op-qa case we are testing for.
#
# Read-only. Execs into an ALREADY-RUNNING pod (CLAUDE.md rule 3). Creates nothing.
#
# NEVER prints credential VALUES. rw_sources.connector_props holds live Confluent keys as
# plaintext on op-dev (INFRA-1637) -- `SELECT *` would leak them into your scrollback and
# into this script's output. Every credential question here is answered as a BOOLEAN.
#
# Rule 5 -- an empty result is not evidence of absence. Every namespace is PROBED with
# `SELECT 1` before any count is believed. A namespace that cannot be reached reports
# UNKNOWN, never "none".

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib-onprem-ctx.sh

K() { kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" "$@"; }

# ---------------------------------------------------------------- one namespace
inventory_ns() {
  local cluster="$1" ns="$2"
  echo
  echo "  ── ${cluster} / ${ns} ─────────────────────────────────────────"

  if ! K get ns "$ns" >/dev/null 2>&1; then
    echo "     namespace ABSENT"
    return
  fi

  # A pod that already runs psql. Never `kubectl run`.
  local pod
  pod=$(K -n "$ns" get pods -o json 2>/dev/null | jq -r '
    [ .items[]
      | select(.status.phase == "Running")
      | select([.spec.containers[].image] | map(test("postgres")) | any)
      | .metadata.name ] | first // empty')
  if [ -z "$pod" ]; then
    echo "     UNKNOWN -- no running postgres pod in this namespace to run psql from."
    echo "               (not the same as 'no ETL' -- we could not ask)"
    return
  fi

  # The RisingWave frontend service, discovered not assumed.
  local svc
  svc=$(K -n "$ns" get svc -o json 2>/dev/null | jq -r '
    [ .items[] | select(.metadata.name | test("frontend")) 
      | select(.spec.type != "NodePort" or (.metadata.name | test("-lb") | not))
      | .metadata.name ] | first // empty')
  [ -n "$svc" ] || svc=$(K -n "$ns" get svc -o json 2>/dev/null | jq -r \
    '[.items[] | select(.metadata.name | test("frontend")) | .metadata.name] | first // empty')
  if [ -z "$svc" ]; then
    echo "     UNKNOWN -- no service matching 'frontend' in ${ns}; RisingWave may not be deployed here"
    return
  fi

  # The root password, from whichever secret in this namespace carries one.
  local sec pw=""
  for sec in $(K -n "$ns" get secrets -o name 2>/dev/null \
                 | sed 's|secret/||' | grep -Ei 'root|credential' ); do
    pw=$(K -n "$ns" get secret "$sec" -o go-template='{{index .data "password"}}' 2>/dev/null \
           | base64 -d 2>/dev/null) || pw=""
    [ -n "$pw" ] && { echo "     auth: secret/${sec} · frontend svc/${svc}:4567 · pod ${pod}"; break; }
  done
  if [ -z "$pw" ]; then
    echo "     UNKNOWN -- no secret in ${ns} yields a 'password' key for RW root."
    echo "               Secrets present: $(K -n "$ns" get secrets -o name 2>/dev/null | sed 's|secret/||' | tr '\n' ' ')"
    return
  fi

  Q() { K -n "$ns" exec "$pod" -- env PGPASSWORD="$pw" PGCONNECT_TIMEOUT=10 \
          psql -h "$svc" -p 4567 -U root -d dev -tAF'|' -c "$1" 2>&1; }

  # ---- THE PROBE. Nothing below is believable until this passes.
  local probe
  probe=$(Q 'SELECT 1;')
  if [ "$(printf '%s' "$probe" | tr -d '[:space:]')" != "1" ]; then
    echo "     UNKNOWN -- cannot query RisingWave. This is NOT 'the ETL is absent'."
    printf '%s\n' "$probe" | sed 's/^/                /' | head -4
    return
  fi

  echo "     probe OK -- counts below are real"

  local src mv snk tbl scr
  src=$(Q "SELECT name FROM rw_catalog.rw_sources ORDER BY name;")
  mv=$(Q  "SELECT name FROM rw_catalog.rw_materialized_views ORDER BY name;")
  snk=$(Q "SELECT name FROM rw_catalog.rw_sinks ORDER BY name;")
  tbl=$(Q "SELECT name FROM rw_catalog.rw_tables ORDER BY name;")
  scr=$(Q "SELECT name FROM rw_catalog.rw_secrets ORDER BY name;")

  show() { local label="$1" body="$2" n
           n=$(printf '%s' "$body" | grep -c . || true)
           if [ "$n" -eq 0 ]; then echo "       ${label}: 0"
           else echo "       ${label}: ${n}  -- $(printf '%s' "$body" | paste -sd' ' -)"; fi; }
  show "sources           " "$src"
  show "materialized views" "$mv"
  show "sinks             " "$snk"
  show "tables            " "$tbl"
  show "secrets defined   " "$scr"

  # ---- Credentials in the catalog (INFRA-1637). BOOLEANS ONLY -- never the value.
  if [ -n "$(printf '%s' "$src" | grep -c . )" ] && [ "$(printf '%s' "$src" | grep -c .)" -gt 0 ]; then
    echo "       plaintext credentials in source DDL (INFRA-1637):"
    Q "SELECT name,
              CASE WHEN connector_props::text LIKE '%plaintext%' THEN 'PLAINTEXT PRESENT'
                   ELSE 'no plaintext' END
       FROM rw_catalog.rw_sources ORDER BY name;" \
      | awk -F'|' 'NF>=2 {printf "         %-28s %s\n", $1, $2}'
  fi
}

# ---------------------------------------------------------------- tracking table
tracking_table() {
  local cluster="$1" ns="$2"
  K get ns "$ns" >/dev/null 2>&1 || return
  local pod pw sec
  pod=$(K -n "$ns" get pods -o json 2>/dev/null | jq -r '
    [ .items[] | select(.status.phase=="Running")
      | select([.spec.containers[].image] | map(test("postgres")) | any)
      | .metadata.name ] | first // empty')
  [ -n "$pod" ] || return
  for sec in $(K -n "$ns" get secrets -o name 2>/dev/null | sed 's|secret/||' | grep -Ei 'postgres'); do
    pw=$(K -n "$ns" get secret "$sec" -o go-template='{{index .data "postgres-password"}}' 2>/dev/null | base64 -d 2>/dev/null) || pw=""
    [ -n "$pw" ] && break
  done
  [ -n "${pw:-}" ] || return
  local out
  out=$(K -n "$ns" exec "$pod" -- env PGPASSWORD="$pw" psql -h localhost -p 5432 -U postgres \
          -tAF'|' -c "SELECT filename, image_digest, applied_at, applied_by FROM pipeline_applied ORDER BY applied_at DESC LIMIT 10;" 2>&1)
  echo "       pipeline_applied (${ns}):"
  printf '%s\n' "$out" | sed 's/^/         /' | head -12
}

# ---------------------------------------------------------------- main
for cluster in op-dev op-qa; do
  echo
  echo "################################ ${cluster} ################################"
  if ! onprem_resolve_ctx "$cluster"; then
    echo "  (unreachable -- everything about ${cluster} below is UNKNOWN, not absent)"
    continue
  fi
  for ns in risingwave risingwave-2 app-risingwave; do
    inventory_ns "$cluster" "$ns"
  done
  echo
  echo "  ── ${cluster} / tracking table ──────────────────────────────"
  for ns in risingwave risingwave-2 app-risingwave; do tracking_table "$cluster" "$ns"; done
done

cat <<'NOTE'

######################################################################
WHAT THIS ANSWERS

RisingWave has two halves and they are promoted by different means:

  1. THE PLATFORM -- operator, frontend, compute, meta. Helm/Flux, ours. A namespace
     with running pods proves this half.
  2. THE ETL -- sources, materialized views, sinks. SQL. It exists only as rows in
     rw_catalog, and running pods prove NOTHING about it.

If op-qa/risingwave probes OK and reports 0 sources and 0 materialized views, then the
platform is promoted and Tim's ETL is not. That is the claim to check.

And if op-dev/risingwave reports PLAINTEXT PRESENT, INFRA-1637 is not done -- which
matters twice over, because the inlined credentials are also the reason the DDL cannot
be promoted as-is.
NOTE
