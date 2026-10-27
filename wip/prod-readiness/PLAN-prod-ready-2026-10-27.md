# op-usxpress-prod: production readiness, measured 2026-10-27

All numbers below were measured today against the live clusters, not recalled.
Where a belief was disproven it is corrected in place rather than deleted.

## Landed today

**INFRA-1661 — AWS SSO on the prod API server. DONE, mechanism proven.**

* Release `0.5.0` deployed to Production 2026-10-27, 21 minutes, no incident.
* Both flags present on all three control-plane nodes:
  * `--authentication-token-webhook-config-file=/var/lib/aws-iam-authenticator/kubeconfig.yaml`
  * `--authentication-token-webhook-cache-ttl=2m0s`
* 13/13 nodes Ready afterwards. `kube-apiserver-talos-cp-op-prod-{1,2,3}` all Ready, 0 restarts.
* `[HEALTH] Waiting for istiod` burned its full 1200s and continued — the known defect, not a fault.

## The one thing blocking a human SSO login

Not a cluster problem. Measured in Identity Center (`usx-mgmt`, instance
`ssoins-7223eb10c0b8ac39`, store `d-90676260a8`):

| | permission set | assigned to |
|---|---|---|
| prod 937464026810 | `usx-on-prem-admins` | GROUP `usx-aws-admin` |
| qa 527101283767 | `op-qa-platform-admin` | **USER** doke@, **USER** ifagbemi@ |

`doke@usxpress.com` is in `usx-technology`, `usx-cloud-admin`,
`usx-technology-lead`, `usx-engineering` — **not** `usx-aws-admin`. So the login
fails with `GetRoleCredentials ForbiddenException`, which is Identity Center
refusing an unassigned principal, not the cluster refusing an unauthorised one.

⚠️ **Do not "make prod identical to QA" here.** Prod's group-based grant is the
better model; QA's two named-user grants are standing personal exceptions.
Recommended: assign `usx-on-prem-admins` to `usx-cloud-admin` on prod, and
migrate QA off per-user grants to the same group.

## The RisingWave blocker

`risingwave-onprem` Kustomization has been **Ready=False for 55 days** on prod.
Every other RW piece is healthy (`risingwave-operator` Ready,
`risingwave-routes` Ready). One Deployment holds it:

```
health check failed: stalled resources: [Deployment/risingwave/risingwave-console status: 'Failed']
```

**Root cause, measured:**

| | |
|---|---|
| strategy | `RollingUpdate` (maxSurge 25%, maxUnavailable 25%) |
| volume | PVC `risingwave-console-data`, **ReadWriteOnce**, ceph-block |
| old pod | `risingwave-console-5b678c59c4-lbzps` on `talos-wk-op-prod-platform-2`, Running since 2026-09-01 |
| new pod | `risingwave-console-6ffc5644d9-x4bmp` on `talos-wk-op-prod-platform-3`, **Pending since 2026-10-13** |

A ReadWriteOnce volume attaches to one node. RollingUpdate starts the new pod
before stopping the old one, the scheduler places it on a different node, and it
waits for a volume that is only released when the rollout completes — which it
cannot. Both ReplicaSets carry the **same image** (`v0.7.4`), so this was not an
upgrade; something merely triggered a rollout on 2026-10-13.

All five init containers show `started=false` — even `fix-data-dir`, a busybox
`mkdir`. Nothing ran. The pod never got as far as a container, which is the tell
that it is a volume problem and not a script problem. Events are long expired.

**Masked by `Available=True`:** the old pod keeps serving, so every dashboard
reads healthy. Related: [[helmrelease-ready-hides-failed-history]].

**Fix, two parts:**

1. `strategy: {type: Recreate}` on the console Deployment — PR to
   `iaac-risingwave-onprem`, all three environments.
2. The live object keeps its `rollingUpdate` block and the API rejects a
   Deployment carrying both, so a plain Flux apply fails. Needs `force: true`
   on the Kustomization or a one-time delete so Flux recreates it.
   Consequence: the console UI restarts. The RW cluster itself is untouched.

## Parity: prod vs QA, measured

Identical: 13 nodes each, same namespaces, all `v1.32.0`, IRSA role ARNs 0/7
wrong on both, 41 of 42 Kustomizations Ready on prod vs 42/42 on QA.

⛔ **Disproven today:** I expected prod to carry dev role ARNs in IRSA
annotations (platform branches are copies of one another). It does not — 0 of 7
wrong. [[manifests-copied-across-branches]] still holds for other fields but not
for these.

### Gaps, worst first

**1. Prod's Helm charts float; QA's are pinned.** Backwards.

| chart | QA | prod |
|---|---|---|
| external-secrets | `2.2.0` | `2.2.x` |
| grafana | `8.15.0` | `8.x` |
| keda | `2.19.0` | `2.19.x` |
| kyverno | `3.3.9` | `3.3.x` |
| prometheus-stack | `72.9.1` | `72.x` |
| velero | `8.7.2` | `8.x` |

Production is the only environment permitted to float, and it is the only one
that does. `grafana: 8.x` means a minor chart bump reaches prod unattended,
without ever being seen in QA. That inverts the promotion model.

**2. `argocd-apps` Kustomization exists on QA, not prod.** 41 vs 42.

**3. `risingwave-console.op-prod.usxpress.io` has no route.** QA serves 7
hostnames, prod 6; the console is the missing one — consistent with the
Deployment above.

## Not parity gaps — QA has these too, so copying QA will not fix them

* **No alert delivery on ANY cluster** (INFRA-1659). Prod fails silently.
* **No promotion gate for RisingWave**: every cluster tracks `branch: main` at
  5m, so merging **is** deploying to production.
* **Kubernetes 1.32 EOL** since 2026-02-28, never patched past `.0`, all three.
* **etcd restore never tested** on any cluster, though snapshots are proven.

## Not a problem

56 (qa) / 57 (prod) pods "not Running" are all `Succeeded` — completed Velero
kopia maintenance and Rook OSD prepare jobs. Hourly Velero backups are running
on prod across argocd, cert-manager, grafana, istio, kyverno, prometheus,
reloader, risingwave, rook-ceph and velero itself.
