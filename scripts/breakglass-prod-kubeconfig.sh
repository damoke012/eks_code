#!/usr/bin/env bash
# Break-glass READ-ONLY access to op-usxpress-prod.
#
# op-usxpress-prod has no routine human access path: aws-iam-authenticator is
# wired only on op-usxpress-qa (INFRA-1638 is the ticket to fix that). Until it
# lands, looking at prod at all means fetching the admin talosconfig from
# Secrets Manager. That is a real privilege, so this script:
#
#   * resolves the AWS profile by ACCOUNT ID rather than by name, so it cannot
#     quietly point at dev or QA — the three clusters differ by one digit
#     (.50 / .51 / .52) and by profile name only;
#   * writes to a dedicated kubeconfig, never ~/.kube/config, so a later
#     `kubectl delete` in another window cannot inherit cluster-admin on prod;
#   * makes no call that writes to the cluster or to AWS.
#
# It still hands you cluster-admin on production. Use it, look, and delete the
# file — the last line tells you how.
#
#   scripts/breakglass-prod-kubeconfig.sh
#   scripts/check-onprem-platform-state.sh \
#       --kubeconfig ~/.kube/op-usxpress-prod-breakglass.yaml \
#       --context admin@op-usxpress-prod
set -euo pipefail

ACCOUNT=937464026810          # op-usxpress-prod
REGION=us-east-2
ENDPOINT=10.10.82.52          # prod. dev is .50, qa is .51 — read it twice.
SECRET=op-usxpress-prod/talosconfig
OUT="$HOME/.kube/op-usxpress-prod-breakglass.yaml"
TC=$(mktemp -t talosconfig-prod.XXXXXX)
trap 'rm -f "$TC"' EXIT

command -v talosctl >/dev/null || { echo "!! talosctl not on PATH" >&2; exit 2; }
command -v aws      >/dev/null || { echo "!! aws not on PATH" >&2; exit 2; }

# --- resolve the profile by account, not by name -----------------------------
PROFILE=""
for P in $(aws configure list-profiles); do
  ID=$(aws --profile "$P" sts get-caller-identity --query Account --output text 2>/dev/null || true)
  if [ "$ID" = "$ACCOUNT" ]; then PROFILE="$P"; break; fi
done
if [ -z "$PROFILE" ]; then
  echo "!! no configured AWS profile currently resolves to account $ACCOUNT." >&2
  echo "   Run 'aws sso login --profile <the prod profile>' first, then re-run." >&2
  exit 2
fi
echo "profile:  $PROFILE  (account $ACCOUNT)"

# --- fetch the talosconfig ---------------------------------------------------
aws --profile "$PROFILE" --region "$REGION" secretsmanager get-secret-value \
    --secret-id "$SECRET" --query SecretString --output text > "$TC"
chmod 600 "$TC"

# A green fetch is not a usable value: prod stood up with a literal
# PLACEHOLDER_POPULATED_BY_TERRAFORM_ON_FIRST_APPLY in this secret, and
# etcd-backup synced green against it for weeks.
head -c 8 "$TC" | grep -q '^context' || {
  echo "!! $SECRET does not start with 'context:' — it is $(head -c 40 "$TC")..." >&2
  exit 1
}
echo "talosconfig: fetched, starts with 'context:'"

# --- derive a kubeconfig (read-only against the cluster) ---------------------
mkdir -p "$HOME/.kube"
rm -f "$OUT"
talosctl --talosconfig "$TC" -n "$ENDPOINT" -e "$ENDPOINT" kubeconfig "$OUT" >/dev/null
chmod 600 "$OUT"

CTX=$(kubectl --kubeconfig "$OUT" config current-context)
SRV=$(kubectl --kubeconfig "$OUT" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "kubeconfig:  $OUT"
echo "context:     $CTX"
echo "server:      $SRV"

case "$SRV" in
  *"$ENDPOINT"*) ;;
  *) echo "!! server is NOT $ENDPOINT — this is not op-usxpress-prod. Stopping." >&2; exit 1 ;;
esac

echo
echo "Next:"
echo "  scripts/check-onprem-platform-state.sh --kubeconfig $OUT --context $CTX"
echo "  scripts/check-flux-sources-current.sh  --kubeconfig $OUT --context $CTX"
echo
echo "When done, destroy it:"
echo "  shred -u $OUT 2>/dev/null || rm -f $OUT"
