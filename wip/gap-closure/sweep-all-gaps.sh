#!/usr/bin/env bash
# Every open platform gap, measured across all three on-prem clusters, in one pass.
#
# READ ONLY. No apply, no patch, no delete, no helm, no terraform. Safe on prod.
#
# Sections:
#   1 HELM   -- releases whose Helm history disagrees with Ready, plus the two silent
#               spec defaults (no .spec.timeout; install.remediation without
#               remediateLastFailure) and floating chart versions.
#   2 DNS    -- every VirtualService host on the cluster: does it resolve PUBLICLY,
#               and what does it actually serve (sha256 of the body)?
#   3 CERTS  -- days to expiry per Certificate, and what a browser really gets.
#   4 ALERTS -- is there an Alertmanager, does it have receivers, and is the IRSA
#               rule still the one that cannot fire?
#   5 IRSA   -- pods whose ServiceAccount is annotated with a role ARN but whose spec
#               carries no AWS_ROLE_ARN: the webhook failed open at pod creation.
#
# A transport failure is never reported as a finding. Each cluster is fingerprinted
# against its known endpoint before anything is read; a mismatch ABORTS that cluster.
set -uo pipefail

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; OFF=$'\033[0m'
GAPS=0
note() { printf '%s\n' "$*"; }
gap()  { GAPS=$((GAPS+1)); printf '%sGAP %s%s\n' "$RED" "$*" "$OFF"; }
ok()   { printf '%sOK  %s%s\n' "$GRN" "$*" "$OFF"; }
warn() { printf '%s??  %s%s\n' "$YEL" "$*" "$OFF"; }

hr() { printf '\n%s\n' "============================================================"; }

