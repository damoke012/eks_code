# CiliumNode Drift — Orphan / Stale IP / Missing CN

**Symptom:**
- `kubectl get ciliumnodes` shows entries that don't match `kubectl get nodes -o wide`
- Examples:
  - A node Ready in kubectl but NO CiliumNode entry
  - A CiliumNode with `INTERNALIP` different from the kubectl Node's `INTERNAL-IP`
  - A CiliumNode for a node that's been deleted (`talos-cp-op-dev-3` exists at .179 but kubectl shows cp-3 was reset)
- Downstream effects:
  - Pod-to-pod traffic on affected nodes silently fails (Cilium eBPF can't route)
  - In-cluster DNS times out (CoreDNS endpoint on a CiliumNode-broken CP becomes unreachable)
  - ztunnel xDS connection to istiod fails

**Root cause:**
The CiliumNode CRD is the agent's view of cluster nodes. It's maintained by:
- Each Cilium agent's local view of the node it runs on
- Cluster events watched by the agent

Drift happens when:
- Node IP changes (kubelet re-registration after VIP loss / cert rotation)
- Hostname patched (Talos machine config change → kubelet re-registers as different identity)
- CP reset wipes EPHEMERAL → node rejoins fresh; old CN entry not cleaned up

Without auto-healing, drift persists indefinitely. Cilium's reconciliation does NOT delete orphan CNs.

**IaC coverage:** ⚠ (reconciler CronJob designed + deployed, but image has entrypoint bug)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/cilium-hygiene/cronjob.yaml` — `cilium-node-reconciler` CronJob (PR #43 — merged, but image broken)
- `iaac-talos-flux-cluster/clusters/bm-dev/flux-system/infra.yaml` — Flux wire-up (PR #17 merged)

### Resolution via IaC (when reconciler works)

The CronJob runs every 15 min on workers (CP `nodeAffinity` exclusion). It handles 4 drift cases:

1. **CASE 1 — Orphan CiliumNode** (CN exists, matching kubectl Node doesn't) → delete CN
2. **CASE 2 — Stale CiliumNode IP** (CN `INTERNALIP` ≠ kubectl Node `INTERNAL-IP`) → delete CN + bounce cilium agent on the node, recreates fresh
3. **CASE 3 — Ghost kubectl Node** (NotReady kubectl Node with duplicate IP of a Ready peer) → delete the Ghost Node
4. **CASE 4 — Stale NotReady Node** (kubectl Node NotReady > 30 min, sits alone) → delete

ENV configurables:
- `AUTO_REMEDIATE=true` — actually delete (vs dry-run report)
- `MIN_AGE_SECONDS=300` — only remediate entries older than this
- `NOTREADY_GRACE_SECONDS=1800` — CASE 4 threshold

**Current issue:** image `bitnamilegacy/kubectl:1.32` has `ENTRYPOINT=kubectl` (exec form). The K8s `command: ["/bin/sh", "-c", "..."]` doesn't override entrypoint — args get passed AS kubectl args, errors immediately with `You must provide one or more resources by argument or filename`.

**Fix (URGENT next-session PR):** swap to `alpine/k8s:1.32.6` or `rancher/kubectl:v1.32.0`, OR add explicit `command: []` + `args:` separation.

### Manual resolution (current path until image fixed)

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# 1. Identify drift — compare CiliumNode vs kubectl Node
kubectl $KCONFIG get nodes -o wide
kubectl $KCONFIG get ciliumnodes
# Look for mismatch in INTERNALIP, or missing entries

# 2. Delete stale CN for the affected node
kubectl $KCONFIG delete ciliumnode <stale-cn-name>

# 3. Bounce cilium agent on the affected node (recreates CN with current IP)
kubectl $KCONFIG -n kube-system delete pod \
  -l k8s-app=cilium \
  --field-selector spec.nodeName=<node-name>

# 4. Wait 30s for cilium agent respawn + new CN creation
sleep 30

# 5. Verify
kubectl $KCONFIG get ciliumnodes
# Expect: ALL nodes listed, InternalIP matching kubectl get nodes -o wide
```

### Verification

```bash
# 1. CN count matches Node count
test $(kubectl $KCONFIG get nodes --no-headers | wc -l) -eq \
     $(kubectl $KCONFIG get ciliumnodes --no-headers | wc -l) && echo "OK"

# 2. Per-node IP alignment (catches stale IPs)
join \
  <(kubectl $KCONFIG get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | sort) \
  <(kubectl $KCONFIG get ciliumnodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.addresses[?(@.type=="InternalIP")].ip}{"\n"}{end}' | sort) | \
  awk '$2 != $3 { print "MISMATCH: " $0 }'
# Expect: empty

# 3. DNS works (catches CN-drift breaking CoreDNS reachability)
kubectl $KCONFIG run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup kubernetes.default 2>&1 | tail -5
```

### Prevention

- **URGENT** — fix the reconciler image (single YAML edit). Restores auto-healing within 15 min of any drift.
- PR #38 hostname-pin prevents the most common drift source (kubelet hostname changes).
- PromRule `CiliumNodeDrift` (drafted) — fires when CN count ≠ Node count for > 10 min.
- Any operation that adds/removes/replaces a Talos node MUST be followed by a manual CN check until the reconciler image is fixed.

### Related

- [[kubelet-cn-mismatch]] — often paired (when CP-3 resets to fix cert CN, the CN entry also goes stale)
- [[cluster-dns-failure]] — DOWNSTREAM of CN drift on CoreDNS-hosting nodes
- [[cp-ip-shuffle]] — primary cause of CN drift on CPs
- [[../06-incidents-timeline/2026-06-19-dns-irsa-rw-cascade]] — tonight's DNS death traced to CP CN drift

### Memory pointers

- `[Cilium node-reconciler LIVE]` — reconciler design (image bug pending fix)
- `[Session state Jun 19]` — manual reconciler-equivalent applied tonight
- `[onprem_topology_corrected_jun17]` — CP/worker IP map
