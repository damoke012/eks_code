#!/usr/bin/env bash
# Why can this person not reach the cluster? Separate NETWORK from AUTHN from AUTHZ.
#
# Runs on the AFFECTED PERSON'S laptop (macOS or Linux), not on ours. Self-contained:
# no repo, no kubeconfig and no cluster credential required. READ ONLY -- it resolves
# names, opens TCP sockets and issues GETs. It changes nothing, anywhere.
#
# Written 2026-09-08. Tim reported "connects to the VPN, still cannot access the cluster"
# and the network team reported they have blocked nothing. Both can be true at once:
# "we did not block it" is a claim about POLICY, not about whether a ROUTE exists. And
# "cannot access the cluster" names three different doors with three different fixes:
#
#   1. the Kubernetes API      10.10.82.50/.51/.52:6443     -- needs a credential we issue
#   2. the RisingWave SQL/PG   rw2-sql / rw2-pg  :4567/:5432 -- needs a DB user, not kubectl
#   3. the web dashboards      *.op-dev.usxpress.io :443     -- needs Istio + DNS + Entra
#
# Granting 1 does nothing for 2 or 3. Before provisioning anybody, find out which door.
#
#   bash triage-user-cluster-access.sh              # dev (default)
#   bash triage-user-cluster-access.sh --env qa
#   bash triage-user-cluster-access.sh --env prod
set -uo pipefail

ENV=dev
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# vLAN 82: dev .50 / qa .51 / prod .52. Read it twice -- one digit apart.
case "$ENV" in
  dev)  API=10.10.82.50; CLUSTER=op-usxpress-dev  ;;
  qa)   API=10.10.82.51; CLUSTER=op-usxpress-qa   ;;
  prod) API=10.10.82.52; CLUSTER=op-usxpress-prod ;;
  *) echo "!! --env must be dev, qa or prod (got '$ENV')" >&2; exit 2 ;;
esac

echo "== target: $CLUSTER   API $API:6443   (env pinned: $ENV)"
echo "   host:   $(uname -s) $(uname -r)   user $(id -un)"

NETFAIL=0; AUTHFAIL=0
ok()   { printf '   ok       %s\n' "$*"; }
bad()  { printf '   FAIL     %s\n' "$*"; }
note() { printf '            %s\n' "$*"; }

# ---- pure-bash TCP probe: 0 open, 1 refused, 2 timed out --------------------
# The distinction matters and nc's exit code loses it. A REFUSE means packets
# reached a device that said no; a TIMEOUT means they reached nothing at all.
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

tcp() {
  local h="$1" p="$2" pid i=0
  # An unresolvable name fails INSTANTLY on /dev/tcp and is indistinguishable from a
  # refused connection unless we check first. Reporting "port refused" for a hostname
  # that does not exist sends the network team hunting a firewall rule that is not there.
  case "$h" in
    *[a-zA-Z]*) resolve "$h" >/dev/null || return 3 ;;
  esac
  ( exec 3<>"/dev/tcp/$h/$p" ) >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 2; fi
  wait "$pid"; return $?
}
verdict() {
  case "$1" in
    0) ok   "$2 OPEN" ;;
    1) bad  "$2 REFUSED -- something answered and closed it (firewall REJECT, or nothing bound)"; NETFAIL=1 ;;
    3) bad  "$2 NOT TESTED -- the hostname has no DNS record. Nothing to connect to."; NETFAIL=1 ;;
    *) bad  "$2 TIMED OUT -- packets reached nothing. No route, or a silent DROP"; NETFAIL=1 ;;
  esac
}

# ---- 1. which interface does this machine use to reach the cluster? ---------
# The single most diagnostic fact. If the answer is the dock/ethernet interface
# rather than a VPN tunnel, the VPN is not carrying vLAN 82 and no credential
# will ever help.
echo
echo "== 1. route to $API"
if command -v ip >/dev/null 2>&1; then
  R=$(ip route get "$API" 2>&1)
elif command -v route >/dev/null 2>&1; then
  R=$(route -n get "$API" 2>&1)
else
  R=""
fi
if [ -n "$R" ]; then
  printf '%s\n' "$R" | sed 's/^/            /'
  IFACE=$(printf '%s\n' "$R" | sed -n 's/.*[Ii]nterface: *\([a-z0-9]*\).*/\1/p;s/.* dev \([a-z0-9]*\).*/\1/p' | head -1)
  case "$IFACE" in
    utun*|tun*|ppp*|ipsec*|wg*) ok "egress interface $IFACE -- this is a VPN tunnel" ;;
    "") note "could not parse the egress interface from the above" ;;
    *)  bad "egress interface $IFACE -- NOT a tunnel. Traffic for $API is leaving via the"
        note "local network, so the VPN is not carrying vLAN 82 (10.10.82.0/24)."
        note "This is a ROUTING problem. Cluster credentials cannot fix it."
        NETFAIL=1 ;;
  esac
else
  note "no 'ip' or 'route' command found -- skipped"
fi

# ---- 2. corporate DNS -------------------------------------------------------
echo
echo "== 2. DNS (a resolver can be configured and still be unreachable)"
# A control query first. Without it, "this name did not resolve" gets reported as
# "DNS is down" -- a claim about the resolver made from a single missing record.
if CTRL=$(resolve argocd.op-dev.usxpress.io); then
  ok "resolver is answering for op-dev.usxpress.io (control: argocd -> ${CTRL% })"
  RESOLVER_UP=1
else
  bad "control lookup argocd.op-dev.usxpress.io failed -- the resolver itself is not answering"
  RESOLVER_UP=0; NETFAIL=1
