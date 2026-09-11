#!/usr/bin/env bash
# Prove QA's schema-registry credentials actually work. Read-only, prints no secret.
#   bash scripts/verify-qa-schema-registry.sh [profile]   (default usx-qa)
set -uo pipefail
PROFILE="${1:-usx-qa}"
SUBJECT="qa_brand_management_cdc_brand_avro-value"

S=$(aws secretsmanager get-secret-value --profile "$PROFILE" --region us-east-2 \
      --secret-id op-usxpress-qa/risingwave/kafka --query SecretString --output text 2>/dev/null) || {
  echo "ABORT: cannot read the secret with profile '$PROFILE'. aws sso login --profile $PROFILE"; exit 3; }

SR=$(jq -r '.kafka__schema_registry_endpoint // ""'   <<<"$S")
SK=$(jq -r '.kafka__schema_registry_api_key // ""'    <<<"$S")
SS=$(jq -r '.kafka__schema_registry_api_secret // ""' <<<"$S")

echo "endpoint : ${SR:-<EMPTY>}"
printf 'api key  : %s\n' "$([ -n "$SK" ] && echo "set (${#SK} chars)" || echo "<EMPTY>")"
printf 'secret   : %s\n' "$([ -n "$SS" ] && echo "set (${#SS} chars)" || echo "<EMPTY>")"
echo
for v in SR SK SS; do
  [ -z "${!v}" ] && { echo "NOT READY: $v is still empty in Secrets Manager. Nothing to test."; exit 4; }
done

CODE=$(curl -s -o /tmp/sr-verify.out -w '%{http_code}' -u "$SK:$SS" "$SR/subjects")
echo "GET /subjects -> HTTP $CODE"
case "$CODE" in
  200) ;;
  401) echo "FAIL: 401 — the key or secret is wrong."; exit 5 ;;
  403) echo "FAIL: 403 — the key is valid but the service account has no role binding on"
       echo "      the registry. This is the failure that looks like a bad key. Ask the"
       echo "      Confluent admin for the binding, not another key."; exit 5 ;;
  000) echo "FAIL: could not reach $SR at all — network or endpoint wrong."; exit 5 ;;
  *)   echo "FAIL: unexpected status. Response:"; head -c 300 /tmp/sr-verify.out; echo; exit 5 ;;
esac

N=$(jq -r 'length' < /tmp/sr-verify.out 2>/dev/null || echo 0)
echo "subjects visible: $N"
if ! jq -e --arg s "$SUBJECT" 'index($s)' < /tmp/sr-verify.out >/dev/null 2>&1; then
  echo "FAIL: 200, but '$SUBJECT' is NOT among them."
  echo "      Authorised for the registry, not for Brand's subject. Partial access reads"
  echo "      as success everywhere except the one place it matters."
  exit 6
fi
echo "  '$SUBJECT' is visible"

CODE=$(curl -s -o /tmp/sr-schema.out -w '%{http_code}' -u "$SK:$SS" "$SR/subjects/$SUBJECT/versions/latest")
echo "GET the Brand schema -> HTTP $CODE"
[ "$CODE" != "200" ] && { echo "FAIL: can list subjects but cannot read the schema."; exit 6; }
jq -r '.schema | fromjson | "  record: \(.namespace // "-").\(.name // "-")"' < /tmp/sr-schema.out
echo
echo "VERDICT: QA can read Brand's schema. Safe to run secret.yaml."
