#!/usr/bin/env bash
# Build the AWS SSO kubeconfig for op-usxpress-prod.  READ ONLY against AWS and
# the cluster; the only thing it writes is the kubeconfig file itself.
#
#   scripts/build-prod-sso-kubeconfig.sh
#
# WHY THIS EXISTS
#   INFRA-1661 landed the apiserver webhook flags on prod 2026-10-27, so the API
#   server will now ask aws-iam-authenticator about bearer tokens. That is the
#   mechanism. The PROPERTY is that a human logs in as themselves -- and nobody
#   has one of these files for prod, so nobody has proven it.
#
# Three things it refuses to guess, because each produces a confusing auth
# failure rather than a clear one:
#   * the ROLE, read from the cluster's own aws-auth, not from this file;
#   * the PROFILE, resolved by which one actually assumes that role;
#   * the CLUSTER ID, read from the authenticator's live config -- `-i` is a
#     shared secret between client and server, and a wrong one is rejected with
#     a generic unauthorized.
set -uo pipefail

ACCOUNT=937464026810
ENDPOINT=10.10.82.52
BG="$HOME/.kube/op-usxpress-prod-breakglass.yaml"
OUT="$HOME/.kube/op-usxpress-prod-sso.yaml"
CTX=op-usxpress-prod-sso

say() { printf '%s\n' "$*"; }
die() { say "STOPPED - $*"; exit 1; }

command -v aws-iam-authenticator >/dev/null 2>&1 \
  || die "aws-iam-authenticator is not on PATH. The kubeconfig would be written
   and then fail at every command with 'executable not found', which reads like
   a cluster problem. Install it first."
[ -f "$BG" ] || die "no break-glass kubeconfig at $BG -- run scripts/breakglass-prod-kubeconfig.sh first"

kubectl --kubeconfig="$BG" get --raw /version >/dev/null 2>&1 \
  || die "the break-glass kubeconfig does not answer. Check the VPN before anything else."

# --- 1. the role, from the cluster -------------------------------------------
MAP=$(kubectl --kubeconfig="$BG" -n kube-system get cm aws-auth -o jsonpath='{.data.mapRoles}' 2>/dev/null)
[ -n "$MAP" ] || die "aws-auth has no mapRoles on this cluster"
# Uncommented rolearn lines only: the operator and reader tiers are commented
# out pending permission sets that do not exist, and a commented ARN is not a
# grant. Matching one would send us hunting a profile for a role nobody has.
ROLEARN=$(printf '%s\n' "$MAP" | grep -E '^[[:space:]]*-[[:space:]]*rolearn:' | head -1 | sed 's/.*rolearn:[[:space:]]*//')
[ -n "$ROLEARN" ] || die "every rolearn in aws-auth is commented out -- there is no tier to log in as"
ROLENAME=${ROLEARN##*/}
say "role in aws-auth:  $ROLENAME"

# --- 2. the profile, by which one assumes that role --------------------------
# Three profiles point at this account with different permission sets. Name and
# iteration order are both accidents; the ARN that comes back is the fact.
# sso_role_name is readable from ~/.aws/config WITHOUT a session, so the
# profile that WOULD work can be named even when nobody is signed in to it.
# The first version of this loop did `|| continue` on a failed
# get-caller-identity, which silently dropped exactly that profile -- it
# reported the two signed-in profiles as the wrong role and never mentioned
# the un-signed-in one whose name matched. A skipped candidate is information.
PROFILE=""; WANTLOGIN=""
WANTROLE=$(printf '%s' "$ROLENAME" | sed -E 's/^AWSReservedSSO_//; s/_[0-9a-f]{16}$//')
for P in $(aws configure list-profiles 2>/dev/null); do
  [ "$(aws configure get sso_account_id --profile "$P" 2>/dev/null)" = "$ACCOUNT" ] || continue
  CFGROLE=$(aws configure get sso_role_name --profile "$P" 2>/dev/null)
  if ARN=$(aws --profile "$P" sts get-caller-identity --query Arn --output text 2>/dev/null); then
    case "$ARN" in
      *"$ROLENAME"*) PROFILE="$P"; say "profile:           $P  (assumes $ROLENAME)"; break ;;
      *) say "   $P  signed in as ${ARN##*/}@${CFGROLE:-?} -- not $WANTROLE" ;;
    esac
  else
    say "   $P  configured for ${CFGROLE:-an unknown role}, NOT SIGNED IN"
    [ "$CFGROLE" = "$WANTROLE" ] && WANTLOGIN="$P"
  fi
