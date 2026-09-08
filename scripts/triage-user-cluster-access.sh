#!/usr/bin/env bash
# Why can this person not reach the cluster? Separate NETWORK from AUTHN from AUTHZ.
#
# Runs on the AFFECTED PERSON'S machine (macOS, Linux or WSL2), not on ours. Self-contained:
# no repo, no kubeconfig, no cluster credential required. READ ONLY -- it resolves names,
# opens TCP sockets and issues GETs. It changes nothing, anywhere.
#
# "Cannot access the cluster" names three doors with three different fixes:
#
#   1. the Kubernetes API      10.10.82.50/.51/.52:6443      -- needs a credential we issue
#   2. the RisingWave SQL/PG   rw2-sql / rw2-pg :4567/:5432  -- needs a DB user, not kubectl
#   3. the web dashboards      *.op-dev.usxpress.io :443     -- needs Istio + DNS + Entra
#
# Granting 1 does nothing for 2 or 3. Establish the door before provisioning anybody.
#
# ORDER MATTERS HERE. Reachability is measured DIRECTLY, and the egress interface is only
# interpreted afterwards, to explain a failure that already happened. The first version of
# this script had that backwards: it read the interface name, inferred "no route", and
# reported FAIL -- on a WSL2 box that went on to open every port successfully. In WSL2 all
# traffic leaves via eth0 into the Hyper-V switch and the Windows host applies the VPN, so
# the tunnel is invisible from inside. Same for a container or any NAT'd VM. An inference
# must never outrank the direct measurement standing next to it.
#
#   bash triage-user-cluster-access.sh              # dev (default)
#   bash triage-user-cluster-access.sh --env qa
#   bash triage-user-cluster-access.sh --env prod
set -uo pipefail

ENV=dev
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# vLAN 82: dev .50 / qa .51 / prod .52. Read it twice -- one digit apart.
case "$ENV" in
  dev)  API=10.10.82.50; CLUSTER=op-usxpress-dev  ;;
  qa)   API=10.10.82.51; CLUSTER=op-usxpress-qa   ;;
  prod) API=10.10.82.52; CLUSTER=op-usxpress-prod ;;
  *) echo "!! --env must be dev, qa or prod (got '${ENV:-}')" >&2; exit 2 ;;
esac

# Per-door outcomes. Nothing else may set these -- in particular, no inference may.
D1=ok; D2=ok; D3=ok; CRED=untested; DNSGAP=""
ok()   { printf '   ok       %s\n' "$*"; }
bad()  { printf '   FAIL     %s\n' "$*"; }
info() { printf '   info     %s\n' "$*"; }
note() { printf '            %s\n' "$*"; }

echo "== target: $CLUSTER   API $API:6443   (env pinned: $ENV)"
echo "   host:   $(uname -s) $(uname -r)   user $(id -un)"

# Is the egress interface even meaningful on this host?
INDIRECT=""
case "$(uname -r)" in *[Mm]icrosoft*|*WSL*) INDIRECT="WSL2" ;; esac
[ -z "$INDIRECT" ] && [ -f /.dockerenv ] && INDIRECT="container"

resolve() {  # prints the A records, non-zero if there are none
  local n="$1" a=""
  if command -v dig >/dev/null 2>&1; then
    a=$(dig +short +time=3 +tries=1 "$n" 2>/dev/null | grep -E '^[0-9]+\.' | tr '\n' ' ')
  fi
  [ -n "$a" ] || a=$(getent hosts "$n" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  [ -n "$a" ] || a=$(python3 -c 'import socket,sys
try: print(" ".join(sorted({i[4][0] for i in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)})))
except Exception: pass' "$n" 2>/dev/null)
  [ -n "$a" ] || return 1
  printf '%s' "$a"
}

# pure-bash TCP probe: 0 open, 1 refused, 2 timed out, 3 name does not resolve
tcp() {
  local h="$1" p="$2" pid i=0
  case "$h" in *[a-zA-Z]*) resolve "$h" >/dev/null || return 3 ;; esac
  ( exec 3<>"/dev/tcp/$h/$p" ) >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 2; fi
  wait "$pid"; return $?
}
say_tcp() {  # $1 rc, $2 label -> echoes verdict, returns rc
  case "$1" in
    0) ok  "$2 OPEN" ;;
    1) bad "$2 REFUSED -- something answered and closed it (a REJECT rule, or nothing bound)" ;;
    3) bad "$2 NOT TESTED -- the hostname has no DNS record. There is nothing to connect to." ;;
    *) bad "$2 TIMED OUT -- packets reached nothing. No route, or a silent DROP" ;;
  esac
  return "$1"
}

# ---- 1. egress, recorded now, INTERPRETED LATER -----------------------------
echo
echo "== 1. egress toward $API  (information -- see the verdict for what it means)"
ROUTE=""
if command -v ip >/dev/null 2>&1; then ROUTE=$(ip route get "$API" 2>&1)
elif command -v route >/dev/null 2>&1; then ROUTE=$(route -n get "$API" 2>&1); fi
IFACE=""
if [ -n "$ROUTE" ]; then
  printf '%s\n' "$ROUTE" | sed 's/^/            /'
  IFACE=$(printf '%s\n' "$ROUTE" | sed -n 's/.*[Ii]nterface: *\([a-zA-Z0-9._-]*\).*/\1/p;s/.* dev \([a-zA-Z0-9._-]*\).*/\1/p' | head -1)
