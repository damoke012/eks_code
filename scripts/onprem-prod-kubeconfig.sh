#!/usr/bin/env bash
# INFRA-1663 -- rebuild a kubeconfig for op-usxpress-prod from its talosconfig.
#
# op-prod has had no persisted kubeconfig on this workstation since at least
# 2026-08-24, which is why prod's node addresses, ingressgateway placement and
# ClusterSecretStore could only be inferred from Git today -- and Git is
# demonstrably wrong about this cluster (all 5 of its VirtualServices carry op-dev
# hostnames).
#
# The credentials exist: op-usxpress-prod/talosconfig, in Secrets Manager, readable
# with the prod profile. talosctl mints a real kubeconfig from it -- correct CA,
# correct endpoint, nothing inferred.
#
# The talosconfig is written 0600 to a temp file and shredded on exit. Nothing is
# printed. This READS prod credentials and CREATES a local file; it changes nothing
# in the cluster or the account.
#
#   scripts/onprem-prod-kubeconfig.sh ops-controller
set -euo pipefail
PROFILE="${1:-}"
ENDPOINT=10.10.82.52
CLUSTER=op-usxpress-prod
ACCOUNT=937464026810
REGION=us-east-2
SECRET="$CLUSTER/talosconfig"
OUT="$HOME/.kube/$CLUSTER.yaml"

[ -n "$PROFILE" ] || { echo "!! usage: $0 <aws-profile-for-$ACCOUNT>" >&2; exit 2; }
for c in aws talosctl kubectl; do
  command -v "$c" >/dev/null 2>&1 || { echo "!! $c not on PATH" >&2; exit 2; }
done

ACCT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>&1)
case "$ACCT" in
  *"SSO session"*|*"Token has expired"*)
    echo "!! '$PROFILE' has an expired SSO session: aws sso login --profile $PROFILE" >&2; exit 2 ;;
esac
[ "$ACCT" = "$ACCOUNT" ] || { echo "!! '$PROFILE' is account $ACCT, not $CLUSTER ($ACCOUNT)" >&2; exit 2; }

echo "== $ENDPOINT:6443 reachable?"
if ! nc -vz -w 5 "$ENDPOINT" 6443 2>&1 | tail -1; then
  echo "!! cannot reach $ENDPOINT:6443 -- check the corp VPN before anything else." >&2
  exit 1
fi

TC=$(mktemp); chmod 600 "$TC"
cleanup() { command -v shred >/dev/null 2>&1 && shred -u "$TC" 2>/dev/null || rm -f "$TC"; }
trap cleanup EXIT

echo "== fetching $SECRET ($ACCOUNT, $REGION)"
# The stored value may be the raw talosconfig or JSON wrapping it. Handle both
# without ever echoing the content.
aws secretsmanager get-secret-value --profile "$PROFILE" --region "$REGION" \
  --secret-id "$SECRET" --query SecretString --output text > "$TC" || {
  echo "!! could not read $SECRET. If this is AccessDenied, grant it with:" >&2
  echo "   ALLOW_PROD_WRITE=yes scripts/idc-grant-secretsmanager.sh op-prod --apply" >&2
  exit 1; }

python3 - "$TC" <<'PY'
import json, sys
p = sys.argv[1]
raw = open(p).read()
try:
    d = json.loads(raw)
    if isinstance(d, dict):
        # one key, whose value is the talosconfig
        v = next(iter(d.values()))
        open(p, "w").write(v)
except (json.JSONDecodeError, StopIteration):
    pass
head = open(p).read(200)
assert "context" in head or "contexts" in head, \
    "the stored value does not look like a talosconfig (no contexts key)"
PY
echo "   looks like a talosconfig ($(wc -c < "$TC") bytes)"

echo "== asking Talos for a kubeconfig"
mkdir -p "$HOME/.kube"
talosctl --talosconfig "$TC" --nodes "$ENDPOINT" --endpoints "$ENDPOINT" \
  kubeconfig --force "$OUT" || {
  echo "!! talosctl could not mint a kubeconfig. The talosconfig may be for a" >&2
  echo "   different cluster, or its certificates may have expired." >&2
  exit 1; }
chmod 600 "$OUT"
echo "   wrote $OUT"

# Prove it is THIS cluster, by a live node name -- a config file can claim anything.
echo "== verifying against the live cluster"
CTX=$(kubectl --kubeconfig="$OUT" config current-context)
NODES=$(kubectl --kubeconfig="$OUT" --context="$CTX" get nodes -o name 2>&1) || {
  echo "$NODES" >&2; echo "!! kubeconfig written but the API did not answer" >&2; exit 1; }
echo "$NODES" | sed 's/^/   /'
printf '%s' "$NODES" | grep -q "prod" || {
  echo "!! no node name contains 'prod' -- this may not be $CLUSTER. Not trusting it." >&2
  exit 1; }
echo
echo "   $CLUSTER reachable as $CTX"
echo "   scripts/lib-onprem-ctx.sh resolves op-prod by endpoint, so every script that"
echo "   uses it now works against prod."
