# Istio-CNI + Ztunnel Stale (Sandbox Setup Fails)

**Symptom:**
- Newly-scheduled pods on a worker stay `ContainerCreating` indefinitely
- `kubectl describe pod` shows repeated:
  ```
  Failed to create pod sandbox: rpc error: ... plugin type="istio-cni" name="istio-cni" failed (add):
  istio-cni cmdAdd failed to contact node Istio CNI agent: unable to push CNI event (status code 500): no ztunnel connection
  ```
- Or earlier signature:
  ```
  failed to setup client: stat /var/run/istio-cni/istio-cni-kubeconfig: no such file or directory
  ```
- Affected nodes are specifically the ones where kubelet recently bounced (Talos config push, hostname patch, etc.)
- DaemonSet pods on affected node have aged AGEs but recent RESTARTS

**Root cause:**
Two DaemonSets are involved in Istio ambient pod sandbox setup:
- `istio-cni-node` (DaemonSet in `istio-system`) — registers the CNI plugin on the host
- `ztunnel` (DaemonSet in `istio-system`) — provides the L4 secure overlay for ambient mode

These DSes mount the host's kubelet socket and CNI directory. They establish socket-level connection at startup. When kubelet bounces (machine config push, hostname change, EPHEMERAL reset), the socket changes underneath but the DS pods retain stale references. New CNI events fail because the agent can't talk to the kubelet-side socket.

**IaC coverage:** ❌ (not yet codified; planned as `istio-ambient-recovery` CronJob OR CASE 5 in cilium-node-reconciler — Track 4 NEW)

**IaC location:** N/A yet — drafted in `wip/iac-sweep-jun18/INCIDENT-COVERAGE-MATRIX-2026-06-19.md` § F4

### Resolution via IaC (planned)

Once shipped: a CronJob runs every 15 min, detects kubelet socket / CNI socket mismatch on each node, and bounces affected DS pods automatically. Like the cilium-node-reconciler pattern.

### Manual resolution

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# Identify affected nodes — those where pods are stuck ContainerCreating
kubectl $KCONFIG get pods -A --field-selector=status.phase=Pending,status.phase=Unknown -o wide | \
  awk '/no ztunnel|istio-cni/ { print $8 }' | sort -u

# OR if you know which node had kubelet bounce (e.g., post-Talos-apply)
NODES="talos-wk-op-dev-2 talos-wk-op-dev-3 talos-wk-op-dev-5 talos-wk-op-dev-7"

for node in $NODES; do
  echo "=== bouncing istio-cni + ztunnel on $node ==="
  kubectl $KCONFIG -n istio-system delete pod \
    -l app=ztunnel \
    --field-selector spec.nodeName=$node
  kubectl $KCONFIG -n istio-system delete pod \
    -l k8s-app=istio-cni-node \
    --field-selector spec.nodeName=$node
done

# Wait for DS pods to respawn
sleep 30

# Verify istio-cni shows 1/1 Ready on each affected node
kubectl $KCONFIG -n istio-system get pods -l k8s-app=istio-cni-node -o wide
```

**Note on ztunnel 0/1 Ready (don't be misled):**

ztunnel pods show `0/1 Ready` cluster-wide as steady-state — the readiness probe is not strictly tied to functional state. ztunnel `0/1` is OK as long as:
- Connection to istiod for xDS is up (logs show no `XDS client connection error`)
- No `no ztunnel connection` errors for new pod sandboxes

**Note on order of operations:**

If DNS is ALSO broken (e.g., during a CN drift cascade), bounce ztunnel/istio-cni AFTER DNS is restored. ztunnel needs DNS to reach istiod. Bouncing while DNS is broken makes a fresh pod start that immediately fails to reach istiod.

Order: fix CiliumNode drift → DNS recovers → bounce istio-cni/ztunnel.

### Verification

```bash
# 1. istio-cni 1/1 Ready on every node
kubectl $KCONFIG -n istio-system get pods -l k8s-app=istio-cni-node -o wide

# 2. New test pod gets sandbox successfully
kubectl $KCONFIG run sandbox-test --image=nginx --restart=Never
sleep 30
kubectl $KCONFIG describe pod sandbox-test | grep -i sandbox
# Expect: no "Failed to create pod sandbox" recent events
kubectl $KCONFIG delete pod sandbox-test

# 3. ztunnel logs show no xDS errors
kubectl $KCONFIG -n istio-system logs <ztunnel-pod-name> --tail=30 | grep -i error
```

### Prevention

- Plan the `istio-ambient-recovery` CronJob (Track 4 NEW) — auto-bounce DS pods after kubelet socket events
- Any `talosctl patch machineconfig` or `talosctl apply-config` should be followed by a `bounce-istio-ambient.sh` script (one-liner per node)
- Add to runbook step: "after any Talos machine config push to a worker, bounce istio-cni + ztunnel on that node"

### Related

- [[cluster-dns-failure]] — bounce ztunnel AFTER DNS restored, not before
- [[../01-cluster-control-plane/kubelet-cn-mismatch]] — Case B-2 fix triggers this staleness
- [[../06-incidents-timeline/2026-06-19-dns-irsa-rw-cascade]] — pattern documented from tonight's recovery

### Memory pointers

- `[Session state Jun 19]` — tonight's bounce on wk-2/wk-3/wk-5/wk-7 needed two rounds (first before DNS, second after)
- `/onprem-safety` skill — pre-deploy gate doesn't yet cover this; add to next-session runbook revision
