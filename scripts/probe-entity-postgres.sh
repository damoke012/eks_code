#!/usr/bin/env bash
# Read-only. Answers ONE question: is POSTGRES_ENTITY_* the same Postgres that backs
# RisingWave's meta store, and is it the same database and the same user?
#
#   bash scripts/probe-entity-postgres.sh qa
#   bash scripts/probe-entity-postgres.sh dev
#
# Takes dev|qa|prod and resolves the kubeconfig FILE and CONTEXT by endpoint
# (10.10.82.50/.51/.52) -- never by filename, never by current-context.
#
# Never prints a secret VALUE -- key names, and equality by hash, only.
set -uo pipefail

ENV_ARG="${1:-}"
case "$ENV_ARG" in
  dev|qa|prod) ;;
  *)
    echo "usage: bash scripts/probe-entity-postgres.sh dev|qa|prod"
    echo "       (resolves the kubeconfig + context BY ENDPOINT -- context names on this"
    echo "        machine are not the cluster names, and merged files hold several clusters)"
    exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVED="$(python3 "$HERE/kube-resolve-onprem.py" "$ENV_ARG")" || {
  echo
  echo "No kubeconfig on this machine serves on-prem $ENV_ARG."
  case "$ENV_ARG" in
    dev)  echo "  rebuild: it is cert-based; see wsl-kubeconfig-churn (op-usxpress-dev-fresh.yaml)" ;;
    qa)   echo "  rebuild: aws s3 cp s3://lazy-tf-state-425rbol87rmn6c7m/iaac/talos/op-usxpress-qa.tfstate - \\"
          echo "             --profile usx-qa | jq -r '.outputs.kubeconfig.value' > ~/.kube/op-usxpress-qa.yaml" ;;
    prod) echo "  rebuild: bash scripts/onprem-prod-kubeconfig.sh ops-controller" ;;
  esac
  exit 4
}
KCFG="$(printf '%s' "$RESOLVED" | cut -f1)"
CTX="$(printf '%s' "$RESOLVED" | cut -f2)"
SRV="$(printf '%s' "$RESOLVED" | cut -f3)"
export KUBECONFIG="$KCFG"
K() { kubectl --context "$CTX" "$@"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

cat > "$T/cm.py" <<'PY'
import json,sys
docs=json.load(sys.stdin).get("items",[])
hits=0
for d in docs:
    data=d.get("data") or {}
    flat={}
    for k,v in data.items():
        if "POSTGRES" in k or k.startswith("PG_"):
            flat[k]=v
        elif isinstance(v,str) and "POSTGRES_" in v:
            for line in v.splitlines():
                if ":" in line and "POSTGRES" in line.upper():
                    kk,_,vv=line.partition(":")
                    flat[kk.strip()+"  ("+k+")"]=vv.strip()
    if not flat: continue
    hits+=1
    m=d["metadata"]
    print("  %s/%s" % (m["namespace"], m["name"]))
    for k in sorted(flat):
        print("      %-42s = %s" % (k, flat[k]))
print("  (%d ConfigMap(s) matched)" % hits if hits else
      "  NONE FOUND -- verify the selector before calling it absent:\n"
      "    kubectl --context CTX get cm -A | grep -iE 'endpoint|pipeline|risingwave'")
PY

cat > "$T/meta.py" <<'PY'
import json,sys,re
items=json.load(sys.stdin).get("items",[])
found=0
for it in items:
    m=it["metadata"]; name=m["name"]
    if "meta" not in name.lower() or not re.search("risingwave|rw", name.lower()): continue
    found+=1
    print("  pod %s/%s" % (m["namespace"], name))
    for c in it["spec"].get("containers",[]):
        argv=list(c.get("command",[]))+list(c.get("args",[]))
        for i,tok in enumerate(argv):
            if re.match(r"^--(pg-|backend|meta-store|sql-endpoint)", tok):
                val = argv[i+1] if i+1 < len(argv) and not argv[i+1].startswith("--") else ""
                print("      arg  %-24s %s" % (tok, val))
        for e in c.get("env",[]):
            k=e.get("name","")
            if not re.match(r"^(RW_|PG_|POSTGRES_|META_)", k): continue
            if any(x in k for x in ("PASSWORD","SECRET","TOKEN")):
                vf=(e.get("valueFrom") or {}).get("secretKeyRef") or {}
                src="secret %s/%s" % (vf.get("name","?"), vf.get("key","?")) if vf else "<literal, REDACTED>"
                print("      env  %-30s <- %s" % (k, src))
            elif e.get("value") is not None:
                print("      env  %-30s = %s" % (k, e["value"]))
            else:
                vf=(e.get("valueFrom") or {}).get("secretKeyRef") or {}
                print("      env  %-30s <- secret %s/%s" % (k, vf.get("name","?"), vf.get("key","?")))
if not found:
    print("  no pod matched 'risingwave.*meta'. Do NOT read that as 'no meta store' --")
    print("  check the selector:  kubectl --context CTX get pods -A | grep -i risingwave")
PY

cat > "$T/svc.py" <<'PY'
import json,sys
rows=[]
for s in json.load(sys.stdin).get("items",[]):
    for p in s["spec"].get("ports",[]):
        if p.get("port")==5432:
            m=s["metadata"]
            rows.append("  %s/%s  type=%s  dns=%s.%s.svc.cluster.local:5432"
                        % (m["namespace"], m["name"], s["spec"].get("type"), m["name"], m["namespace"]))
print("\n".join(rows) if rows else "  no service exposes 5432 in this cluster")
PY

cat > "$T/es.py" <<'PY'
import json,sys
try: items=json.load(sys.stdin).get("items",[])
except Exception: items=[]
found=False
for es in items:
    sp=es.get("spec",{}); m=es["metadata"]
    refs=[(d.get("secretKey"), (d.get("remoteRef") or {}).get("key"),
           (d.get("remoteRef") or {}).get("property")) for d in sp.get("data",[])]
    if not any("POSTGRES" in (r[0] or "") or (r[0] or "").startswith("PG_") for r in refs): continue
    found=True
    print("  %s/%s   -> Secret '%s'" % (m["namespace"], m["name"],
          (sp.get("target") or {}).get("name","?")))
    for sk,key,prop in refs:
        print("      %-28s <- %s%s" % (sk, key, " ["+prop+"]" if prop else ""))
    for c in (es.get("status",{}).get("conditions") or []):
        print("      status: %s=%s  %s  %s" % (c.get("type"), c.get("status"),
              c.get("reason",""), (c.get("message") or "")[:80]))
if not found:
    print("  no ExternalSecret requests POSTGRES_*/PG_* keys. Verify the CRD exists before")
    print("  concluding absence:  kubectl --context CTX get crd | grep external-secrets")
PY

cat > "$T/job.py" <<'PY'
import json,sys
items=json.load(sys.stdin).get("items",[])
if not items:
    print("  no Job/CronJob found in this namespace")
for it in items:
    m=it["metadata"]
    st=it.get("status",{})
    tmpl=(it.get("spec",{}).get("template") or
          (it.get("spec",{}).get("jobTemplate",{}).get("spec",{}).get("template")) or {})
    conts=(tmpl.get("spec",{}) or {}).get("containers",[])
    print("  %s/%s   active=%s succeeded=%s failed=%s" %
          (m["namespace"], m["name"], st.get("active",0), st.get("succeeded",0), st.get("failed",0)))
    for c in conts:
        for e in c.get("env",[]):
            skr=(e.get("valueFrom") or {}).get("secretKeyRef")
            if not skr: continue
            print("      env %-30s <- secret %s/%s   optional=%s" %
                  (e.get("name"), skr.get("name"), skr.get("key"), skr.get("optional", False)))
        for ef in c.get("envFrom",[]):
            sr=ef.get("secretRef") or {}
            cr=ef.get("configMapRef") or {}
            if sr: print("      envFrom secret    %s   optional=%s" % (sr.get("name"), sr.get("optional", False)))
            if cr: print("      envFrom configMap %s   optional=%s" % (cr.get("name"), cr.get("optional", False)))
PY

cat > "$T/secnames.py" <<'PY'
import json,sys
for s in json.load(sys.stdin).get("items",[]):
    d=s.get("data") or {}
    if any(k.startswith(("POSTGRES_","PG_","RW_")) for k in d):
        m=s["metadata"]; print(m["namespace"], m["name"])
PY

cat > "$T/seccmp.py" <<'PY'
import json,sys,hashlib
d=(json.load(sys.stdin).get("data") or {})
for k in sorted(d): print("      key  %s" % k)
h=lambda k: hashlib.sha256(d[k].encode()).hexdigest()[:12] if d.get(k) else None
for a,b in (("PG_USER","POSTGRES_ENTITY_USER"),("PG_PASSWORD","POSTGRES_ENTITY_PASSWORD")):
    ha,hb=h(a),h(b)
    if ha and hb:
        print("      COMPARE %s vs %s: %s" % (a,b,"SAME VALUE" if ha==hb else "DIFFERENT VALUES"))
    elif ha and not hb:
        print("      COMPARE %s vs %s: %s IS ABSENT -- this is the wedge" % (a,b,b))
PY

echo "=============================================================="
echo " entity-postgres probe   context: $CTX   $(date -u '+%Y-%m-%dT%H:%MZ')"
echo "=============================================================="

echo "kubeconfig : $KCFG"
echo "context    : $CTX"
echo "endpoint   : $SRV"
echo

HOSTPORT="${SRV#*://}"; H="${HOSTPORT%%:*}"; P="${HOSTPORT##*:}"; [ "$P" = "$H" ] && P=6443
if ! timeout 5 bash -c "exec 3<>/dev/tcp/$H/$P" 2>/dev/null; then
  echo "ABORT: $H:$P is not reachable -- corp VPN is down or the cluster is."
  echo "       Transport failure, not a finding. Nothing below would mean anything."
  exit 3
fi
echo "tcp $H:$P  : open"

if ! K version -o json >/dev/null 2>&1; then
  echo "ABORT: port is open but the API refused us -- this is CREDENTIALS, not the network."
  echo "       op-dev is cert-based; op-qa authenticates through aws-iam-authenticator and"
  echo "       needs BOTH sso logins:  aws sso login --profile op-qa   (cluster)"
  echo "                               aws sso login --profile usx-qa  (AWS API)"
  K version -o json 2>&1 | tail -5
  exit 3
fi
echo "api reachable: yes"; echo

echo "--- [1] ConfigMaps carrying POSTGRES_SERVER / POSTGRES_ENTITY_DB -------"
K get configmap -A -o json 2>/dev/null | python3 "$T/cm.py"; echo

echo "--- [2] RisingWave meta store backend (from the running pod) ----------"
K get pods -A -o json 2>/dev/null | python3 "$T/meta.py"; echo

echo "--- [3] in-cluster Postgres services (port 5432) ----------------------"
K get svc -A -o json 2>/dev/null | python3 "$T/svc.py"; echo

echo "--- [4] ExternalSecret -> Secrets Manager mapping ---------------------"
K get externalsecret -A -o json 2>/dev/null | python3 "$T/es.py"; echo

echo "--- [5] pipeline Secret: keys present (NO values printed) -------------"
SEC="$(K get secret -A -o json 2>/dev/null | python3 "$T/secnames.py")"
if [ -z "$SEC" ]; then
  echo "  no Secret carries POSTGRES_*/PG_*/RW_* keys on this cluster"
else
  printf '%s\n' "$SEC" | while read -r ns name; do
    [ -z "${ns:-}" ] && continue
    echo "  $ns/$name"
    K get secret "$name" -n "$ns" -o json 2>/dev/null | python3 "$T/seccmp.py"
  done
fi
echo

echo "--- [6] the apply Job: which Secret keys it demands, and are they optional? --"
K get job,cronjob -A -o json 2>/dev/null | python3 "$T/job.py"
echo
cat <<'EOF'
--- READ THIS ---------------------------------------------------------
  Verdict is [1] POSTGRES_SERVER against [2] the meta store's --pg-host:

    different host                  -> entity-postgres is a separate system
    same host, different database   -> one instance, two databases (both accounts true)
    same host, SAME database        -> the #20 routing guard REFUSES .sql (exit 1)

  [5] answers whether a new Secrets Manager record is needed at all:
  if PG_USER and POSTGRES_ENTITY_USER hold the same value, the ExternalSecret can
  point both at the existing postgres/{username,password} records -- no Terraform.

  Every call is a get. Nothing here mutates anything.
EOF
