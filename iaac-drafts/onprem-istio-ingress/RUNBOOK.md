# istio-ingress deploy runbook (op-usxpress-dev)

**Cluster**: op-usxpress-dev (Talos, kubectl context `admin@op-usxpress-dev`)
**Executed from**: WSL2 (codespace can't reach the cluster)
**Protection rule**: Any change MUST NOT degrade running RW
(see `memory/feedback_protect_rw_onprem_workload.md`).

**Pattern confirmed 2026-05-13**: platform owns the data plane (DaemonSet);
app teams own their Gateway+VirtualService routing. This runbook ships ONLY
the data plane in Flux; the smoke-test Gateway is applied by hand.

---

## 0. Sanity context check

```bash
kubectl config current-context
# Expect: admin@op-usxpress-dev
kubectl get nodes
# Expect: 3 CP + 5 worker, all Ready
```

---

## 1. Pre-flight RW protection check

**Non-negotiable. Captures baseline; re-run after each change.**

```bash
# RW CR
kubectl get rw risingwave -n risingwave
# Expect: RUNNING=True

# RW pods
kubectl get pods -n risingwave --no-headers | awk '$2 != "1/1" && $2 != "0/1"'
# Expect: NO output (all pods 1/1; the known stuck risingwave-compactor-*-d6pkq 0/1 Error is ignored by the filter)

# psql round-trip
PGPASSWORD='WLThdeIQznAJ9RxSdWV3SaCFMY1yFjO1' \
  psql -h 10.10.82.26 -p 32567 -U root -d dev -c 'SELECT 1;'
# Expect: 1 row, value 1

# Existing NodePort sprawl — snapshot for post-flight diff
kubectl -n risingwave get svc -o wide | grep NodePort
# Expect: 3 services — frontend-lb:32567, pg-postgresql-0:32546, risingwave-console-*:32114
```

**Baseline captured 2026-05-13 (pre-deploy)**:
- RW RUNNING=True, AGE=13d ✅
- psql `SELECT 1` returned 1 row ✅

---

## 2. Sanity check: hostPort 80/443 unbound across workers

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.containers[*].ports[?(@.hostPort)].hostPort}{"\n"}{end}' \
  | grep -E ': (80|443) ?$' || echo "Clear"
# Expect: Clear
```

---

## 3. Apply: commit + push to both repos

In WSL:

```bash
# A. Platform repo — DaemonSet manifests
cd ~/work/iaac-talos-flux-platform
git checkout op-dev && git pull --ff-only origin op-dev
mkdir -p infrastructure/istio-ingress
# Copy the 3 yaml files from onprem_istio_ingress_iaac/infrastructure/istio-ingress/
# (namespace.yaml, release.yaml, values.yaml — NO gateway.yaml)
git add infrastructure/istio-ingress
git status   # verify only the new dir is staged
git commit -m "feat(istio-ingress): hostNetwork DaemonSet ingressgateway (data plane only)"
git push origin op-dev

# B. Cluster repo — Kustomization wiring
cd ~/work/iaac-talos-flux-cluster
git checkout master && git pull --ff-only origin master
# Append snippet from onprem_istio_ingress_iaac/cluster-kustomization-snippet.yaml
# into clusters/bm-dev/flux-system/infra.yaml
git diff clusters/bm-dev/flux-system/infra.yaml   # verify only an addition
git add clusters/bm-dev/flux-system/infra.yaml
git commit -m "feat(bm-dev): wire istio-ingress kustomization"
git push origin master
```

---

## 4. Watch Flux reconcile

```bash
flux reconcile source git infra
flux reconcile kustomization istio-ingress

kubectl get ks -n flux-system istio-ingress -w
# Expect within ~5m: READY=True

kubectl get hr -n istio-ingress
kubectl get pods -n istio-ingress -o wide
# Expect: 5 DaemonSet pods (one per worker), all 1/1 Running, each on a different worker IP
```

---

## 5. Post-flight RW protection check

**Re-run §1 commands. All four outputs must match baseline.**

If ANY differs → execute Rollback (§8). Otherwise proceed.

---

## 6. Smoke test — wire brands-api end-to-end

The DaemonSet is alive but Envoy has no listeners yet (no Gateway resource exists).
Create the missing `enterprise/brands-api` Gateway that the existing VS already references:

```bash
# Apply the smoke-test Gateway (HAND-APPLIED — not in any Flux Kustomization)
kubectl apply -f app-gateways/brands-api.yaml

