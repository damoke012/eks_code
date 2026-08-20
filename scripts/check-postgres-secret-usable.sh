#!/usr/bin/env bash
# Does the password in Secrets Manager actually open the database?
#
# Written 2026-08-20 after INFRA-1648. On op-usxpress-qa, Secrets Manager,
# `pg-credentials`, `risingwave-pg-credentials` and the app's own secret all held
# the SAME password, every ExternalSecret reported SecretSynced, and none of them
# matched the database: initdb ran 2026-08-11 19:20 UTC, the secret was rotated
# 2026-08-12 13:35 UTC, and POSTGRES_PASSWORD only applies at initialisation.
#
# It stayed invisible for 8 days because env from secretKeyRef resolves at POD
# creation — risingwave-meta's 238 container restarts each replayed the old value
# and each succeeded. The first thing to use the credential fresh was a smoke test.
#
# This does two things no status field does:
#   1. compares the secret's LastChangedDate against initdb
#   2. actually authenticates, over TCP so pg_hba host rules apply
#
# The password is fed on stdin, never as an argument — argv is visible on the node.
#
# Usage:
#   ./check-postgres-secret-usable.sh op-usxpress-qa-sso risingwave \
#       op-usxpress-qa/risingwave/postgres usx-qa
set -euo pipefail

CTX="${1:?usage: $0 <kube-context> <namespace> <sm-secret-id> <aws-profile> [pg-pod]}"
NS="${2:?}"; SM="${3:?}"; PROFILE="${4:?}"; POD="${5:-}"
: "${KUBECONFIG:?set KUBECONFIG to the kubeconfig holding $CTX}"

kc() { kubectl --context "$CTX" -n "$NS" "$@"; }

[[ -n "$POD" ]] || POD=$(kc get pod -o name | grep -m1 postgres | sed 's|pod/||')
[[ -n "$POD" ]] || { echo "no postgres pod found in $NS on $CTX"; exit 1; }
echo "cluster   : $CTX"
echo "pod       : $POD"
echo "sm secret : $SM  (profile $PROFILE)"
echo

# ---- 1. timeline -----------------------------------------------------------
INITDB=$(kc logs "$POD" 2>/dev/null | grep -m1 -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' || true)
CHANGED=$(aws --profile "$PROFILE" secretsmanager describe-secret --secret-id "$SM" \
            --query 'LastChangedDate' --output text 2>/dev/null || echo "")
echo "initdb / first log line : ${INITDB:-unknown}"
echo "secret LastChanged      : ${CHANGED:-unknown}"
if [[ -n "$INITDB" && -n "$CHANGED" ]]; then
  I=$(date -u -d "$INITDB" +%s 2>/dev/null || echo 0)
  C=$(date -u -d "$CHANGED" +%s 2>/dev/null || echo 0)
  if (( C > I && I > 0 )); then
    echo "  ⚠ the secret changed AFTER the database was initialised."
    echo "    POSTGRES_PASSWORD applies only at initdb, so the database may never"
    echo "    have learned this value. The auth test below is the real answer."
  fi
fi
echo

# ---- 2. does it actually authenticate? -------------------------------------
USER=$(aws --profile "$PROFILE" secretsmanager get-secret-value --secret-id "$SM" \
        --query SecretString --output text \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("username","postgres"))')
DB=$(kc get pod "$POD" -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
      | awk -F= '/^POSTGRES_DB=/{print $2}')
DB="${DB:-postgres}"
echo "authenticating as '$USER' to database '$DB' over TCP (pg_hba host rules apply)"

if aws --profile "$PROFILE" secretsmanager get-secret-value --secret-id "$SM" \
     --query SecretString --output text \
   | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["password"])' \
   | kc exec -i "$POD" -- sh -c \
       'read -r PW; PGPASSWORD="$PW" psql -h 127.0.0.1 -U '"$USER"' -d '"$DB"' -tAq -c "SELECT 1" >/dev/null 2>&1'
then
  echo "  ✓ the value in Secrets Manager opens the database"
  exit 0
else
  echo "  ✗ AUTHENTICATION FAILED with the value in Secrets Manager."
  echo
  echo "  Every ExternalSecret reading this path will still report SecretSynced."
  echo "  Postgres gives the same message for a wrong password and a missing role,"
  echo "  so check both:"
  echo "    kubectl --context $CTX -n $NS exec -i $POD -- psql -U $USER -d $DB -c '\\du'"
  echo
  echo "  To align the database to Secrets Manager (initdb enables trust for LOCAL"
  echo "  connections, so no prior password is needed):"
  echo "    ALTER USER $USER WITH PASSWORD '<the SM value>'"
  echo "  Afterwards RECREATE every pod holding the old value in env — a container"
  echo "  restart replays it, only pod recreation re-reads the secret."
  exit 1
fi
