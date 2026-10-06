#!/usr/bin/env bash
# ENVIRONMENT: op-usxpress-dev ONLY (on-prem Talos, 10.10.82.50). Aborts on anything else.
#
# cert-manager's ServiceAccount carries the IRSA role annotation, but the running pod has no
# AWS_ROLE_ARN -- pod-identity-webhook is failurePolicy:Ignore and was unavailable when the
# pod was created on 2026-06-19, so it started with no AWS identity and has run that way for
# 109 days. Six certificates expired behind it while every object reported Ready.
#
# Restarting only works if the webhook is healthy NOW. Restarting into a broken webhook
# reproduces the identical silent state, which is why step 1 aborts rather than warns.
#
#   bash fix-dev-certmanager-irsa.sh          # read-only: checks, changes nothing
#   bash fix-dev-certmanager-irsa.sh --go     # restarts cert-manager, reissues the six
set -uo pipefail
GO=0; [ "${1:-}" = "--go" ] && GO=1
export KUBECONFIG="$HOME/.kube/op-usxpress-dev-fresh.yaml"

step() { echo; echo "=== $* ==="; }
die()  { echo; echo "ABORT: $*"; exit 1; }

step "0. prove the cluster is op-usxpress-dev"
INFO=$(kubectl cluster-info 2>&1 | head -1); echo "$INFO"
case "$INFO" in *10.10.82.50*) echo "OK: op-usxpress-dev" ;; *) die "not op-usxpress-dev." ;; esac

step "1. is pod-identity-webhook healthy RIGHT NOW"
kubectl -n pod-identity-webhook get pods \
  -o custom-columns='POD:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount'
READY=$(kubectl -n pod-identity-webhook get pods \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' | grep -c '^true$')
echo "ready pods: $READY"
EP=$(kubectl -n pod-identity-webhook get endpoints -o jsonpath='{.items[*].subsets[*].addresses[*].ip}')
echo "webhook endpoints: ${EP:-<NONE>}"
kubectl get mutatingwebhookconfigurations -o custom-columns='NAME:.metadata.name,POLICY:.webhooks[*].failurePolicy' | grep -i identity
[ "$READY" -ge 1 ] || die "pod-identity-webhook has no ready pod. Fix that FIRST -- a restart now would silently reproduce the same credential-less pod."
[ -n "$EP" ]       || die "pod-identity-webhook Service has no endpoints. Same reason."
echo "OK: webhook can inject."

step "2. current cert-manager pod: does it carry IRSA env"
POD=$(kubectl -n cert-manager get pod -l app.kubernetes.io/name=cert-manager -o jsonpath='{.items[0].metadata.name}')
echo "pod: $POD  (created $(kubectl -n cert-manager get pod "$POD" -o jsonpath='{.metadata.creationTimestamp}'))"
BEFORE=$(kubectl -n cert-manager get pod "$POD" -o jsonpath='{.spec.containers[*].env[*].name}' | tr ' ' '\n' | grep -c '^AWS_')
echo "AWS_* env vars present: $BEFORE   (expected 0 before the fix, >=2 after)"

if [ "$GO" -eq 0 ]; then
  echo; echo "READ-ONLY. Re-run with --go to restart cert-manager and reissue the six certificates."
  exit 0
fi

step "3. restart cert-manager so the webhook can inject credentials"
kubectl -n cert-manager rollout restart deploy cert-manager
kubectl -n cert-manager rollout status deploy cert-manager --timeout=180s || die "rollout did not complete."

step "4. VERIFY the new pod actually got the credentials"
NEWPOD=$(kubectl -n cert-manager get pod -l app.kubernetes.io/name=cert-manager -o jsonpath='{.items[0].metadata.name}')
kubectl -n cert-manager get pod "$NEWPOD" -o jsonpath='{range .spec.containers[*]}{range .env[*]}{.name}{"\n"}{end}{end}' | grep '^AWS_' || true
AFTER=$(kubectl -n cert-manager get pod "$NEWPOD" -o jsonpath='{.spec.containers[*].env[*].name}' | tr ' ' '\n' | grep -c '^AWS_')
echo "AWS_* env vars now: $AFTER"
[ "$AFTER" -ge 2 ] || die "the new pod STILL has no IRSA env. The webhook is not injecting; do not proceed -- this is now a webhook problem, not a cert problem."
echo "OK: credentials injected."

step "5. clear the stuck requests so cert-manager issues fresh ones"
# These are derived objects. The Certificate recreates them; the expired Secrets stay in
# place until a new certificate replaces them, so nothing that works today stops working.
kubectl get certificaterequests.cert-manager.io -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
  | awk '$3!="True" {print $1, $2}' | while read -r ns name; do
      echo "deleting certificaterequest $ns/$name"; kubectl -n "$ns" delete certificaterequest.cert-manager.io "$name" --wait=false
    done
kubectl get orders.acme.cert-manager.io -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.state}{"\n"}{end}' \
  | awk '$3!="valid" {print $1, $2}' | while read -r ns name; do
      echo "deleting order $ns/$name"; kubectl -n "$ns" delete order.acme.cert-manager.io "$name" --wait=false
    done

step "6. watch issuance (DNS-01 through Route53 takes a few minutes)"
echo "run this until every row says valid:"
echo "  kubectl get orders.acme.cert-manager.io -A"
echo "then re-run the expiry check:"
echo "  bash ~/check-cert-expiry.sh"
echo
echo "the only verdict that counts -- a browser trusting it:"
echo "  for u in argocd grafana risingwave-dashboard risingwave-overview; do printf '%-24s ' \$u; curl -s -o /dev/null -w 'verify=%{ssl_verify_result}\\n' --max-time 8 https://\$u.op-dev.usxpress.io/ || echo REJECTED; done"
echo "verify=0 is the fix. Anything else is not."