done
if [ -z "$PROFILE" ] && [ -n "$WANTLOGIN" ]; then
  die "profile '$WANTLOGIN' is configured for $WANTROLE but has no live session.
   That is a login, not a permissions problem:
     aws sso login --profile $WANTLOGIN
   then re-run this script."
fi
[ -n "$PROFILE" ] || die "no profile for account $ACCOUNT assumes $ROLENAME.
   This is a permission-set question, not a missing file: the $WANTROLE set has
   to be assigned to you in account $ACCOUNT. The profiles above show what you
   do have -- AWSAdministratorAccess is NOT a substitute, because aws-auth maps
   this one specific role ARN and nothing else."

# --- 3. the cluster ID, from the authenticator's own config ------------------
CID=$(kubectl --kubeconfig="$BG" -n kube-system get cm -o jsonpath='{range .items[*]}{.data.config\.yaml}{"\n"}{end}' 2>/dev/null \
      | grep -iE '^[[:space:]]*clusterID:' | head -1 | sed 's/.*clusterID:[[:space:]]*//' | tr -d '"'"'"'')
if [ -z "$CID" ]; then
  CID=$(kubectl --kubeconfig="$BG" -n kube-system get ds -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].args}{"\n"}{end}' 2>/dev/null \
        | tr ',' '\n' | grep -A1 -i 'cluster-id' | grep -oE 'op-usxpress-[a-z0-9]+' | head -1)
fi
[ -n "$CID" ] || die "could not read the authenticator's clusterID from the cluster.
   Do not guess it: '-i' must match the server exactly or every login is
   rejected as unauthorized, which looks identical to a missing grant."
say "cluster id:        $CID"

# --- 4. build it, reusing break-glass's server and CA ------------------------
SRV=$(kubectl --kubeconfig="$BG" config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl --kubeconfig="$BG" config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
case "$SRV" in *"$ENDPOINT"*) ;; *) die "break-glass server is $SRV, not $ENDPOINT -- that is not op-usxpress-prod" ;; esac
[ -n "$CA" ] || die "break-glass kubeconfig has no inline CA to copy"

umask 077
cat > "$OUT" <<YAML
apiVersion: v1
kind: Config
clusters:
- name: op-usxpress-prod
  cluster:
    server: $SRV
    certificate-authority-data: $CA
users:
- name: $CTX
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws-iam-authenticator
      args: ["token", "-i", "$CID"]
      env:
      - name: AWS_PROFILE
        value: $PROFILE
      interactiveMode: IfAvailable
      provideClusterInfo: false
contexts:
- name: $CTX
  context:
    cluster: op-usxpress-prod
    user: $CTX
current-context: $CTX
YAML
chmod 600 "$OUT"
say "wrote:             $OUT"

# --- 5. prove it ------------------------------------------------------------
# A written file is not a working login. This is the property the whole ticket
# was about, so it is measured here and not left to the reader.
say ""
say "-- auth whoami through SSO (no certificate involved)"
if kubectl --kubeconfig="$OUT" auth whoami 2>&1; then
  say ""
  say "PASS. That username came from your AWS SSO session, not a cert."
else
  say ""
  say "The file is written but the login did not work. Read the error above:"
  say "  'executable not found'  -> aws-iam-authenticator is not on PATH"
  say "  'Unauthorized'          -> the token was rejected: wrong cluster id,"
  say "                             or the role is not the one aws-auth maps"
  say "  'expired'               -> aws sso login --profile $PROFILE"
  exit 1
fi
