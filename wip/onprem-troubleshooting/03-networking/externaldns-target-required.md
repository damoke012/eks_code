# ExternalDNS v0.20.0 — Per-VirtualService Target Required

**Symptom:**
- VirtualService bound to a `shared-http` Gateway resolves a hostname (e.g., `api.brands.op-dev.usxpress.io`) but `dig` returns no answer or NXDOMAIN externally
- `kubectl -n external-dns logs deploy/external-dns` shows: no endpoints generated for the VirtualService
- Or: `Skipping endpoint generation` for the VS
- The Gateway Service is `ClusterIP` (not LoadBalancer or NodePort)

**Root cause:**
ExternalDNS `istio-virtualservice` source in v0.20.0 produces **ZERO endpoints** when the bound Gateway's Service is `ClusterIP` AND no per-VS `external-dns.alpha.kubernetes.io/target` annotation is set.

Flags that LOOK like they should work — but don't:
- `--default-targets`: applies cluster-wide, not VS-specific
- `--force-default-targets`: doesn't override the ClusterIP exclusion logic

The hostNetwork + ClusterIP pattern used on op-usxpress-dev (Cilium L2 announcements aren't reachable from corp VPN — see [[../06-incidents-timeline/2026-06-19-dns-irsa-rw-cascade]] for background) needs per-VS annotation.

**IaC coverage:** ✓ (codified pattern — every VS template includes the annotation)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/<team>/virtualservice.yaml` — every VS includes:
  ```yaml
  metadata:
    annotations:
      external-dns.alpha.kubernetes.io/target: "<worker-host-ip>"
  ```
- Or for hostport ingress: target points to worker public IPs

### Resolution via IaC

Pattern is codified — new VS files always include the annotation. PR review catches missing annotation.

### Manual resolution

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# Identify the affected VS
kubectl $KCONFIG -n <ns> get virtualservice <name> -o yaml | grep -A 2 annotations

# Add the target annotation
kubectl $KCONFIG -n <ns> annotate virtualservice <name> \
  external-dns.alpha.kubernetes.io/target="<gateway-worker-IP>" \
  --overwrite

# external-dns picks it up within 5 min (default reconcile interval)
# To force immediate:
kubectl $KCONFIG -n external-dns rollout restart deploy external-dns
```

### Verification

```bash
# 1. external-dns produces endpoint
kubectl $KCONFIG -n external-dns logs deploy/external-dns --tail=50 | \
  grep -i <hostname>
# Expect: "Add" or "Update" record for <hostname>

# 2. DNS resolves externally (from corp VPN)
dig <hostname>.op-dev.usxpress.io +short
# Expect: the target IP

# 3. End-to-end HTTPS via VS
curl -sk https://<hostname>.op-dev.usxpress.io -o /dev/null -w "HTTP %{http_code}\n"
# Expect: HTTP 200 or 302
```

### Prevention

- Every VS PR includes the `target` annotation (template enforced)
- Code review: any VS without the annotation is BLOCKED until added
- For QA + PROD: same pattern carries forward (verified 2026-06-01)
- If switching Gateway Service to NodePort or LoadBalancer in future, the annotation can be removed (but harmless to leave)

### Related

- [[../05-terraform-octopus/iaac-talos-branch-base]] — VS files live in iaac-talos-flux-platform `op-dev` branch
- [[../06-incidents-timeline/2026-06-19-dns-irsa-rw-cascade]] — earlier session related to ingress patterns
- Memory: `[Phase 1 cleanup chain closed — 2026-06-01]`

### Memory pointers

- `[feedback_externaldns_v020_target_required]` — codified gotcha memory
- `[Per-team cert pattern]` — shared-http Gateway pattern context
