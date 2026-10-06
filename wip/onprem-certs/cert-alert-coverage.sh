#!/usr/bin/env bash
# Read-only. For each on-prem cluster: is cert-manager scraped, which certificate rules exist,
# and what is currently matching. Answers "do QA and prod have this" without assuming.
#
# ENVIRONMENTS: op-usxpress-dev, op-usxpress-qa, op-usxpress-prod. Read-only on all three.
set -uo pipefail
PROXY="/api/v1/namespaces/prometheus/services/prometheus-operated:9090/proxy/api/v1"

check() {
  local label="$1" kubeconfig="$2" ctx="$3" expect="$4"
  echo; echo "############ $label ############"
  export KUBECONFIG="$kubeconfig"
  local info; info=$(kubectl $ctx cluster-info 2>&1 | head -1); echo "$info"
  case "$info" in *"$expect"*) : ;; *) echo "SKIP: endpoint lacks $expect"; return ;; esac

  echo
  echo "-- 1. does ANY ServiceMonitor select cert-manager --"
  kubectl $ctx get servicemonitors.monitoring.coreos.com -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.selector.matchLabels}{"\n"}{end}' \
    | grep -i cert || echo "  NONE -- every certmanager_ rule here is inert"

  echo
  echo "-- 2. every PrometheusRule group mentioning certificates --"
  kubectl $ctx get prometheusrules.monitoring.coreos.com -A -o json \
    | python3 -c "
import sys,json
found=False
for i in json.load(sys.stdin)['items']:
    for g in i['spec'].get('groups',[]):
        names=[r.get('alert') for r in g.get('rules',[]) if r.get('alert')]
        if 'cert' in g['name'].lower() or any('ertificate' in (n or '') for n in names):
            found=True
            print('  %-42s group=%-22s %s' % (i['metadata']['namespace']+'/'+i['metadata']['name'], g['name'], names))
if not found: print('  NONE')
"

  echo
  echo "-- 3. is the metric actually being collected (the only honest test) --"
  n=$(kubectl $ctx -n prometheus get --raw "$PROXY/query?query=count(certmanager_certificate_expiration_timestamp_seconds)" 2>/dev/null \
      | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(int(float(r[0]["value"][1])) if r else 0)' 2>/dev/null) || n="?"
  echo "  certificates with a series: ${n}   (0 = nothing is scraped; every rule above is dead)"

  echo
  echo "-- 4. certificate alerts pending or firing RIGHT NOW --"
  kubectl $ctx -n prometheus get --raw "$PROXY/alerts" 2>/dev/null \
    | python3 -c "
import sys,json
a=[x for x in json.load(sys.stdin)['data']['alerts'] if 'ertificate' in x['labels'].get('alertname','')]
if not a: print('  none')
for x in a:
    l=x['labels']
    print('  %-8s %-26s %-18s %s' % (x['state'], l.get('alertname',''), l.get('exported_namespace') or l.get('namespace',''), l.get('name','')))
" 2>/dev/null || echo "  (could not read alerts)"

  echo
  echo "-- 5. expiry, so we know what WOULD fire on promotion --"
  kubectl $ctx get certificates.cert-manager.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.notAfter}{"\n"}{end}' \
  | python3 -c "
import sys,datetime
now=datetime.datetime.now(datetime.timezone.utc)
for line in sys.stdin:
    p=line.rstrip('\n').split('\t')
    if len(p)<3 or not p[1]: continue
    ns,name,na=p[0],p[1],p[2]
    if not na: print('  %-20s %-34s NEVER ISSUED' % (ns,name)); continue
    d=(datetime.datetime.fromisoformat(na.replace('Z','+00:00'))-now).days
    if d<15: print('  %-20s %-34s %sd %s' % (ns,name,d,'<-- WOULD ALERT'))
"
}

check "op-usxpress-dev  (10.10.82.50)"  "$HOME/.kube/op-usxpress-dev-fresh.yaml" ""                                 "10.10.82.50"
check "op-usxpress-qa   (10.10.82.51)"  "$HOME/.kube/op-usxpress-qa.yaml"        "--context admin@op-usxpress-qa"   "10.10.82.51"
check "op-usxpress-prod (10.10.82.52)"  "$HOME/.kube/op-usxpress-prod.yaml"      "--context admin@op-usxpress-prod" "10.10.82.52"
