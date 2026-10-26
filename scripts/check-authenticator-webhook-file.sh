#!/usr/bin/env bash
# Is the aws-iam-authenticator webhook kubeconfig actually on every
# control-plane node?  READ ONLY.
#
#   scripts/check-authenticator-webhook-file.sh qa      # positive control
#   scripts/check-authenticator-webhook-file.sh prod    # the question
#
# WHY THIS EXISTS
#   The kube-apiserver flag --authentication-token-webhook-config-file names a
#   HOST path. If that file is absent when the flag lands, the API server does
#   not start. The DaemonSet writes it, so "DaemonSet 3/3" is the writer being
#   healthy, not the file existing -- and on 2026-10-26 the obvious check,
#   `kubectl exec ... ls`, returned `ls: executable file not found`: the image
#   is distroless. That is the instrument failing, not a finding about the file.
#
#   RUN qa FIRST. QA already carries the flag and its API server is up, so QA
#   MUST show the file. If it does not, this script is wrong -- not the cluster.
#
# It makes no call that writes to a cluster or to AWS. It never prints the
# talosconfig; only whether it starts with 'context:' and what the node says.
set -uo pipefail

ENV="${1:-}"
case "$ENV" in
  prod) ACCOUNT=937464026810; ENDPOINT=10.10.82.52 ;;
  qa)   ACCOUNT=527101283767; ENDPOINT=10.10.82.51 ;;
  *)    echo "usage: $0 qa|prod   (qa is the positive control; run it first)"; exit 2 ;;
esac
REGION=us-east-2
SECRET="op-usxpress-$ENV/talosconfig"
HOSTDIR=/var/lib/aws-iam-authenticator
WANT=kubeconfig.yaml

say() { printf '%s\n' "$*"; }
nm()  { say "NOT MEASURED - $*"; exit 3; }

say "== op-usxpress-$ENV   endpoint $ENDPOINT   account $ACCOUNT"

command -v talosctl >/dev/null 2>&1 || nm "talosctl absent on this box; not a missing file"
command -v aws      >/dev/null 2>&1 || nm "aws absent on this box; not a missing file"

# --- the AWS profile, resolved by account id and never by name ---------------
PROFILE=""
for P in $(aws configure list-profiles 2>/dev/null); do
  ID=$(aws --profile "$P" sts get-caller-identity --query Account --output text 2>/dev/null || true)
  if [ "$ID" = "$ACCOUNT" ]; then PROFILE="$P"; break; fi
done
[ -n "$PROFILE" ] || nm "no configured profile resolves to account $ACCOUNT right now.
   If a profile for it exists, its session has expired: aws sso login --profile <it>.
   If none exists, a login cannot help -- it must be added to ~/.aws/config."
say "profile: $PROFILE"

# --- the talosconfig ---------------------------------------------------------
TC=$(mktemp -t talosconfig.XXXXXX) || nm "cannot create a temp file"
trap 'rm -f "$TC"' EXIT
chmod 600 "$TC"
aws --profile "$PROFILE" --region "$REGION" secretsmanager get-secret-value \
    --secret-id "$SECRET" --query SecretString --output text > "$TC" 2>/dev/null \
  || nm "cannot read secret $SECRET in account $ACCOUNT"
# A green fetch is not a usable value: this secret held a literal placeholder
# for weeks while everything downstream reported success.
head -c 8 "$TC" | grep -q '^context' \
  || nm "$SECRET does not start with 'context:' -- it is a placeholder, not a config"
say "talosconfig: fetched, starts with 'context:'"

# --- which nodes are control planes -----------------------------------------
# Taken from the live cluster, not from a list in this file: the IPs differ per
# environment and a hardcoded one would silently measure the wrong host.
KC=""
for f in "$HOME"/.kube/*.yaml "$HOME"/.kube/*.yml; do
  [ -f "$f" ] || continue
  S=$(kubectl --kubeconfig="$f" config view -o jsonpath='{.clusters[*].cluster.server}' 2>/dev/null)
  [ "$(echo "$S" | wc -w)" = "1" ] || continue
  case "$S" in *"$ENDPOINT:6443"*) KC="$f"; break ;; esac
done

IPS=""
if [ -n "$KC" ]; then
  IPS=$(kubectl --kubeconfig="$KC" get nodes -l node-role.kubernetes.io/control-plane \
        -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}' 2>/dev/null)
fi
N=$(echo "$IPS" | wc -w)
if [ "$N" -lt 1 ]; then
  say "no control-plane IPs from a kubeconfig; falling back to the endpoint alone"
  say "   WARNING: that is ONE node, not the control plane. Not a population."
  IPS="$ENDPOINT"; N=1
fi
say "control-plane nodes: $N -> $IPS"

# --- the actual question -----------------------------------------------------
say "-- $HOSTDIR/$WANT on each node"
OK=0; BAD=0; UNK=0
for IP in $IPS; do
  R=$(talosctl --talosconfig "$TC" -e "$ENDPOINT" -n "$IP" list -l "$HOSTDIR" 2>&1)
  if printf '%s' "$R" | grep -q "$WANT"; then
    say "   $IP  PRESENT  $(printf '%s' "$R" | grep "$WANT" | tail -1 | tr -s ' ')"
    OK=$((OK+1))
  elif printf '%s' "$R" | grep -qiE 'x509|handshake|certificate|unauthenticated|deadline'; then
    say "   $IP  NOT MEASURED  talos API refused us: $(printf '%s' "$R" | head -c 90)"
    UNK=$((UNK+1))
  else
    say "   $IP  ABSENT   $(printf '%s' "$R" | head -c 120)"
    BAD=$((BAD+1))
  fi
done

say "-- present=$OK absent=$BAD not-measured=$UNK  (want present=$N)"
if [ "$UNK" -gt 0 ]; then
  say "VERDICT: NOT MEASURED. The Talos API would not talk to us on $UNK node(s)."
  exit 3
elif [ "$BAD" -gt 0 ]; then
  say "VERDICT: FAIL. $BAD node(s) have no $WANT."
  say "  Do NOT land the apiserver flag: it would not restart on those nodes."
  exit 1
else
  say "VERDICT: PASS on all $N control-plane nodes."
  [ "$ENV" = "qa" ] && say "  qa is the control, so the method is sound. Now run: $0 prod"
  exit 0
fi
