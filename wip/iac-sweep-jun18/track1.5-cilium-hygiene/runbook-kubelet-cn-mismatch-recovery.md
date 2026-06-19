# Runbook: kubelet CN-mismatch recovery

**Target location:** `iaac-talos/deploy/docs/runbooks/kubelet-cn-mismatch-recovery.md`
**Triggered by:** `KubeletNotRegistering` / `KubeletCSRForbidden` PromRule
**Severity:** Warning (cluster operates degraded; etcd still has quorum)
**Owner:** Cloud Platform On-Prem

## Signature

A node's kubelet shows `Running OK` via `talosctl service kubelet status` BUT:
- No matching `Node` object in `kubectl get nodes`
- Kubelet logs (`talosctl logs kubelet`) contain:
  ```
  csr-: can only create a node CSR with CN=system:node:<OLD-HOSTNAME>
  nodes "<NEW-HOSTNAME>" is forbidden: ... cannot read '<NEW-HOSTNAME>', only its own Node object
  ```
- Machine config (`talosctl get machineconfig -o yaml`) shows the NEW hostname

## Root cause

Kubelet's TLS client cert has CN bound to a previous hostname. The Kubernetes Node Authorizer enforces `CN must match target node name` for both CSR creation and Node API access. A kubelet can rotate its cert via CSR — but only for the IDENTITY in its current cert. So if the cert says `cp-2` and the kubelet now wants to identify as `cp-3`, every CSR is rejected and the cert never rotates.

This is a chicken-and-egg lockup. It surfaces on Talos clusters when:
- Machine config is patched to change `machine.network.hostname` (out-of-band `talosctl patch` OR Terraform apply changing the value)
- Kubelet restarts with the new hostname-override
- But the existing kubelet client cert in `/system/secrets/kubelet/` retains the OLD CN

## Why we don't auto-fix

The recovery procedure wipes the EPHEMERAL partition on the affected node, which contains:
- Kubelet client cert + key
- etcd data (if a CP)
- Ephemeral pod state

Wiping that on a CP temporarily drops etcd quorum by 1. Wiping it on a worker drops any local-path PVs hosted there. Both are recoverable but invasive. **Auto-execution is too risky** — a human verifies pre-conditions and triggers the procedure.

## Pre-flight

```bash
export TALOSCONFIG=/tmp/talosconfig-op-usxpress-dev
KCONFIG="--server=https://<healthy-cp-ip>:6443 --insecure-skip-tls-verify=true"
STUCK_IP=<the-IP-shown-in-the-alert>

# 1. Confirm the kubelet is actually stuck — NOT a transient API server flap
talosctl --nodes "$STUCK_IP" --endpoints "$STUCK_IP" service kubelet status

# 2. Confirm kubelet logs show the CN-mismatch error
talosctl --nodes "$STUCK_IP" --endpoints "$STUCK_IP" logs kubelet 2>&1 | grep -i "csr-\|forbidden" | tail -10

# 3. Confirm 2+ OTHER CPs healthy (etcd needs quorum during the reset)
for cp in <other-cp-1-ip> <other-cp-2-ip>; do
  echo "--- $cp ---"
  talosctl --nodes "$cp" --endpoints "$cp" etcd members 2>&1 | head -5
done

# 4. Confirm RW healthy baseline
kubectl $KCONFIG -n risingwave get pods,svc,pvc > /tmp/rw-pre-cn-fix.txt
wc -l /tmp/rw-pre-cn-fix.txt

# 5. If stuck node is a CP — find its etcd member ID
talosctl --nodes <any-healthy-cp> --endpoints <any-healthy-cp> etcd members
# Note the ID column for the row with PEER URL pointing at $STUCK_IP
```

**GO criteria:**
- Kubelet truly stuck (CN-mismatch in logs)
- 2+ OTHER CPs healthy with quorum
- RW baseline captured
- Etcd member ID identified (CP case only)

## Procedure

### Case A — stuck node is a control plane

```bash
# 1. Remove the stuck node's etcd member (so etcd doesn't get confused on rejoin)
STUCK_ETCD_ID=<member-id-from-pre-flight>
talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd remove-member "$STUCK_ETCD_ID"

# 2. Verify member removed — should show 2 members
talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd members

# 3. Reset the stuck node — wipes EPHEMERAL (kubelet PKI + etcd data + pod state),
#    keeps STATE (machine config + secrets), reboots
talosctl --nodes "$STUCK_IP" --endpoints "$STUCK_IP" reset \
  --system-labels-to-wipe=EPHEMERAL \
  --reboot \
  --graceful=false

# 4. Wait for reboot + Talos to re-apply machine config + kubelet to bootstrap fresh
sleep 90

# 5. Watch the rejoin (loop until you see the node + new etcd member)
for i in {1..15}; do
  echo "--- attempt $i ---"
  date
  kubectl $KCONFIG get nodes | head -15
  talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd members 2>&1 | head -8
  sleep 20
done
```

### Case B — stuck node is a worker

Same as Case A but **skip step 1+2** (workers don't have etcd members). Just run the reset (step 3) and wait.

## Verification

```bash
# 1. All expected Nodes Ready in kubectl
kubectl $KCONFIG get nodes -o wide
# Expect: 3 CPs + 7 workers = 10 Ready

# 2. etcd quorum back to 3/3 (CP case)
talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd members
# Expect 3 members all with PEER URL reachable

# 3. New CiliumNode for the rejoined node
kubectl $KCONFIG get ciliumnodes
# Expect entry for the rejoined node with the new INTERNALIP

# 4. RW post-check matches baseline
kubectl $KCONFIG -n risingwave get pods,svc,pvc > /tmp/rw-post-cn-fix.txt
diff /tmp/rw-pre-cn-fix.txt /tmp/rw-post-cn-fix.txt   # should be empty or trivial

# 5. No more cilium-node-reconciler failures
kubectl $KCONFIG -n kube-system get jobs --sort-by=.metadata.creationTimestamp | tail -5
```

## Post-procedure

- The cluster should be fully healthy. Cilium-node-reconciler will catch any transient CN/Node drift during the rejoin within 15 min.
- The PR #38 hostname-pin refactor (2026-06-18) ensures fresh clusters never hit this state — Talos hostname is pinned to vSphere VM identity from day 0. This runbook applies ONLY to legacy clusters where hostname was changed mid-life.

## Related

- `iaac-talos-flux-platform/infrastructure/prometheus/kubelet-not-registering.yaml` — detection PromRule that fires this runbook
- `iaac-talos/deploy/terraform/modules/talos/main.tf` — hostname pin (PR #38, 2026-06-18)
- `iaac-talos-flux-platform/infrastructure/cilium-hygiene/cronjob.yaml` — CiliumNode reconciler (catches CN drift; doesn't catch this specific kubelet-PKI lockup)
- `/onprem-safety` skill Rules 4 (etcd quorum) + 5 (RW awareness) apply