fi
for name in rw2-sql.op-dev.usxpress.io rw2-pg.op-dev.usxpress.io rw2-dashboard.op-dev.usxpress.io; do
  if A=$(resolve "$name"); then
    ok "$name -> ${A% }"
  elif [ "$RESOLVER_UP" = "1" ]; then
    bad "$name has NO DNS RECORD -- the resolver answered, this name does not exist"
    note "Not a VPN fault and not a permissions fault. The record was never published."
    NETFAIL=1
  else
    bad "$name did not resolve (resolver is down -- cannot tell whether the record exists)"
  fi
done

# ---- 3. the three doors -----------------------------------------------------
echo
echo "== 3. door 1 -- Kubernetes API ($CLUSTER)"
tcp "$API" 6443; verdict $? "$API:6443"

echo
echo "== 4. door 2 -- RisingWave SQL and Postgres (op-dev, namespace risingwave-2)"
tcp rw2-sql.op-dev.usxpress.io 4567; verdict $? "rw2-sql.op-dev.usxpress.io:4567"
tcp rw2-pg.op-dev.usxpress.io  5432; verdict $? "rw2-pg.op-dev.usxpress.io:5432"
note "If :5432 is open but psql then hangs or resets, that is INFRA-1654, not access:"
note "ghostunnel-rw-postgres listens on :4567 behind a Service published as 5432, so"
note "nothing is bound where traffic arrives. Open since 2026-06-01. Its readinessProbe"
note "watches the status port, so the pod reports Ready with a dead data port."

echo
echo "== 5. door 3 -- web dashboards"
for h in rw2-dashboard.op-dev.usxpress.io risingwave-dashboard.op-dev.usxpress.io; do
  tcp "$h" 443; rc=$?
  if [ $rc -eq 0 ] && command -v curl >/dev/null 2>&1; then
    code=$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "https://$h/" 2>/dev/null)
    case "$code" in
      200|30[0-9]) ok "$h -> HTTP $code" ;;
      302|401|403) ok "$h -> HTTP $code (reachable; this is a login/permission answer, not a network one)" ;;
      000|"")      bad "$h TCP open but no HTTP response"; NETFAIL=1 ;;
      *)           ok "$h -> HTTP $code" ;;
    esac
  else
    verdict $rc "$h:443"
  fi
done

# ---- 4. only NOW is it meaningful to ask about the credential ---------------
echo
echo "== 6. credential"
if [ "$NETFAIL" = "1" ]; then
  echo "   SKIPPED -- something above failed at the network layer."
  echo "   A credential test against an unreachable endpoint reports a TRANSPORT failure as"
  echo "   though it were an access verdict. It is not one. Fix the route first."
elif ! command -v kubectl >/dev/null 2>&1; then
  echo "   kubectl is not installed here -- nothing to test."
  echo "   That is fine if the SQL endpoint (door 2) is all that is needed."
else
  # Pin the context to the cluster this run is ABOUT. current-context is merely whatever
  # was used last, so on an operator's own machine it will happily report on prod while
  # every other line of output is about dev -- a true answer to the adjacent question.
  CTX=""
  for c in $(kubectl config get-contexts -o name 2>/dev/null); do
    srv=$(kubectl config view --minify --context "$c" \
            -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
    case "$srv" in
      *"$API"*) CTX="$c"; ok "context '$c' -> $srv"; break ;;
    esac
  done

  if [ -z "$CTX" ]; then
    CUR=$(kubectl config current-context 2>/dev/null)
    if [ -n "$CUR" ]; then
      bad "no kubeconfig context points at $API ($CLUSTER)."
      note "current-context is '$CUR' -- a DIFFERENT cluster. Not testing it: an answer"
      note "about another cluster is not an answer about this one."
    else
      bad "kubectl has no contexts at all on this machine."
    fi
    note "No credential exists here for $CLUSTER. That is a provisioning gap."
    AUTHFAIL=1
  else
    OUT=$(kubectl --context "$CTX" get --raw /version 2>&1); RC=$?
    if [ "$RC" -eq 0 ]; then
      ok "authenticated to $CLUSTER"
      echo "   what this identity may do in namespace risingwave-2:"
      kubectl --context "$CTX" auth can-i --list -n risingwave-2 2>&1 \
        | sed 's/^/            /' | head -12
    else
      printf '%s\n' "$OUT" | sed 's/^/            /'
      case "$OUT" in
        *Unauthorized*|*"must be logged in"*)
          bad "AUTHN -- the API answered and rejected the credential. Re-issue it."; AUTHFAIL=1 ;;
        *Forbidden*|*"cannot list"*|*"cannot get"*)
          bad "AUTHZ -- identity accepted, permissions missing. Bind the group; do not re-issue."; AUTHFAIL=1 ;;
        *"i/o timeout"*|*"no route to host"*|*"connection refused"*|*"context deadline"*)
          bad "NETWORK -- transport, not access. There is nothing to provision."; NETFAIL=1 ;;
        *) bad "unclassified -- send the line above rather than guessing at it"; AUTHFAIL=1 ;;
      esac
    fi
  fi
fi

echo
if [ "$NETFAIL" = "1" ]; then
  echo "== VERDICT  NETWORK. Routing or DNS, not permissions."
  echo "   Give the network team the '== 1. route' block above: it names the interface"
  echo "   their VPN is or is not putting 10.10.82.0/24 on. 'We blocked nothing' and"
  echo "   'there is no route' are both true at the same time."
  exit 1
elif [ "$AUTHFAIL" = "1" ]; then
  echo "== VERDICT  ACCESS. The network is fine; the credential is the problem."
  echo "   docs/runbooks/onprem_cluster_access_runbook.md -- and note the agreed scope is"
  echo "   super-user in the RisingWave namespace only, NOT cluster-wide."
  exit 1
fi
echo "== VERDICT  every door checked above is reachable and answering."
exit 0
