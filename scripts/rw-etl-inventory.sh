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
  # Pod AND container. `kubectl exec` without -c prints "Defaulted container ..." on
  # stderr; on 2026-08-26 that warning was folded into the probe by 2>&1 and op-qa was
  # reported UNKNOWN when its probe had in fact returned 1. Name the container, and never
  # let stderr reach a value that gets compared.
  local pod ctr
  pod=$(K -n "$ns" get pods -o json 2>/dev/null | jq -r '
    [ .items[]
      | select(.status.phase == "Running")
      | select([.spec.containers[].image] | map(test("postgres")) | any)
      | .metadata.name ] | first // empty')
  ctr=$(K -n "$ns" get pod "$pod" -o json 2>/dev/null | jq -r '
    [ .spec.containers[] | select(.image | test("postgres")) | .name ] | first // empty')
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
    [ -n "$pw" ] && { echo "     auth: secret/${sec} · frontend svc/${svc}:4567 · pod ${pod}/${ctr}"; break; }
  done
  if [ -z "$pw" ]; then
    echo "     UNKNOWN -- no secret in ${ns} yields a 'password' key for RW root."
    echo "               Secrets present: $(K -n "$ns" get secrets -o name 2>/dev/null | sed 's|secret/||' | tr '\n' ' ')"
    return
  fi

  # Q returns the VALUE (stdout only). Qdiag is for showing a failure, and is the only
  # one that ever merges stderr.
  Q()     { K -n "$ns" exec "$pod" -c "$ctr" -- env PGPASSWORD="$pw" PGCONNECT_TIMEOUT=10 \
              psql -h "$svc" -p 4567 -U root -d dev -tAF'|' -c "$1" 2>/dev/null; }
  Qdiag() { K -n "$ns" exec "$pod" -c "$ctr" -- env PGPASSWORD="$pw" PGCONNECT_TIMEOUT=10 \
              psql -h "$svc" -p 4567 -U root -d dev -tAF'|' -c "$1" 2>&1; }

  # ---- THE PROBE. Nothing below is believable until this passes.
  local probe
  probe=$(Q 'SELECT 1;')
  if [ "$(printf '%s' "$probe" | tr -d '[:space:]')" != "1" ]; then
    echo "     UNKNOWN -- cannot query RisingWave. This is NOT 'the ETL is absent'."
    Qdiag 'SELECT 1;' | sed 's/^/                /' | head -6
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
# Rewritten 2026-08-26. The first version returned silently whenever it could not find a
# credential -- so "no tracking table" and "never looked" printed identically, which is the
# same defect the probe above exists to prevent. It also assumed the bitnami key name
# `postgres-password` and the secret name `postgres`; op-qa uses `pg-credentials`.
tracking_table() {
  local cluster="$1" ns="$2"
  K get ns "$ns" >/dev/null 2>&1 || return

  local pod ctr
  pod=$(K -n "$ns" get pods -o json 2>/dev/null | jq -r '
    [ .items[] | select(.status.phase=="Running")
      | select([.spec.containers[].image] | map(test("postgres")) | any)
      | .metadata.name ] | first // empty')
  [ -n "$pod" ] || { echo "       ${ns}: no running postgres pod -- not asked"; return; }
  ctr=$(K -n "$ns" get pod "$pod" -o json 2>/dev/null | jq -r '
    [ .spec.containers[] | select(.image | test("postgres")) | .name ] | first // empty')

  # Try every (secret, key, user) combination -- and look in app-risingwave too, not just
  # this namespace. The applier Job runs in app-risingwave and gets its Postgres credential
  # from an ExternalSecret THERE, while the database it writes to lives in the risingwave
  # namespace. On 2026-08-26 a same-namespace-only search reported UNKNOWN on op-qa for
  # exactly that reason.
  local sec key pw="" user="" k credns
  for credns in "$ns" app-risingwave; do
  K get ns "$credns" >/dev/null 2>&1 || continue
  for sec in $(K -n "$credns" get secrets -o name 2>/dev/null | sed 's|secret/||'); do
    for key in $(K -n "$credns" get secret "$sec" -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}' 2>/dev/null); do
      case "$key" in *assword*|*PASSWORD*) ;; *) continue ;; esac
      k=$(K -n "$credns" get secret "$sec" -o go-template="{{index .data \"$key\"}}" 2>/dev/null | base64 -d 2>/dev/null)
      [ -n "$k" ] || continue
      for user in postgres rwadmin root risingwave app; do
        if K -n "$ns" exec "$pod" -c "$ctr" -- env PGPASSWORD="$k" PGCONNECT_TIMEOUT=8 \
             psql -h localhost -p 5432 -U "$user" -d postgres -tAc 'SELECT 1;' 2>/dev/null \
             | tr -d '[:space:]' | grep -qx 1; then
          pw="$k"; echo "       ${ns}: opened postgres:5432 as ${user} via ${credns}/${sec}:${key}"; break 4
        fi
      done
    done
  done
  done
  if [ -z "$pw" ]; then
    echo "       ${ns}: UNKNOWN -- no secret/user pair in ${ns} or app-risingwave opened postgres:5432"
    echo "                   users tried: postgres rwadmin root risingwave app"
    return
  fi

  P() { K -n "$ns" exec "$pod" -c "$ctr" -- env PGPASSWORD="$pw" PGCONNECT_TIMEOUT=8 \
          psql -h localhost -p 5432 -U "$user" -d "$1" -tAF'|' -c "$2" 2>/dev/null; }

  local dbs db found=0
  dbs=$(P postgres "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;")
  for db in $dbs; do
    [ "$(P "$db" "SELECT to_regclass('public.pipeline_applied') IS NOT NULL;" | tr -d '[:space:]')" = "t" ] || continue
    found=1
    echo "       ${ns} / db ${db} -- pipeline_applied:"
    P "$db" "SELECT * FROM pipeline_applied ORDER BY 1 DESC LIMIT 10;" | sed 's/^/         /'
  done
  [ "$found" -eq 1 ] || echo "       ${ns}: connected OK, no pipeline_applied table in any of: $(echo $dbs | tr '\n' ' ')"
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
