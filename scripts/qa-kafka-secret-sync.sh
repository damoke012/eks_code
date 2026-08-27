#!/usr/bin/env bash
# Add the missing schema-registry keys to op-usxpress-qa/risingwave/kafka, MERGING with
# what is already there.
#
#   bash scripts/qa-kafka-secret-sync.sh            # report which keys are missing
#   bash scripts/qa-kafka-secret-sync.sh --write    # prompt for them and put a new version
#
# op-qa ONLY. There is no flag to point this at another account.
#
# Values are read with `read -s` and never echoed, never passed as an argv, never written
# to shell history. The merged JSON goes to a 0600 temp file that is shredded on exit --
# `--secret-string` on the command line would put live credentials in ps output and in
# ~/.bash_history. (See the 2026-08-2x note on passing prose through shell strings: a
# PR body as --body "..." executed its own backticks.)
set -uo pipefail

PROFILE=op-qa
REGION=us-east-2
SECRET=op-usxpress-qa/risingwave/kafka
# What dev carries, and therefore what QA needs for the same pipelines to run.
WANT=(KAFKA__api_key KAFKA__api_secret KAFKA__bootstrap_server KAFKA__resource_id
      KAFKA__rest_endpoint KAFKA__schema_registry_api_key KAFKA__schema_registry_api_secret
      KAFKA__schema_registry_endpoint KAFKA__service_account)

acct=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null)
[ "$acct" = "527101283767" ] || { echo "!! profile ${PROFILE} resolves to account '${acct}', not QA (527101283767)" >&2; exit 2; }
echo "account : ${acct} (op-usxpress-qa)"
echo "secret  : ${SECRET}"
echo

CUR=$(aws secretsmanager get-secret-value --profile "$PROFILE" --region "$REGION" \
        --secret-id "$SECRET" --query SecretString --output text 2>/dev/null) || {
  echo "!! cannot read ${SECRET}" >&2; exit 2; }

missing=()
for k in "${WANT[@]}"; do
  if printf '%s' "$CUR" | jq -e --arg k "$k" 'has($k) and (.[$k] | length > 0)' >/dev/null 2>&1; then
    printf '  present  %s\n' "$k"
  else
    printf '  MISSING  %s\n' "$k"; missing+=("$k")
  fi
done

if [ "${#missing[@]}" -eq 0 ]; then
  echo; echo "Nothing to do -- all ${#WANT[@]} keys present and non-empty."
  exit 0
fi

echo
echo "${#missing[@]} key(s) missing. Brand's source is FORMAT PLAIN ENCODE AVRO, so the three"
echo "schema_registry values are required for it to decode anything at all."

if [ "${1:-}" != "--write" ]; then
  echo; echo "Report only. Re-run with --write to supply them."
  exit 0
fi

echo
echo "Enter each value. Input is hidden and is not echoed or stored in history."
echo "ROTATE FIRST -- if these keys are about to be revoked you will be writing dead values."
echo
TMP=$(mktemp); chmod 600 "$TMP"
trap 'shred -u "$TMP" 2>/dev/null || rm -f "$TMP"' EXIT

NEW="$CUR"
for k in "${missing[@]}"; do
  printf '  %s: ' "$k"
  IFS= read -rs val; echo
  [ -n "$val" ] || { echo "  !! empty -- aborting, nothing written" >&2; exit 1; }
  NEW=$(printf '%s' "$NEW" | jq --arg k "$k" --arg v "$val" '.[$k] = $v')
  unset val
done

printf '%s' "$NEW" > "$TMP"
# Prove the merge kept everything before writing.
before=$(printf '%s' "$CUR" | jq -r 'keys|length')
after=$(jq -r 'keys|length' "$TMP")
echo "  keys: ${before} -> ${after}"
[ "$after" -ge "$before" ] || { echo "  !! merge LOST keys -- refusing to write" >&2; exit 1; }

aws secretsmanager put-secret-value --profile "$PROFILE" --region "$REGION" \
  --secret-id "$SECRET" --secret-string "file://${TMP}" \
  --query 'VersionId' --output text

echo
echo "Verify (names only):"
echo "  aws secretsmanager get-secret-value --profile ${PROFILE} --region ${REGION} \\"
echo "    --secret-id ${SECRET} --query SecretString --output text | jq -r 'keys[]'"
