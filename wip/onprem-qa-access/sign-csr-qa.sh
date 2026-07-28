#!/usr/bin/env bash
# Sign a user CSR against op-usxpress-qa and print the three public artifacts to send back.
#
#   ./sign-csr-qa.sh <USER_CN> <PATH_TO_CSR> [admin|operator|reader]
#   ./sign-csr-qa.sh idris-fagbemi ~/onprem-access/idris-fagbemi.csr admin
#
# Signs ONLY. It never creates a ClusterRoleBinding — the group-keyed bindings already
# exist in Flux (infrastructure/rbac on the op-qa branch). The tier comes from the O=
# values the user put in their own CSR; this script verifies they match the tier you
# asked for and refuses otherwise, so a typo cannot silently issue an admin cert.
#
# Everything this prints is public. Private key material never reaches this machine.
set -euo pipefail

USER_CN="${1:?usage: sign-csr-qa.sh <USER_CN> <PATH_TO_CSR> [admin|operator|reader]}"
CSR_PATH="${2:?usage: sign-csr-qa.sh <USER_CN> <PATH_TO_CSR> [admin|operator|reader]}"
TIER="${3:-reader}"

# op-usxpress-qa has no context in the default kubeconfig and never has. The working
# config is derived from tfstate (see wip/onprem-qa-access/README.md § 3), so its context
# NAME comes from Terraform and is not a stable thing to guard on. Guard on the endpoint.
#   export KUBECONFIG=~/.kube/op-usxpress-qa.yaml
QA_SERVER="https://10.10.82.51:6443"

case "$TIER" in
  # Admin certs are deliberately short-lived: with group-keyed bindings there is no
  # per-user revocation short of rolling the CA, so expiry IS the revocation control.
  admin)    REQUIRED_O="onprem-platform-admins";    EXPIRY=7776000  ;;  # 90 days
  operator) REQUIRED_O="onprem-platform-operators"; EXPIRY=15552000 ;;  # 180 days
  reader)   REQUIRED_O="onprem-platform-users";     EXPIRY=31536000 ;;  # 1 year
  *) echo "ERROR: tier must be admin|operator|reader (got '$TIER')" >&2; exit 1 ;;
esac

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Guard 1: right cluster. Signing against dev (.50 — ONE DIGIT OFF) issues a cert that
# looks fine and works nowhere. The endpoint is the only thing worth trusting here.
LIVE_SERVER="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$LIVE_SERVER" == "$QA_SERVER" ]] || die "kubectl points at '$LIVE_SERVER', expected '$QA_SERVER' — export KUBECONFIG=~/.kube/op-usxpress-qa.yaml"
echo "Cluster:  $LIVE_SERVER  (context '$(kubectl config current-context)', KUBECONFIG=${KUBECONFIG:-~/.kube/config})"

# --- Guard 2: we can actually sign. Without this the CSR gets created and then the approve
# fails, leaving a dangling CSR to clean up by hand.
kubectl auth can-i approve certificatesigningrequests.certificates.k8s.io/kubernetes.io/kube-apiserver-client >/dev/null \
  || die "this identity cannot approve kube-apiserver-client CSRs — need the system:masters kubeconfig from tfstate"

# --- Guard 3: the CSR is a CSR, and its subject is what we expect.
[[ -f "$CSR_PATH" ]] || die "no CSR at $CSR_PATH"
openssl req -in "$CSR_PATH" -noout -verify >/dev/null 2>&1 || die "$CSR_PATH is not a valid CSR (paste mangled?)"

SUBJECT="$(openssl req -in "$CSR_PATH" -noout -subject)"
echo "CSR subject: $SUBJECT"
grep -q "CN *= *${USER_CN}\b"    <<<"$SUBJECT" || die "CSR CN does not match '$USER_CN' — do not sign"
grep -q "O *= *${REQUIRED_O}\b"  <<<"$SUBJECT" || die "CSR lacks O=${REQUIRED_O} for tier '$TIER' — have them regenerate"
grep -q "O *= *onprem-platform-users\b" <<<"$SUBJECT" || die "CSR lacks the baseline O=onprem-platform-users"

# --- Guard 4: the group-keyed binding must already exist, or the cert grants nothing.
kubectl get clusterrolebinding "$REQUIRED_O" >/dev/null 2>&1 \
  || die "ClusterRoleBinding '$REQUIRED_O' not found — land infrastructure/rbac via Flux first"

WORKDIR="$HOME/onprem-access/$USER_CN"
mkdir -p "$WORKDIR"

echo "Signing $USER_CN as '$TIER' ($((EXPIRY / 86400)) days) on $LIVE_SERVER ..."
kubectl delete csr "$USER_CN" --ignore-not-found

kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_CN}
spec:
  request: $(base64 -w 0 < "$CSR_PATH")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: ${EXPIRY}
  usages:
    - client auth
EOF

kubectl certificate approve "$USER_CN"

# The controller issues asynchronously; poll rather than sleep-and-hope.
for _ in $(seq 1 30); do
  CERT_B64="$(kubectl get csr "$USER_CN" -o jsonpath='{.status.certificate}')"
  [[ -n "$CERT_B64" ]] && break
  sleep 1
done
[[ -n "${CERT_B64:-}" ]] || die "CSR approved but no certificate issued after 30s — check kube-controller-manager"

base64 -d <<<"$CERT_B64" > "$WORKDIR/$USER_CN.crt"
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > "$WORKDIR/op-usxpress-qa-ca.crt"

echo
openssl x509 -in "$WORKDIR/$USER_CN.crt" -noout -subject -dates

# --- Post-check: prove the grant landed, via the GROUP, before telling anyone it works.
echo
echo "Effective access check (impersonation):"
case "$TIER" in
  admin)    kubectl auth can-i '*' '*' --as="$USER_CN" --as-group="$REQUIRED_O" ;;
  operator) kubectl auth can-i delete deployments --as="$USER_CN" --as-group="$REQUIRED_O" ;;
  reader)   kubectl auth can-i list pods -A --as="$USER_CN" --as-group="$REQUIRED_O" ;;
esac
echo -n "  can read secrets (expect 'no' unless admin): "
kubectl auth can-i list secrets -A --as="$USER_CN" --as-group="$REQUIRED_O"

cat <<BANNER

==========================================================
Send these to $USER_CN (all public — Teams/Slack is fine):
==========================================================

Server URL:
  $QA_SERVER

----- SIGNED CERT (save as ~/.kube/keys/$USER_CN-qa.crt) -----
$(cat "$WORKDIR/$USER_CN.crt")

----- CLUSTER CA (save as ~/.kube/keys/op-usxpress-qa-ca.crt) -----
$(cat "$WORKDIR/op-usxpress-qa-ca.crt")

Reminder: set a calendar reminder 30 days before notAfter above.
Record the issuance in wip/onprem-qa-access/README.md § 6.
BANNER