fi
if [ -n "$INDIRECT" ]; then
  info "this is $INDIRECT -- the VPN is applied by the host, outside this namespace."
  note "The interface here is always the virtual one and says NOTHING about the tunnel."
elif [ -n "$IFACE" ]; then
  case "$IFACE" in
    utun*|tun*|ppp*|ipsec*|wg*) info "egress interface $IFACE (a tunnel)" ;;
    *) info "egress interface $IFACE (not a tunnel name)" ;;
  esac
fi

# ---- 2. DNS -----------------------------------------------------------------
echo
echo "== 2. DNS (a resolver can be configured and still be unreachable)"
# Control query first: without it, one missing record gets reported as "DNS is down".
if CTRL=$(resolve argocd.op-dev.usxpress.io); then
  ok "resolver answering for op-dev.usxpress.io (control: argocd -> ${CTRL% })"
  RESOLVER_UP=1
else
  bad "control lookup argocd.op-dev.usxpress.io failed -- the resolver is not answering"
  RESOLVER_UP=0
fi
for name in rw2-sql.op-dev.usxpress.io rw2-pg.op-dev.usxpress.io rw2-dashboard.op-dev.usxpress.io; do
  if A=$(resolve "$name"); then
    ok "$name -> ${A% }"
  elif [ "$RESOLVER_UP" = "1" ]; then
    bad "$name has NO DNS RECORD -- the resolver answered, this name does not exist"
    case "$name" in
      rw2-pg.*) note "EXPECTED. rw2-pg-passthrough.yaml is a draft, deliberately not applied:"
                note "exposing RW-2 postgres is a Phase 2 decision (INFRA-1495), not an outage."
                note "If Tim needs it, that is a decision to take, not a fault to chase." ;;
      *)        DNSGAP="$DNSGAP $name" ;;
    esac
  else
    bad "$name did not resolve (resolver down -- cannot tell whether the record exists)"
  fi
done

# ---- 3/4/5. the three doors, measured directly ------------------------------
echo
echo "== 3. door 1 -- Kubernetes API ($CLUSTER)"
tcp "$API" 6443; say_tcp $? "$API:6443" || D1=fail

echo
echo "== 4. door 2 -- RisingWave SQL and Postgres (op-dev, namespace risingwave-2)"
tcp rw2-sql.op-dev.usxpress.io 4567; say_tcp $? "rw2-sql.op-dev.usxpress.io:4567" || D2=fail
tcp rw2-pg.op-dev.usxpress.io  5432; say_tcp $? "rw2-pg.op-dev.usxpress.io:5432" || true
note "rw2-pg is expected to be absent -- its VirtualService was never applied."
note "In the risingwave namespace, if :5432 opens but psql hangs or resets, that is"
note "INFRA-1654 rather than access:"
note "ghostunnel-rw-postgres listens on :4567 behind a Service published as 5432, so"
note "nothing is bound where traffic arrives. Its readinessProbe watches the status"
note "port, so the pod reports Ready with a dead data port."

echo
echo "== 5. door 3 -- web dashboards"
for h in rw2-dashboard.op-dev.usxpress.io risingwave-dashboard.op-dev.usxpress.io; do
  tcp "$h" 443; rc=$?
  if [ "$rc" -eq 0 ] && command -v curl >/dev/null 2>&1; then
    code=$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "https://$h/" 2>/dev/null)
    case "$code" in
      000|"") bad "$h TCP open but no HTTP response"; D3=fail ;;
      401|403) ok "$h -> HTTP $code (reachable; a login answer, not a network one)" ;;
      *) ok "$h -> HTTP $code" ;;
    esac
  else
    say_tcp "$rc" "$h:443" || D3=fail
  fi
done

# ---- 6. credential ----------------------------------------------------------
# Gated ONLY on door 1. A missing DNS record for an unrelated endpoint must not
# suppress this section -- that is how the useful answer gets withheld.
echo
echo "== 6. credential"
if [ "$D1" = "fail" ]; then
  echo "   SKIPPED -- the API endpoint itself is unreachable (door 1 above)."
  echo "   Testing a credential against an unreachable endpoint reports a TRANSPORT"
  echo "   failure as though it were an access verdict. It is not one."
elif ! command -v kubectl >/dev/null 2>&1; then
  echo "   kubectl is not installed here -- nothing to test."
  echo "   That is fine if the SQL endpoint (door 2) is all that is needed."
