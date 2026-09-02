#!/usr/bin/env bash
# INFRA-1650 -- create the deploy key Argo CD reads variant-inc/risingwave-pipeline with,
# and put the private half where the ExternalSecret expects it.
#
# THE HAZARD THIS SCRIPT EXISTS FOR. op-usxpress-prod/platform/argocd already holds
# `admin.password`. `aws secretsmanager put-secret-value` REPLACES the whole JSON
# document, so writing the new property naively destroys the Argo CD admin password and
# locks you out of the very console you are fixing. This reads the record, merges one
# property in, and refuses if anything that was there is not still there afterwards.
#
# DRY RUN BY DEFAULT. --write generates the key and updates Secrets Manager.
#
#   bash scripts/argocd-repo-deploy-key.sh
#   bash scripts/argocd-repo-deploy-key.sh --write
#
# After --write, the PUBLIC half must be added to the repository as a deploy key:
#   GitHub -> variant-inc/risingwave-pipeline -> Settings -> Deploy keys -> Add deploy key
#   Title: argocd-op-usxpress-prod     Allow write access: NO
# A deploy key belongs to the repository: it never expires and survives offboarding,
# and it needs admin on one repo rather than ownership of the org.
set -uo pipefail
SECRET_ID="${SECRET_ID:-op-usxpress-prod/platform/argocd}"
PROFILE="${PROFILE:-ops-controller}"
REGION="${REGION:-us-east-2}"
ACCOUNT="${ACCOUNT:-937464026810}"
PROP="${PROP:-repo.risingwave-pipeline.sshPrivateKey}"
WRITE="no"; [ "${1:-}" = "--write" ] && WRITE="yes"

command -v aws >/dev/null 2>&1 || { echo "!! aws is not on PATH. Run this on WSL." >&2; exit 2; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "!! ssh-keygen not found." >&2; exit 2; }

acct=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null) || {
  echo "!! no session for --profile $PROFILE. aws sso login --profile $PROFILE" >&2; exit 3; }
[ "$acct" = "$ACCOUNT" ] || { echo "!! --profile $PROFILE lands in $acct, expected $ACCOUNT" >&2; exit 3; }
echo "account $acct  secret $SECRET_ID  region $REGION"

WORK="$(mktemp -d)"; chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT

CUR="$WORK/current.json"
aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
  --profile "$PROFILE" --region "$REGION" --query SecretString --output text > "$CUR" 2>"$WORK/e" || {
  echo "!! cannot read $SECRET_ID: $(tail -1 "$WORK/e")" >&2; exit 3; }
echo "current properties: $(python3 -c "import json,sys;print(sorted(json.load(open(sys.argv[1])).keys()))" "$CUR")"

if python3 -c "import json,sys;sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])) else 1)" "$CUR" "$PROP"; then
  echo "   '$PROP' is ALREADY present — nothing to do."
  echo "   If it is wrong rather than missing, remove it deliberately first."
  exit 0
fi
echo "   '$PROP' is absent — this is what makes PR #144 inert."

if [ "$WRITE" != "yes" ]; then
  cat <<'NEXT'

Dry run. Nothing generated, nothing written. Re-run with --write to:
  1. generate an ed25519 deploy key (private half never touches disk outside a 0700 tmpdir)
  2. merge it into the existing secret as one added property, preserving admin.password
  3. print the PUBLIC half for you to add on GitHub
NEXT
  exit 0
fi

ssh-keygen -t ed25519 -N "" -C "argocd-op-usxpress-prod" -f "$WORK/key" -q || {
  echo "!! ssh-keygen failed" >&2; exit 3; }

NEW="$WORK/new.json"
python3 - "$CUR" "$WORK/key" "$PROP" "$NEW" <<'PY'
import json, sys
cur_path, key_path, prop, out_path = sys.argv[1:5]
doc = json.load(open(cur_path))
assert prop not in doc, "property appeared between the check and the write"
before = set(doc)
doc[prop] = open(key_path).read()
# Every property that was there must still be there. put-secret-value replaces the whole
# document, and one of these is the Argo CD admin password.
assert before <= set(doc), "a property would be dropped: %s" % (before - set(doc))
json.dump(doc, open(out_path, "w"))
print("   merging: %d existing properties preserved, 1 added" % len(before))
PY
[ $? -eq 0 ] || { echo "!! merge refused" >&2; exit 3; }

aws secretsmanager put-secret-value --secret-id "$SECRET_ID" \
  --profile "$PROFILE" --region "$REGION" --secret-string "file://$NEW" \
  --query VersionId --output text >/dev/null 2>"$WORK/e" || {
  echo "!! write failed: $(tail -1 "$WORK/e")" >&2; exit 3; }

# Read back by CONTENT, not by "the write returned 200".
aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
  --profile "$PROFILE" --region "$REGION" --query SecretString --output text > "$WORK/after.json"
python3 - "$CUR" "$WORK/after.json" "$PROP" <<'PY'
import json, sys
before = json.load(open(sys.argv[1])); after = json.load(open(sys.argv[2])); prop = sys.argv[3]
missing = [k for k in before if k not in after]
if missing:
    sys.exit("!! properties LOST in the write: %s — restore from a previous version now" % missing)
if prop not in after or not after[prop].strip():
    sys.exit("!! %s is not present on read-back" % prop)
if "PRIVATE KEY" not in after[prop]:
    sys.exit("!! %s does not look like a private key" % prop)
print("   verified: all %d previous properties intact, %s written" % (len(before), prop))
PY
[ $? -eq 0 ] || exit 3

echo
echo "Add this PUBLIC key to the repository — read-only, no write access:"
echo "  GitHub -> variant-inc/risingwave-pipeline -> Settings -> Deploy keys -> Add deploy key"
echo "  Title: argocd-op-usxpress-prod"
echo
cat "$WORK/key.pub"
echo
echo "Then, once PR #144 is merged, force ESO to pick it up and confirm the KEY is in the"
echo "Secret — SecretSynced alone proves only that the sync ran:"
echo "  bash scripts/onprem-kubectl.sh op-prod -- -n argocd get externalsecret argocd-repo-risingwave-pipeline"
echo "  bash scripts/onprem-kubectl.sh op-prod -- -n argocd get secret argocd-repo-risingwave-pipeline -o jsonpath='{.data.sshPrivateKey}' | base64 -d | head -1"
