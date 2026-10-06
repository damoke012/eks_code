#!/usr/bin/env bash
# Read-only. Every cert-manager Certificate on all three on-prem clusters, with the only
# field that decides whether a browser trusts it: status.notAfter.
#
# Ready=True does NOT mean valid. cert-manager leaves Ready=True on a certificate it has
# failed to renew, and the condition never flips when the stored cert expires.
#
# ENVIRONMENTS: op-usxpress-dev, op-usxpress-qa, op-usxpress-prod. Read-only on all three.
set -uo pipefail
NOW=$(date -u +%s)

check() {
  local label="$1" kubeconfig="$2" ctxflag="$3" expect="$4"
  echo
  echo "############ $label ############"
  export KUBECONFIG="$kubeconfig"
  local info
  info=$(kubectl $ctxflag cluster-info 2>&1 | head -1)
  echo "$info"
  case "$info" in
    *"$expect"*) : ;;
    *) echo "SKIP: endpoint does not contain $expect -- wrong cluster or no credentials."; return ;;
  esac

  echo
  printf '%-34s %-28s %-7s %-22s %s\n' NAMESPACE NAME READY NOT_AFTER VERDICT
  kubectl $ctxflag get certificates.cert-manager.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.notAfter}{"\n"}{end}' \
  | while IFS=$'\t' read -r ns name ready notafter; do
      [ -z "${name:-}" ] && continue
      local verdict days exp
      if [ -z "${notafter:-}" ]; then
        verdict="NO notAfter -- never issued"
      else
        exp=$(date -u -d "$notafter" +%s 2>/dev/null) || exp=""
        if [ -z "$exp" ]; then
          verdict="unparseable"
        else
          days=$(( (exp - NOW) / 86400 ))
          if   [ "$days" -lt 0 ]  ; then verdict="*** EXPIRED ${days#-}d AGO ***"
          elif [ "$days" -lt 15 ] ; then verdict="!! expires in ${days}d"
          else                           verdict="ok (${days}d)"
          fi
        fi
      fi
      printf '%-34s %-28s %-7s %-22s %s\n' "$ns" "$name" "$ready" "${notafter:--}" "$verdict"
    done

  echo
  echo "-- CertificateRequests not Ready (why renewal is not happening) --"
  kubectl $ctxflag get certificaterequests.cert-manager.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.conditions[?(@.type=="Ready")].reason}{"\t"}{.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}' \
    2>/dev/null | awk -F'\t' '$3!="True"' | head -20
  echo "(empty above = no failing requests; renewal may not have been ATTEMPTED at all)"

  echo
  echo "-- ACME Orders / Challenges still pending --"
  kubectl $ctxflag get orders.acme.cert-manager.io,challenges.acme.cert-manager.io -A 2>/dev/null | head -20

  echo
  echo "-- cert-manager controller: is it running, and what is it saying --"
  kubectl $ctxflag get pods -A -l app.kubernetes.io/name=cert-manager \
    -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,AGE:.metadata.creationTimestamp' 2>/dev/null
  kubectl $ctxflag -n cert-manager logs -l app.kubernetes.io/name=cert-manager --tail=25 2>/dev/null \
    | grep -iE "error|fail|expir|renew|order|challenge" | tail -15
  echo "(no log lines above = nothing matching; not proof of health)"
}

check "op-usxpress-dev  (on-prem, 10.10.82.50)"  "$HOME/.kube/op-usxpress-dev-fresh.yaml" ""                              "10.10.82.50"
check "op-usxpress-qa   (on-prem, 10.10.82.51)"  "$HOME/.kube/op-usxpress-qa.yaml"        "--context admin@op-usxpress-qa"   "10.10.82.51"
check "op-usxpress-prod (on-prem, 10.10.82.52)"  "$HOME/.kube/op-usxpress-prod.yaml"      "--context admin@op-usxpress-prod" "10.10.82.52"

echo
echo "############ what a browser actually gets ############"
for u in argocd.op-dev.usxpress.io risingwave-dashboard.op-dev.usxpress.io \
         risingwave-overview.op-dev.usxpress.io grafana.op-dev.usxpress.io \
         argocd.op-qa.usxpress.io argocd.op-prod.usxpress.io; do
  printf '%-45s ' "$u"
  curl -s -o /dev/null -w 'http=%{http_code} verify=%{ssl_verify_result}\n' --max-time 8 "https://$u/" \
    || echo "TLS REJECTED (verify!=0 means a browser shows Not secure)"
done
echo
echo "verify=0 trusted | 10 expired | 18 self-signed | 19 self-signed in chain | 20 no issuer cert"
