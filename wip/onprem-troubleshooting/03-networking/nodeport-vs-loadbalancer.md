# NodePort vs LoadBalancer on Talos On-Prem (No BGP)

**Symptom:**
- Service of type `LoadBalancer` provisioned via Cilium L2/ARP announcements is reachable inside the on-prem network but NOT from corp VPN clients
- `cilium status --verbose` shows the L2 announcement happy but no route reachability from external networks
- Service of type `NodePort` on a CP returns connection refused (Talos blocks NodePort on CPs by default)
- Workloads needing external access (corp VPN reach) end up using NodePort on worker IPs as the only working option

**Root cause:**
Cilium has 3 main load balancer modes:
- **L2/ARP announcements** — works on flat networks, announces a VIP via ARP. Doesn't propagate to corp VPN (no BGP federation).
- **BGP** — would work but requires BGP infrastructure on-prem we don't have
- **kube-proxy-style NodePort** — works on workers (not on CPs by Talos default)

Without BGP, LoadBalancer Services produce VIPs only reachable inside the data center's flat network. Corp VPN clients (10.11.0.0/19) are on a separate routed network and never see the announcement.

NodePort works on workers but Talos applies a default firewall on CPs that blocks the NodePort range (`30000-32767`).

**IaC coverage:** ✓ (codified pattern — use NodePort on worker IPs)

**IaC location:**
- All externally-reachable Services in `iaac-talos-flux-platform/infrastructure/<workload>/` use `type: NodePort`
- DNS records resolve to worker IPs (one IP per worker, round-robin or specific based on workload affinity)
- ExternalDNS configured to use per-VS `target` annotation pointing at worker IPs

### Resolution via IaC

For external access: use NodePort on worker IPs, exposed via VS target annotation.

For internal access: use ClusterIP normally. Cilium handles it inside the cluster.

For HTTPS via Istio: hostNetwork-bound istio-ingressgateway DaemonSet on workers (hostPort), Gateway/VirtualService routes traffic, external-dns publishes worker IPs.

### Manual resolution (if a workload is wrongly set up as LoadBalancer)

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# Identify wrongly-typed Services
kubectl $KCONFIG -A get svc | grep LoadBalancer

# Change to NodePort
kubectl $KCONFIG -n <ns> patch svc <name> --type=merge \
  -p '{"spec":{"type":"NodePort"}}'

# Note assigned nodePort
kubectl $KCONFIG -n <ns> get svc <name>

# Test reachability from corp VPN to a worker IP
# (Run from corp-VPN-connected machine)
nc -zv -w 5 10.10.82.<worker-ip> <nodeport>
```

### Verification

```bash
# From corp VPN
WORKER_IP=10.10.82.26   # any worker
SVC_PORT=32567          # the NodePort

nc -zv -w 5 $WORKER_IP $SVC_PORT
# Expect: "Connection to <ip> <port> port [tcp/*] succeeded!"

# HTTP/HTTPS variants
curl -sv http://$WORKER_IP:$SVC_PORT/ -o /dev/null
```

### Prevention

- Code review: ANY new Service with `type: LoadBalancer` requires explicit justification
- Lint policy: if Service has `type: LoadBalancer`, fail unless there's a label `cilium.io/l2-only: true` (internal flat-network LBs only)
- For HTTPS/TCP/SNI external access: use the hostNetwork-bound istio-ingressgateway pattern (proven 2026-06-01)

### Related

- [[externaldns-target-required]] — pairs with NodePort pattern for corp-VPN-resolvable DNS
- [[istio-meshconfig-exportto]] — for HTTPS ingress routing
- Memory: `[External access: L2 LB vs NodePort]`

### Memory pointers

- `[onprem_external_access_l2_vs_nodeport]` — codified gotcha
- `[hostNetwork ingress proven viable]` — istio-ingressgateway pattern
- `[Phase 1 TCP/SNI listeners — DONE 2026-06-01]` — production pattern