sweep() {
  local label="$1" kcfg="$2" ctxflag="$3" expect="$4" env="$5"
  hr; note "##### $label #####"

  if [ ! -r "$kcfg" ]; then
    warn "kubeconfig unreadable: $kcfg -- cluster SKIPPED, nothing concluded"; return
  fi
  export KUBECONFIG="$kcfg"

  local info
  info=$(kubectl $ctxflag cluster-info 2>&1)
  if ! printf '%s' "$info" | grep -q "$expect"; then
    warn "endpoint fingerprint $expect NOT found -- cluster SKIPPED, nothing concluded"
    printf '%s\n' "$info" | head -3
    return
  fi
  ok "reached $expect"

  # ---------- 1 HELM ----------
  note ""; note "-- 1 HELM --"
  local hrs
  hrs=$(kubectl $ctxflag get helmrelease -A -o json 2>/dev/null)
  if [ -z "$hrs" ]; then warn "could not list HelmReleases"; else
    printf '%s' "$hrs" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows=[]
for i in d.get("items",[]):
    ns=i["metadata"]["namespace"]; n=i["metadata"]["name"]
    sp=i.get("spec",{}); st=i.get("status",{})
    hist=st.get("history") or []
    hstat=hist[0].get("status") if hist else "NONE"
    hver =hist[0].get("chartVersion") if hist else "-"
    ready=next((c["status"] for c in st.get("conditions",[]) if c["type"]=="Ready"),"?")
    miss=[]
    if not sp.get("timeout"): miss.append("no-timeout")
    inst=sp.get("install",{}).get("remediation",{})
    if inst and "remediateLastFailure" not in inst: miss.append("no-remediateLastFailure")
    ver=sp.get("chart",{}).get("spec",{}).get("version","")
    if any(c in str(ver) for c in "x*^~") or ">" in str(ver) or "<" in str(ver): miss.append("floating:"+str(ver))
    rows.append((ns,n,ready,hstat,hver,",".join(miss) or "-"))
print("%-22s %-26s %-6s %-9s %-10s %s"%("NAMESPACE","RELEASE","READY","HISTORY","CHART","SPEC GAPS"))
bad=0
for r in sorted(rows):
    print("%-22s %-26s %-6s %-9s %-10s %s"%r)
    if r[3]!="deployed" or r[5]!="-": bad+=1
print("TOTAL=%d  NEEDING_WORK=%d"%(len(rows),bad))
'
    local bad
    bad=$(printf '%s' "$hrs" | python3 -c '
import json,sys
d=json.load(sys.stdin); bad=0
for i in d.get("items",[]):
    sp=i.get("spec",{}); st=i.get("status",{})
    hist=st.get("history") or []
    h=hist[0].get("status") if hist else "NONE"
    m=False
    if not sp.get("timeout"): m=True
    inst=sp.get("install",{}).get("remediation",{})
    if inst and "remediateLastFailure" not in inst: m=True
    v=str(sp.get("chart",{}).get("spec",{}).get("version",""))
    if any(c in v for c in "x*^~<>"): m=True
    if h!="deployed" or m: bad+=1
print(bad)' 2>/dev/null)
    [ "${bad:-0}" -gt 0 ] && gap "$env HELM: $bad release(s) stalled or carrying the silent defaults" \
                          || ok "$env HELM: every release deployed, no spec gaps"
  fi

  # ---------- 2 DNS ----------
  note ""; note "-- 2 DNS / routing --"
  local hosts
  hosts=$(kubectl $ctxflag get virtualservice -A -o jsonpath='{range .items[*]}{range .spec.hosts[*]}{@}{"\n"}{end}{end}' 2>/dev/null \
          | grep -E '\.usxpress\.io$' | sort -u)
  if [ -z "$hosts" ]; then warn "$env: no VirtualService hosts found -- verify the CRD is served before concluding"; else
    printf '%-46s %-16s %-6s %-7s %s\n' HOST "PUBLIC-DNS" "HTTP" "VERIFY" "BODY-SHA256"
    local h ip code vfy body
    while read -r h; do
      [ -z "$h" ] && continue
      ip=$(dig +short "$h" @8.8.8.8 2>/dev/null | tail -1)
      [ -z "$ip" ] && ip="NXDOMAIN"
      read -r code vfy < <(curl -s -o /tmp/.gapbody -w '%{http_code} %{ssl_verify_result}' --max-time 8 "https://$h/" 2>/dev/null || echo "000 999")
      body=$(sha256sum /tmp/.gapbody 2>/dev/null | cut -c1-16)
      printf '%-46s %-16s %-6s %-7s %s\n' "$h" "$ip" "$code" "$vfy" "$body"
      [ "$ip" = "NXDOMAIN" ] && gap "$env DNS: $h is routed in Istio but has NO public record"
      [ "$vfy" != "0" ] && [ "$vfy" != "999" ] && gap "$env TLS: $h verify=$vfy -- a browser shows Not secure"
    done <<< "$hosts"
    rm -f /tmp/.gapbody
    note "(identical BODY-SHA256 = two names serving the same UI; that is the consolidation list)"
  fi

  # ---------- 3 CERTS ----------
  note ""; note "-- 3 CERTS --"
  kubectl $ctxflag get certificate -A -o json 2>/dev/null | python3 -c '
import json,sys,datetime
try: d=json.load(sys.stdin)
except Exception: print("could not read Certificates"); sys.exit(0)
now=datetime.datetime.now(datetime.timezone.utc); bad=0
print("%-18s %-34s %-7s %s"%("NAMESPACE","CERTIFICATE","DAYS","ISSUER"))
for i in sorted(d.get("items",[]),key=lambda x:(x["metadata"]["namespace"],x["metadata"]["name"])):
    st=i.get("status",{}); na=st.get("notAfter")
    iss=i.get("spec",{}).get("issuerRef",{}).get("name","-")
    if iss=="istio-ca": continue
    if not na: print("%-18s %-34s %-7s %s"%(i["metadata"]["namespace"],i["metadata"]["name"],"NEVER",iss)); bad+=1; continue
    days=(datetime.datetime.fromisoformat(na.replace("Z","+00:00"))-now).days
    print("%-18s %-34s %-7d %s"%(i["metadata"]["namespace"],i["metadata"]["name"],days,iss))
    if days<21: bad+=1
print("UNDER_21_DAYS_OR_NEVER_ISSUED=%d"%bad)'

  # ---------- 4 ALERTS ----------
  note ""; note "-- 4 ALERT DELIVERY --"
  local amp amsvc
  amp=$(kubectl $ctxflag get pods -A -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | wc -l)
  if [ "$amp" -eq 0 ]; then
    gap "$env ALERTS: no Alertmanager pod -- every firing rule reaches nobody"
  else
    ok "$env: $amp Alertmanager pod(s)"
    amsvc=$(kubectl $ctxflag get secret -A -o name 2>/dev/null | grep -i alertmanager | head -1)
    if [ -n "$amsvc" ]; then
      note "config secret: $amsvc"
      kubectl $ctxflag get "$amsvc" -A -o jsonpath='{.data}' 2>/dev/null >/dev/null \
        && note "(decode and read the receivers by hand -- a config existing is not a receiver that works)"
    else
      gap "$env ALERTS: Alertmanager runs with NO config secret -- receivers unproven"
    fi
  fi
  note "firing right now:"
  kubectl $ctxflag get prometheusrule -A --no-headers 2>/dev/null | wc -l | xargs -I{} echo "  PrometheusRule objects: {}"
  if kubectl $ctxflag get prometheusrule -A -o yaml 2>/dev/null | grep -q 'IRSATokenInjectionFailure'; then
    gap "$env ALERTS: IRSATokenInjectionFailure still present -- it counts rejected=true, and failurePolicy Ignore never rejects, so it CANNOT fire"
  else
    ok "$env: the un-fireable IRSA rule is gone"
  fi
  if kubectl $ctxflag get prometheusrule -A -o yaml 2>/dev/null | grep -q 'apiserver_admission_webhook_fail_open_count'; then
    ok "$env: fail-open counter is alerted on"
  else
    gap "$env ALERTS: nothing alerts on apiserver_admission_webhook_fail_open_count -- the metric that actually moves"
  fi

  # ---------- 5 IRSA ----------
  note ""; note "-- 5 IRSA injection (SA annotated, pod has no AWS_ROLE_ARN) --"
  kubectl $ctxflag get pods -A -o json 2>/dev/null | python3 -c '
import json,sys
try: pods=json.load(sys.stdin)
except Exception: print("could not list pods"); sys.exit(0)
print(json.dumps([{"ns":p["metadata"]["namespace"],"name":p["metadata"]["name"],
  "sa":p["spec"].get("serviceAccountName","default"),
  "has":any(e.get("name")=="AWS_ROLE_ARN" for c in p["spec"].get("containers",[]) for e in (c.get("env") or []))}
  for p in pods.get("items",[]) if p.get("status",{}).get("phase")=="Running"]))' > /tmp/.gappods 2>/dev/null
  kubectl $ctxflag get sa -A -o json 2>/dev/null | python3 -c '
import json,sys
try: sas=json.load(sys.stdin)
except Exception: print("could not list serviceaccounts"); sys.exit(0)
ann={}
for s in sas.get("items",[]):
    a=(s["metadata"].get("annotations") or {}).get("eks.amazonaws.com/role-arn")
    if a: ann[(s["metadata"]["namespace"],s["metadata"]["name"])]=a
pods=json.load(open("/tmp/.gappods"))
bad=[p for p in pods if (p["ns"],p["sa"]) in ann and not p["has"]]
for p in bad: print("  UNINJECTED %s/%s  sa=%s"%(p["ns"],p["name"],p["sa"]))
print("ANNOTATED_SAS=%d  UNINJECTED_PODS=%d"%(len(ann),len(bad)))'
  rm -f /tmp/.gappods
}

sweep "op-usxpress-dev  (on-prem, 10.10.82.50)" "$HOME/.kube/op-usxpress-dev-fresh.yaml" ""                                 "10.10.82.50" "DEV"
sweep "op-usxpress-qa   (on-prem, 10.10.82.51)" "$HOME/.kube/op-usxpress-qa.yaml"        "--context admin@op-usxpress-qa"   "10.10.82.51" "QA"
sweep "op-usxpress-prod (on-prem, 10.10.82.52)" "$HOME/.kube/op-usxpress-prod.yaml"      "--context admin@op-usxpress-prod" "10.10.82.52" "PROD"

hr
printf 'TOTAL GAPS FLAGGED: %d\n' "$GAPS"
note "A skipped cluster contributes zero gaps and proves nothing. Read the ?? lines."
