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

## ✅ Prod measured the same day, and it is identical

`op-usxpress-prod` returns **the same pod count in 19 of 20 namespaces** — rook-ceph 62,
velero 44, kube-system 32, istio-system 28, prometheus 13, istio-ingress 10, cert-manager 6,
kyverno 5, argocd 5, flux-system 4, keda/external-secrets/etcd-backup 3 each,
pod-identity-webhook/ecr-credentials 2 each, reloader/local-path-storage/grafana/external-dns
1 each. Same 13-node layout, same Kubernetes version.

**The only difference is `risingwave`: 14 pods on prod against 13 on QA.**

**Why this matters more than it looks.** "Is prod production-ready?" is **not** a question
about missing platform components — prod has everything QA has, in the same quantity. The
remaining gaps are **configuration and behaviour**: whether alerts are routed, whether an IAM
role can write, how humans authenticate, and what version is running. That narrows the
readiness list sharply and removes a whole category of imagined work.

⚠️ **kube-system is 32 on both**, and QA's `aws-iam-authenticator` DaemonSet lives there. If
QA's authenticator pods are inside that 32 and prod's count matches, **prod may already be
running the authenticator** — which would change the sprint. Settle it with
`kubectl -n kube-system get ds,deploy -o name | grep -i auth` on each. **Equal counts are a
hint, never a finding.**

⚠️ **dev is not measured**, and is known to differ at least in Flux version.

Related: [[onprem-k8s-132-out-of-support]] (the same sweep), [[onprem-gitops-repo-topology]].
