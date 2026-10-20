---
name: onprem-platform-component-inventory
description: "MEASURED 2026-10-20 on op-usxpress-qa: 183 pods, 20 namespaces, 30 Flux Kustomizations all Ready. The CNI is Cilium, Istio runs in ambient mode (ztunnel), Rook-Ceph is live with 62 pods, and aws-iam-authenticator is Flux-managed"
metadata:
  type: project
---

**op-usxpress-qa, 2026-10-20** — the first full component sweep. Settles several things that
were previously "believed, never checked".

| Namespace | Pods | |
|---|---|---|
| `rook-ceph` | **62** | ✅ **Rook-Ceph is live**, not merely stood up once |
| `velero` | **44** | backup; the count suggests a node agent per node plus jobs |
| `kube-system` | 32 | |
| `istio-system` | 28 | |
| `risingwave` | 13 | the one application |
| `prometheus` | 13 | |
| `istio-ingress` | 10 | one gateway per node |
| `cert-manager` | 6 | + trust-manager + istio-csr |
| `kyverno` | 5 | policy |
| `argocd` | 5 | |
| `flux-system` | 4 | the four controllers |
| `keda`, `external-secrets`, `etcd-backup` | 3 each | **KEDA was not previously recorded** |
| `pod-identity-webhook`, `ecr-credentials` | 2 each | IRSA webhook; the pull-secret refresher |
| `reloader`, `local-path-storage`, `grafana`, `external-dns` | 1 each | |

**Corrections to earlier assumptions:**

* **The CNI is Cilium** — `cilium-lb` and `cilium-hygiene` Kustomizations, 105 days old. The
  per-node /24 out of `10.244.0.0/16` is Cilium's allocation, not Flannel's.
* **Istio runs in ambient mode** — there is an `istio-ztunnel` Kustomization, so workloads are
  meshed without a sidecar each.
* **`aws-iam-authenticator` is a Flux Kustomization, 83 days old** — QA's AWS SSO is fully
  GitOps-managed, which is what makes it a clean copy for another cluster.
* **`gateway-api` is pinned to tag `v1.4.0`**, confirmed live.
* **KEDA is installed** and was in none of our notes.

**The two-source model, confirmed live:** every Kustomization reports
`op-qa@sha1:625b1cc9…` except `flux-system` itself, which reports
`master@sha1:db4812ce…`. That is the cluster repo and the platform repo, visible in one
listing — and the reason reconciling `flux-system` does not reconcile the rest.

**All 30 Kustomizations were `True`** at the time of the sweep.

⚠️ **This is QA.** dev and prod are not measured, and dev is known to differ at least in Flux
version. Do not quote these counts for another cluster.

Related: [[onprem-k8s-132-out-of-support]] (the same sweep), [[onprem-gitops-repo-topology]].
