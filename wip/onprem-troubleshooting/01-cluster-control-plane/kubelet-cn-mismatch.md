# Kubelet TLS Client Cert CN-Mismatch Lockup

**Symptom:**
- Node shows `NotReady` in `kubectl get nodes` (or missing entirely after a reset)
- `talosctl service kubelet status` shows `Running OK`
- Kubelet logs contain:
  ```
  csr-: can only create a node CSR with CN=system:node:<OLD-HOSTNAME>
  nodes "<NEW-HOSTNAME>" is forbidden: User "system:node:<OLD-HOSTNAME>" cannot read/get/list resource "nodes"
  ```
- `talosctl get hostnamestatus` shows the NEW hostname (not what kubelet's cert thinks it is)

**Root cause:**
Kubelet's TLS client cert has CN bound to the previous hostname. Kubernetes Node Authorizer enforces `CN MUST equal target node name` for both CSR creation and Node API access. Kubelet can rotate its cert via CSR — but only for the identity already in its cert. Chicken-and-egg: cert says `cp-2`, kubelet wants to identify as `cp-3`, every CSR rejected, cert never rotates.

Surfaces on Talos when:
- Machine config patched to change `machine.network.hostname` (Terraform apply OR `talosctl patch`)
- Kubelet restarts with new hostname-override
- Existing kubelet client cert in `/system/secrets/kubelet/` retains the OLD CN

**IaC coverage:** ✓ (prevention via PR #38) + ⚠ (recovery via runbook — manual trigger)

**IaC location:**
- `iaac-talos/deploy/terraform/modules/talos/main.tf` — hostname pinned to `vsphere_virtual_machine.vm[count.index].name` (VM identity) instead of list-index (PR #38)
- `iaac-talos/deploy/docs/runbooks/kubelet-cn-mismatch-recovery.md` (to be PRed from `wip/iac-sweep-jun18/track1.5-cilium-hygiene/runbook-kubelet-cn-mismatch-recovery.md`)

### Resolution via IaC

For FRESH clusters: PR #38 prevents this entire class of bug. Talos hostname is pinned to vSphere VM identity from day 0, never list-index. Machine config changes for hostname now NEVER happen mid-life.

For LEGACY clusters or after manual hostname patches: no auto-fix — wiping EPHEMERAL is too risky (drops etcd member if CP). Use one of the manual cases below.

### Manual resolution

**Case A — stuck node has OLD cert CN, wants NEW hostname (e.g., reset + rejoin scenario)**

Used when the cert is genuinely orphaned and the new hostname is the desired identity going forward.

```bash
export TALOSCONFIG=/tmp/talosconfig-op-usxpress-dev
STUCK_IP=<the-IP-shown-in-the-alert>

# 1. Confirm stuck (not transient API server flap)
talosctl --nodes "$STUCK_IP" --endpoints "$STUCK_IP" service kubelet status
talosctl --nodes "$STUCK_IP" --endpoints "$STUCK_IP" logs kubelet 2>&1 | grep -i "csr-\|forbidden" | tail -5

# 2. If stuck node is a CP, find + remove its etcd member
talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd members
STUCK_ETCD_ID=<member-id-from-list>
talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd remove-member "$STUCK_ETCD_ID"

# 3. Reset stuck node — wipes EPHEMERAL (kubelet PKI + etcd data + pod state)
#    Keeps STATE (machine config + secrets), reboots
talosctl --nodes "$STUCK_IP" --endpoints "$STUCK_IP" reset \
  --system-labels-to-wipe=EPHEMERAL \
  --reboot \
  --graceful=false

# 4. Wait + watch rejoin
sleep 90
for i in {1..15}; do
  echo "--- attempt $i ---"
  kubectl get nodes
  talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd members
  sleep 20
done
```

**Case B — stuck node has CORRECT cert CN, but machine config has WRONG hostname (e.g., bad TF apply pushed wrong index)**

This is a SAFER fix: just patch the machine config back to match the cert CN that's already valid. No reset, no PKI churn, no etcd disruption.

```bash
# Push the CORRECT hostname back into the machine config
# Replace `<correct-hostname>` with what the kubelet cert CN expects (e.g., talos-wk-op-dev-5)
talosctl --nodes "$STUCK_IP" --endpoints "$STUCK_IP" patch machineconfig --patch '[
  {"op":"replace","path":"/machine/network/hostname","value":"<correct-hostname>"},
  {"op":"replace","path":"/machine/kubelet/extraArgs/hostname-override","value":"<correct-hostname>"}
]'
```

Talos applies the patch without reboot. Kubelet restarts with the correct hostname-override, cert CN now matches target node name, registration succeeds within ~30s.

**PROVEN twice on 2026-06-19** for `.27` (talos-wk-op-dev-5) and `.21` (talos-wk-op-dev-7) — both flipped Ready immediately, no further intervention.

**Case B-2 follow-up: bounce istio-cni + ztunnel**

After hostname patch, the DaemonSet pods on that node retain stale state tied to the kubelet socket — bounce them so they pick up the new node identity:

```bash
NODE="<correct-hostname>"
kubectl -n istio-system delete pod \
  -l app=ztunnel \
  --field-selector spec.nodeName=$NODE
kubectl -n istio-system delete pod \
  -l k8s-app=istio-cni-node \
  --field-selector spec.nodeName=$NODE
```

Without this, new pods scheduled on the node fail sandbox setup with `no ztunnel connection`.

### Verification

```bash
# 1. All expected Nodes Ready
kubectl get nodes -o wide
# Expect: 3 CPs + 7 workers = 10 Ready

# 2. CiliumNode now matches kubectl Node
kubectl get ciliumnodes

# 3. Kubelet logs clean (no CSR errors in last 5 min)
talosctl --nodes "$STUCK_IP" --endpoints "$STUCK_IP" logs kubelet 2>&1 | \
  grep -i "csr-\|forbidden" | tail -5
# Expect: empty

# 4. RW post-check (if it's a worker that hosts RW pods)
kubectl -n risingwave get pods,svc,pvc
```

### Prevention

- PR #38 (iaac-talos) pins Talos hostname to vSphere VM identity. Fresh clusters never hit this.
- Any future manual `talosctl patch machineconfig` involving hostname MUST go through review — the TF code now derives hostname from VM identity, so a patch that disagrees creates drift.
- PrometheusRule `KubeletNotRegistering` + `KubeletCSRForbidden` detect this within 30 min (drafted at `wip/iac-sweep-jun18/track1.5-cilium-hygiene/prometheusrule-kubelet-not-registering.yaml`).

### Related

- [[ciliumnode-drift]] — usually accompanies CN-mismatch (the CiliumNode also gets stale)
- [[cluster-dns-failure]] — if CP is stuck, CoreDNS on that CP becomes unreachable to other pods
- [[istio-cni-ztunnel-stale]] — Case B-2 follow-up requires DS bounce
- [[../06-incidents-timeline/2026-06-19-dns-irsa-rw-cascade]] — tonight's full cascade

### Memory pointers

- `[Session state Jun 19]` — runbook proven twice tonight (.27 + .21)
- `[onprem_topology_corrected_jun17]` — current CP/worker IP map
