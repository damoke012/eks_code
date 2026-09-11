#!/usr/bin/env bash
# Populate RisingWave's schema-registry fields from the ACCOUNT's registry master.
#
#   bash scripts/copy-registry-creds-to-rw.sh qa
#
# dx--ccloud-schema-registry-master is the one registry credential per AWS account;
# every consumer copies it. Verified 2026-09-11: dev's op-usxpress-dev/risingwave/kafka
# holds byte-identical values to dev's master. This does the same for another env.
#
# Prints no secret value. Preserves the target's existing key names and casing.
set -uo pipefail
ENVN="${1:-}"
case "$ENVN" in
  dev)  PROFILE="usx-dev" ;;
  qa)   PROFILE="usx-qa" ;;
  prod) PROFILE="ops-controller" ;;
  *) echo "usage: copy-registry-creds-to-rw.sh dev|qa|prod"; exit 2 ;;
esac
REGION="us-east-2"
MASTER="dx--ccloud-schema-registry-master"
TARGET="op-usxpress-$ENVN/risingwave/kafka"

get() { aws secretsmanager get-secret-value --profile "$PROFILE" --region "$REGION" \
          --secret-id "$1" --query SecretString --output text 2>/dev/null; }

echo "env $ENVN   profile $PROFILE"
M=$(get "$MASTER")   || { echo "ABORT: cannot read $MASTER (aws sso login --profile $PROFILE)"; exit 3; }
[ -n "$M" ]          || { echo "ABORT: $MASTER is empty or unreadable"; exit 3; }
T=$(get "$TARGET")   || { echo "ABORT: cannot read $TARGET"; exit 3; }
[ -n "$T" ]          || { echo "ABORT: $TARGET does not exist. On prod this record has never been"
                          echo "       created -- that is a Terraform change in iaac-risingwave-onprem,"
                          echo "       not something to create by hand."; exit 4; }

# the master is uppercase KAFKA__; the target may be either casing. Write into whatever
# key names the target already uses -- dev is KAFKA__, QA is kafka__.
PREFIX=$(jq -r 'keys[] | select(test("schema_registry_endpoint$"))' <<<"$T" | head -1)
PREFIX="${PREFIX%schema_registry_endpoint}"
[ -n "$PREFIX" ] || { echo "ABORT: $TARGET has no *schema_registry_endpoint key to fill"; exit 4; }
echo "target key prefix  : ${PREFIX}"

for f in endpoint api_key api_secret; do
  v=$(jq -r ".KAFKA__schema_registry_$f // \"\"" <<<"$M")
  [ -n "$v" ] || { echo "ABORT: the master's schema_registry_$f is EMPTY -- nothing to copy"; exit 5; }
  printf '  master %-11s set (%s chars)\n' "$f" "${#v}"
done
echo
echo "target now:"
jq -r --arg p "$PREFIX" 'to_entries[] | select(.key|startswith($p+"schema_registry")) | "  \(.key) = \(if (.value|tostring|length)==0 then "EMPTY" else "set (\(.value|tostring|length) chars)" end)"' <<<"$T"

NEW=$(jq --argjson m "$M" --arg p "$PREFIX" '
  .[$p+"schema_registry_endpoint"]   = $m.KAFKA__schema_registry_endpoint |
  .[$p+"schema_registry_api_key"]    = $m.KAFKA__schema_registry_api_key  |
  .[$p+"schema_registry_api_secret"] = $m.KAFKA__schema_registry_api_secret' <<<"$T")

KB=$(jq -r 'keys|length' <<<"$T"); KA=$(jq -r 'keys|length' <<<"$NEW")
PB=$(jq -r '[to_entries[]|select((.value|tostring|length)>0)]|length' <<<"$T")
PA=$(jq -r '[to_entries[]|select((.value|tostring|length)>0)]|length' <<<"$NEW")
echo
echo "keys $KB -> $KA      populated $PB -> $PA"
[ "$KB" = "$KA" ] || { echo "ABORT: key count changed -- refusing to write"; exit 6; }

read -r -p "write these three values into $TARGET ($PROFILE)? [y/N] " a
case "$a" in y|Y|yes|YES) ;; *) echo "not written"; exit 0 ;; esac
aws secretsmanager put-secret-value --profile "$PROFILE" --region "$REGION" \
  --secret-id "$TARGET" --secret-string "$NEW" >/dev/null || { echo "write FAILED"; exit 7; }
unset NEW M T
echo "written. re-reading:"
get "$TARGET" | jq -r 'to_entries[] | select(.key|test("schema_registry")) | "  \(.key) = \(if (.value|tostring|length)==0 then "STILL EMPTY" else "set (\(.value|tostring|length) chars)" end)"'
echo
echo "Now prove it works, don't assume:  bash scripts/verify-qa-schema-registry.sh $PROFILE"
