# risingwave-operator chart ClusterRoleBinding has hardcoded subject namespace

**Category**: 04-secrets-credentials (RBAC)
**First seen**: 2026-06-23 op-usxpress-dev rw-2 namespace
**Severity**: silent — operator runs initially, crashloops after FIRST container restart, with cluster-scoped reconciliation degraded

## Symptom

The risingwave-operator pod enters CrashLoopBackOff with errors like:

```
ERROR controller-runtime.cache.UnhandledError Failed to watch:
configmaps is forbidden: User
"system:serviceaccount:risingwave-2:risingwave-operator"
cannot list resource "configmaps" in API group "" at the cluster scope

setup problem running manager
"error": "failed to wait for meta-pod-role-labeler caches to sync"
```

After supplementing configmaps + pods cluster-scoped access, you may see additional `Failed to watch` errors for `statefulsets.apps`, `deployments.apps`, `services`, `secrets`, `jobs.batch`, and the RisingWave CRDs themselves.

**Critical:** the operator may run for days BEFORE the symptom appears. It only manifests after the operator pod gets a container restart (which happens with pod-identity-webhook rolls, node migrations, or chart upgrades). Controller-runtime cache resync hits the missing perms, startup probe fails, kubelet kills the container, then CrashLoopBackOff.

## Why

The risingwave-operator Helm chart (v0.1.35+, from risingwavelabs.io) installs:

- `ClusterRole/risingwave-operator` — has FULL CRUD on configmaps, pods, services, secrets, statefulsets.apps, deployments.apps, jobs.batch, risingwaves, risingwavescaleviews, events, CRDs, kruise statefulsets/clonesets ✅
- `ClusterRole/risingwave-operator-proxy` — for manager metrics proxy
- `ClusterRoleBinding/risingwave-operator` — **subject HARDCODED to `{ kind: ServiceAccount, name: risingwave-operator, namespace: risingwave }`** ❌

The chart's `values.yaml` does NOT parameterize `subjects[0].namespace`. The chart assumes there's exactly ONE install, in a namespace called `risingwave`.

When the chart is installed a SECOND time in a different namespace (e.g., `risingwave-2`), the second install's HelmRelease creates a ClusterRoleBinding with the SAME name. Since cluster-scoped resources aren't namespaced, the two installs collide:

- Either the second install's binding overwrites the first → Tim's operator breaks
- Or the chart skips re-installing it because the name exists → the second install's SA has zero cluster-scoped perms

In practice on op-usxpress-dev: the binding's subject is `namespace: risingwave` (whoever installed first won). rw-2 operator's SA `risingwave-2:risingwave-operator` is NOT bound to the chart's full ClusterRole at all.

## Fix (two options)

### Option A — Cleanest: forward-compatible binding to chart's existing ClusterRole

Add a uniquely-named ClusterRoleBinding that binds the chart's existing ClusterRole to the correct SA. As the chart updates its ClusterRole over time, your binding inherits those changes automatically.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: risingwave-operator-<ns>-bind   # unique name to prevent chart-installer overwrite
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: risingwave-operator
subjects:
  - kind: ServiceAccount
    name: risingwave-operator
    namespace: <correct-ns>             # e.g., risingwave-2
```

### Option B — Explicit supplemental ClusterRole + binding

Useful if you want explicit control over what the operator can access:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: risingwave-operator-supplemental
rules:
  - apiGroups: [""]
    resources: ["configmaps", "pods", "services", "secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets", "deployments"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["risingwave.risingwavelabs.com"]
    resources: ["risingwaves", "risingwavescaleviews"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: risingwave-operator-supplemental
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: risingwave-operator-supplemental
subjects:
  - kind: ServiceAccount
    name: risingwave-operator
    namespace: <correct-ns>
```

This was the approach used for rw-2 (PRs #15 + #16 on iaac-risingwave-2). It maintains parallel rules but doesn't accidentally inherit future chart additions.

## Detection

```bash
# Which ClusterRoleBindings target this SA?
kubectl get clusterrolebinding -o json \
  | jq -r '.items[] | select(.subjects[]? | select(.namespace=="<ns>" and .name=="risingwave-operator")) | "\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"'
# If empty or only supplemental: chart binding skipped this SA

# Confirm via can-i
for r in statefulsets.apps deployments.apps services secrets jobs.batch configmaps pods \
         risingwaves.risingwave.risingwavelabs.com risingwavescaleviews.risingwave.risingwavelabs.com; do
  ans=$(kubectl auth can-i list $r --all-namespaces --as=system:serviceaccount:<ns>:risingwave-operator)
  printf "%-60s %s\n" "$r" "$ans"
done
# All 9 should return "yes". If any return "no", you've hit this.
```

## Recovery

After applying the supplemental ClusterRole + binding via Flux:

```bash
# Force a fresh operator pod (cache is per-pod)
kubectl -n <ns> delete pod -l app.kubernetes.io/name=risingwave-operator

# Verify
sleep 30
kubectl -n <ns> get pods -l app.kubernetes.io/name=risingwave-operator
kubectl -n <ns> logs deploy/risingwave-operator --tail=200 | grep -c "Failed to watch"
# expect: 0
```

## How to apply to QA / PROD

- Any cluster running >1 risingwave-operator install: add a supplemental binding (Option A or B) for EACH install whose namespace isn't `risingwave`
- For QA: pre-stage the supplemental binding BEFORE deploying the operator (avoid the post-install crashloop discovery)
- File upstream issue at risingwavelabs/risingwave-operator: chart should template `subjects[0].namespace` from `.Values.namespace` or `.Release.Namespace`
- A namespace-scoped Role + RoleBinding `risingwave-operator` also gets installed by the chart inside the operator's namespace — that part works regardless

## Reference incident

op-usxpress-dev 2026-06-23:
- PR #15 on iaac-risingwave-2 — partial fix (configmaps + pods only)
- PR #16 on iaac-risingwave-2 — full 9-resource extension
- After PR #16: 9/9 perms = yes, 0 Failed-to-watch errors, RW CR Running 28d

## Related

- [`feedback-risingwave-operator-chart-missing-cluster-rbac`](../../memory/feedback_risingwave_operator_chart_missing_cluster_rbac.md)
- Multi-tenancy considerations: this affects ANY chart that hardcodes subject namespace in its installed ClusterRoleBinding