# Verify it landed
kubectl -n enterprise get gateway brands-api
# Expect: present, no errors

# Verify Envoy got config (config_dump shows the new listener)
INGRESS_POD=$(kubectl -n istio-ingress get pod -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}')
kubectl -n istio-ingress exec $INGRESS_POD -- pilot-agent request GET listeners | grep -i brands || \
  kubectl -n istio-ingress exec $INGRESS_POD -- curl -s localhost:15000/config_dump | grep -A2 brands
# Expect: at least one mention of brands-api / api.brands.dev.usxpress.io

# The actual smoke test from VPN
curl -v -H "Host: api.brands.dev.usxpress.io" http://10.10.82.26/
# Expect: brands-api responds with its real HTTP response (200/healthcheck/etc)
# A 503 means Gateway is bound but upstream brands-api Service/pod isn't reachable — separate issue

# Confirm DaemonSet coverage (any worker IP works)
curl -v -H "Host: api.brands.dev.usxpress.io" http://10.10.82.27/
# Expect: same response
```

**Success signal**: real HTTP response from brands-api via worker IP. That proves:
- DaemonSet binds 80 on every worker ✅
- Envoy receives Gateway+VS config from pilot ✅
- VirtualService routes to brands-api Service ✅
- VPN → worker IP routing works at L7 ✅

---

## 7. Post-smoke-test RW protection check

**Re-run §1 commands one more time.** Applying the Gateway resource is additive but verify nothing drifted.

---

## 8. Rollback

Only if RW degrades OR ingressgateway pods fail OR brands-api breaks.

### Rolling back the smoke-test Gateway only (safest)

```bash
kubectl delete -f app-gateways/brands-api.yaml
# Gateway gone; DaemonSet stays up; brands-api still reachable via its existing NodePort (if any) or in-cluster
```

### Rolling back the full DaemonSet

```bash
cd ~/work/iaac-talos-flux-cluster
git revert HEAD
git push origin master
flux reconcile kustomization istio-ingress
# Kustomization deletes (prune=true); namespace `istio-ingress` goes away
kubectl get ns istio-ingress   # Expect: NotFound
```

Platform-repo commit can stay — without the cluster Kustomization, Flux doesn't apply it.

---

## 9. Next steps (NOT part of this deploy)

- **Other 4 VSes**: each needs its own Gateway resource (`attrition/attrition-api`, `geoservices/...`, `io-curt/...`, `octopus/octopusworker`). Same pattern as brands-api.yaml. Apply one at a time with RW checks each.
- **Piece 2 (external-dns + Route53)**: gives apps real DNS names instead of raw `10.10.82.x` IPs. ONPREM-25.
- **Piece 3 (cert-manager public ClusterIssuer)**: uncomment HTTPS block in each app's Gateway.
- **Architectural decision**: long-term home for per-app Gateway YAML (MageRunner-generated vs platform-managed dir).

---

## Troubleshooting cheatsheet

| Symptom | Likely cause | Action |
|---|---|---|
| Kustomization `NotReady`, PSA error | Namespace label missing | Re-apply `namespace.yaml`; verify `enforce: privileged` |
| Pods `CreateContainerError`, capability error | `NET_BIND_SERVICE` not granted | Check `containerSecurityContext.capabilities.add` in values |
| Pods Running, `curl` → connection refused | hostNetwork not engaging | `kubectl get po -n istio-ingress -o jsonpath='{.items[0].spec.hostNetwork}'` should be `true` |
| Pods Running, `curl` → connection refused (after Gateway applied) | Envoy didn't get config | Check `pilot-agent request GET listeners`; verify Gateway selector matches DaemonSet pod labels (`istio: ingressgateway`) |
| `curl` → 503 no upstream | Gateway bound but brands-api Service unreachable | `kubectl -n enterprise get svc,ep`; check brands-api pod health (separate issue from piece 1) |
| `curl` → 404 from istio-envoy | VS host mismatch | Verify `Host:` header matches VS `spec.hosts` exactly |
| RW psql fails post-deploy | Something broke RW — STOP, rollback | Execute §8 |