else
  # Look in every kubeconfig, not just the default one. Asking `kubectl config` with no
  # KUBECONFIG set reads ~/.kube/config alone, and this team deliberately keeps each
  # cluster in its OWN file (op-usxpress-prod-breakglass.yaml, op-usxpress-qa-sso.yaml)
  # precisely so a stray command cannot inherit the wrong cluster. Reading the default
  # path and concluding "no credential exists" is a claim about a FILE, not about access.
  CANDS=""
  [ -n "${KUBECONFIG:-}" ] && CANDS=$(printf '%s' "$KUBECONFIG" | tr ':' '\n')
  for f in "$HOME/.kube/config" "$HOME"/.kube/*.yaml "$HOME"/.kube/*.yml "$HOME"/.kube/*.conf; do
    [ -f "$f" ] && CANDS="$CANDS
$f"
  done
  CANDS=$(printf '%s\n' "$CANDS" | grep -v '^$' | awk '!seen[$0]++')

  CTX=""; KCF=""; SEEN=0; OTHERS=""
  for f in $CANDS; do
    [ -f "$f" ] || continue
    SEEN=$((SEEN+1))
    for c in $(kubectl --kubeconfig "$f" config get-contexts -o name 2>/dev/null); do
      srv=$(kubectl --kubeconfig "$f" config view --minify --context "$c" \
              -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
      case "$srv" in
        *"$API"*) CTX="$c"; KCF="$f"; break ;;
        *)        OTHERS="$OTHERS
            $(basename "$f")  $c  ->  ${srv:-<no server>}" ;;
      esac
    done
    [ -n "$CTX" ] && break
  done

  if [ -n "$CTX" ]; then
    ok "context '$CTX' in $KCF -> $API"
    OUT=$(kubectl --kubeconfig "$KCF" --context "$CTX" get --raw /version 2>&1); RC=$?
    if [ "$RC" -eq 0 ]; then
      ok "authenticated to $CLUSTER"
      CRED=ok
      echo "   what this identity may do in namespace risingwave-2:"
      kubectl --kubeconfig "$KCF" --context "$CTX" auth can-i --list -n risingwave-2 2>&1 \
        | sed 's/^/            /' | head -12
    else
      printf '%s\n' "$OUT" | sed 's/^/            /'
      case "$OUT" in
        *Unauthorized*|*"must be logged in"*)
          bad "AUTHN -- the API answered and rejected the credential. Re-issue it."; CRED=authn ;;
        *Forbidden*|*"cannot list"*|*"cannot get"*)
          bad "AUTHZ -- identity accepted, permissions missing. Bind the group."; CRED=authz ;;
        *"certificate has expired"*|*"x509"*)
          bad "AUTHN -- the client certificate is expired or untrusted. Re-issue it."; CRED=authn ;;
        *"i/o timeout"*|*"no route to host"*|*"connection refused"*|*"context deadline"*)
          bad "transport failure on a port that opened seconds ago -- rerun before acting"; CRED=flaky ;;
        *) bad "unclassified -- send the line above rather than guessing at it"; CRED=unknown ;;
      esac
    fi
  elif [ "$SEEN" -eq 0 ]; then
    bad "no kubeconfig file found (checked \$KUBECONFIG and $HOME/.kube/)"
    note "No credential for $CLUSTER on this machine -- a provisioning gap."
    CRED=missing
  else
    bad "$SEEN kubeconfig file(s) found, none with a context pointing at $API"
    [ -n "$OTHERS" ] && { note "what they do point at:"; printf '%s\n' "$OTHERS"; }
    note "So there is no credential for $CLUSTER here. Other clusters are not a substitute."
    CRED=missing
  fi
fi

# ---- verdict ----------------------------------------------------------------
echo
echo "== VERDICT"
RC=0
if [ "$D1" = "fail" ]; then
  echo "   NETWORK -- $API:6443 is not reachable from this machine."
  if [ -n "$INDIRECT" ]; then
    note "Egress interface is unreadable from inside $INDIRECT; the VPN is on the host."
    note "Check the tunnel on the host, not here."
  elif [ -n "$IFACE" ]; then
    note "Traffic for $API leaves via '$IFACE'. Give the network team the '== 1.' block:"
    note "it names the interface their VPN is or is not putting 10.10.82.0/24 on."
    note "'We blocked nothing' and 'there is no route' are both true at the same time."
  fi
  RC=1
else
  ok "door 1 (Kubernetes API) reachable"
fi
[ "$D2" = "fail" ] && { echo "   door 2 (RisingWave SQL/Postgres) has a failure above."; RC=1; } || ok "door 2 reachable"
[ "$D3" = "fail" ] && { echo "   door 3 (dashboards) has a failure above."; RC=1; }              || ok "door 3 reachable"
if [ -n "$DNSGAP" ]; then
  echo "   MISSING DNS:$DNSGAP"
  note "Not a VPN fault and not a permissions fault -- the record was never published."
  RC=1
fi
case "$CRED" in
  ok)      ok "credential valid for $CLUSTER" ;;
  missing) echo "   ACCESS -- the network is fine; no credential exists here. See"
           echo "   docs/runbooks/onprem_cluster_access_runbook.md. Agreed scope is super-user"
           echo "   in the RisingWave namespace ONLY, not cluster-wide."; RC=1 ;;
  authn|authz) echo "   ACCESS -- classified $CRED above."; RC=1 ;;
esac
exit "$RC"
