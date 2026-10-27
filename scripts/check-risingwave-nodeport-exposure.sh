#!/usr/bin/env bash
# Which RisingWave NodePorts are reachable, and do they demand a credential?
# READ ONLY: the only SQL issued is `select current_user`, the only HTTP is GET.
# Nothing is written to any cluster or database.
#
#   scripts/check-risingwave-nodeport-exposure.sh dev|qa|prod|all
#
# WHY
#   2026-10-27, Idris Fagbemi: `psql -h <node> -p 32567 -U root -d dev` connects
#   as superuser with NO PASSWORD and no TLS on dev and QA. Confirmed the same
#   day on op-usxpress-prod from a laptop on the corp VPN, on three worker
#   addresses.
#
#   A NodePort publishes the port on EVERY node's own address. It does not pass
#   through the Istio gateway, so none of the gateway's TLS or the
#   CiliumNetworkPolicy that restricts corp VLANs to the ingressgateway applies
#   to it. Those controls guard a door this traffic never uses.
#
# Three results and they are NOT the same:
#   OPEN+NOAUTH  connected and ran SQL with an empty password  -- the finding
#   OPEN+AUTH    the port answers but demanded a credential    -- acceptable
#   CLOSED       nothing listening from here                   -- says nothing
#                about other callers; this box is one vantage point
set -uo pipefail

ENVS="${1:-all}"
[ "$ENVS" = "all" ] && ENVS="dev qa prod"
NS=risingwave

say() { printf '%s\n' "$*"; }
command -v psql >/dev/null 2>&1 || { say "NOT MEASURED - psql is not on PATH"; exit 3; }

kube_for() {
  local ep="$1" f s
  for f in "$HOME"/.kube/*.yaml "$HOME"/.kube/*.yml; do
    [ -f "$f" ] || continue
    s=$(kubectl --kubeconfig="$f" config view -o jsonpath='{.clusters[*].cluster.server}' 2>/dev/null)
    [ "$(echo "$s" | wc -w)" = "1" ] || continue
    case "$s" in *"$ep:6443"*) ;; *) continue ;; esac
    kubectl --kubeconfig="$f" get --raw /version >/dev/null 2>&1 && { printf '%s' "$f"; return 0; }
  done
  return 1
}

TOTAL_OPEN=0
for E in $ENVS; do
  case "$E" in
    dev)  EP=10.10.82.50 ;;
    qa)   EP=10.10.82.51 ;;
    prod) EP=10.10.82.52 ;;
    *) say "skip unknown env '$E'"; continue ;;
  esac
  say ""
  say "=============================================================="
  say "== op-usxpress-$E"
  KC=$(kube_for "$EP" || true)
  if [ -z "$KC" ]; then
    say "   NOT MEASURED - no working kubeconfig answers $EP:6443 (VPN? session?)"
    continue
  fi
  say "   via $(basename "$KC")"

  # The published ports, from the cluster itself rather than a list in here.
  PORTS=$(kubectl --kubeconfig="$KC" -n "$NS" get svc \
    -o jsonpath='{range .items[*]}{range .spec.ports[*]}{.nodePort}{" "}{end}{end}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u)
  if [ -z "$PORTS" ]; then
    say "   no NodePort services in $NS -- nothing published"
    continue
  fi
  say "   published nodePorts: $(echo "$PORTS" | tr '\n' ' ')"

  # EVERY node, not the endpoint and not a sample. One sample is not a
  # population: on 2026-10-27 the control-plane VIP refused 32567 while three
  # workers accepted it, and the refusal nearly read as "prod is fine".
  IPS=$(kubectl --kubeconfig="$KC" get nodes \
    -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null | sort -u)
  say "   nodes: $(echo "$IPS" | wc -w)"
  say ""

  for IP in $IPS; do
    for P in $PORTS; do
      if ! timeout 4 bash -c "echo > /dev/tcp/$IP/$P" 2>/dev/null; then
        continue   # closed from here; print nothing, the matrix would be noise
      fi
      # The port answers. Does it want a credential?
      OUT=$(PGPASSWORD= timeout 8 psql -h "$IP" -p "$P" -U root -d dev \
              -At -c 'select current_user' 2>&1)
      RC=$?
      case "$OUT" in
        root*)
          say "   ${IP}:${P}  OPEN + NO AUTH  -> connected as '$OUT' with an empty password"
          TOTAL_OPEN=$((TOTAL_OPEN+1)) ;;
        *password*|*authentication*|*auth*)
          say "   ${IP}:${P}  OPEN + AUTH     -> credential demanded" ;;
        *)
          # Not postgres, or postgres refused for another reason. Try HTTP.
          CODE=$(timeout 6 curl -s -o /dev/null -w '%{http_code}' "http://${IP}:${P}/" 2>/dev/null || echo "000")
          if [ "$CODE" = "200" ]; then
            say "   ${IP}:${P}  OPEN + NO AUTH  -> HTTP 200 without a credential"
            TOTAL_OPEN=$((TOTAL_OPEN+1))
          elif [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
            say "   ${IP}:${P}  OPEN + AUTH     -> HTTP $CODE"
          else
            say "   ${IP}:${P}  OPEN            -> psql rc=$RC, http=$CODE, $(printf '%s' "$OUT" | tr -s ' \n' ' ' | head -c 70)"
          fi ;;
      esac
    done
  done
done

say ""
say "=============================================================="
if [ "$TOTAL_OPEN" -gt 0 ]; then
  say "FINDING: $TOTAL_OPEN node/port pair(s) answered WITHOUT a credential."
  say "A NodePort bypasses the Istio gateway, so neither its TLS nor the"
  say "CiliumNetworkPolicy restricting corp VLANs to the ingressgateway applies."
  exit 1
fi
say "No unauthenticated node/port pair reachable FROM THIS HOST."
say "That is one vantage point, not a statement about the whole network."
