# iaac-risingwave-onprem — RisingWave Production (Tim Preble's domain)

This repository holds the Infrastructure-as-Code for the **production RisingWave instance** running in the `risingwave` namespace on the `op-usxpress-dev` on-prem Talos cluster. It is **owned and maintained by Tim Preble**.

This README is a **read-only acknowledgement** authored by the Knight-Swift Cloud Platform team. It documents the boundary between Tim's RisingWave domain (the application, schemas, sealed secrets, chart values) and the cluster underlay that the Cloud Platform team operates beneath it. The Cloud Platform team does **not** push manifests to this repo; we coordinate with Tim before any change that could affect his namespace.

---

## Ownership

| Domain | Owner |
| --- | --- |
| RisingWave application (chart values, sealed secrets, schemas, pipelines, SQL artifacts) | Tim Preble |
| `risingwave` namespace contents | Tim Preble |
| Cluster underlay (Talos, Cilium, Rook-Ceph, Istio, Flux, ESO, cert-manager) | Cloud Platform team |
| This README | Cloud Platform team (read-only ack) |

**Cloud Platform commitment:** we do not push manifests to this repo. PRs from our side are limited to documentation acknowledgements like this README, and only with Tim's coordination. All RisingWave-internal changes flow through Tim.

---

## Namespace and cluster targeting

- **Cluster:** `op-usxpress-dev` (Talos v1.32.0, 3 control plane + 7 workers, API VIP `10.10.82.50:6443`).
- **Namespace:** `risingwave`.
- **Pod placement:** workers `.26`, `.28`, `.180` host the active RisingWave pods.
- **Reconciliation:** Flux CD reconciles from `main` of this repo directly. There is no staging branch; `main` is the source of truth.
- **Default branch:** `main`.

The three worker nodes that carry RW pods are operationally significant — any maintenance, drain, reboot, or Talos upgrade affecting `.26`, `.28`, or `.180` is treated as RW-affecting and requires Tim coordination.

---

## Relationship to iaac-risingwave-2

The Cloud Platform team operates a **separate, team-owned RisingWave instance** in the `risingwave-2` namespace, sourced from `variant-inc/iaac-risingwave-2`. That instance exists so the Cloud Platform team can:

- Prove cluster-wide patterns (IRSA, ESO, Velero PVC backup, ceph-block storage, Istio routing, gateway+DNS+cert layout) on a RisingWave-shaped workload **without touching Tim's prod**.
- Burn in operator RBAC supplements, chart upgrades, and storage class behavior before recommending them.
- Carry our own debugging and on-call load so Tim's instance can stay stable.

`risingwave-2` is **not a replacement** for this repo's instance. It is a validation surface. Production RisingWave for the business is and remains Tim's instance in the `risingwave` namespace, governed by this repo.

---

## Cloud Platform pre/post check pattern

Before any cluster-wide change that **could** propagate into the `risingwave` namespace (see the list further down), the Cloud Platform team captures a baseline of Tim's namespace, applies the change, then diffs and validates. This is non-negotiable per the binding safety rule.

### Pre-check (baseline capture)

```bash
# Baseline pods, services, PVCs, and endpoints in Tim's namespace.
TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p ~/wip/rw-prepost/$TS

kubectl -n risingwave get pods -o wide       > ~/wip/rw-prepost/$TS/pods.pre
kubectl -n risingwave get svc -o wide        > ~/wip/rw-prepost/$TS/svc.pre
kubectl -n risingwave get pvc                > ~/wip/rw-prepost/$TS/pvc.pre
kubectl -n risingwave get endpoints          > ~/wip/rw-prepost/$TS/endpoints.pre
kubectl -n risingwave get events --sort-by=.lastTimestamp | tail -50 \
                                             > ~/wip/rw-prepost/$TS/events.pre

# Connectivity probe via Tim's documented SQL endpoint.
# (Tim publishes the actual host/port/credentials; the Cloud Platform team
#  does not embed those here. Use his runbook for the current endpoint.)
psql "$RW_PROD_URL" -c "SELECT 1;" > ~/wip/rw-prepost/$TS/sql.pre 2>&1
```

If any pod is not `Running` and `Ready`, or `SELECT 1` fails, **stop**. Do not proceed with the cluster-wide change until baseline is clean or Tim has acknowledged the pre-existing state.

### Post-check (diff and validate)

```bash
# Same captures, post-change.
kubectl -n risingwave get pods -o wide       > ~/wip/rw-prepost/$TS/pods.post
kubectl -n risingwave get svc -o wide        > ~/wip/rw-prepost/$TS/svc.post
kubectl -n risingwave get pvc                > ~/wip/rw-prepost/$TS/pvc.post
kubectl -n risingwave get endpoints          > ~/wip/rw-prepost/$TS/endpoints.post
kubectl -n risingwave get events --sort-by=.lastTimestamp | tail -50 \
                                             > ~/wip/rw-prepost/$TS/events.post

psql "$RW_PROD_URL" -c "SELECT 1;" > ~/wip/rw-prepost/$TS/sql.post 2>&1

# Diff.
diff ~/wip/rw-prepost/$TS/pods.pre  ~/wip/rw-prepost/$TS/pods.post
diff ~/wip/rw-prepost/$TS/svc.pre   ~/wip/rw-prepost/$TS/svc.post
diff ~/wip/rw-prepost/$TS/pvc.pre   ~/wip/rw-prepost/$TS/pvc.post
```

**Acceptance criteria:**

- Pod count and Ready status unchanged.
- Restart counts unchanged.
- PVC bindings unchanged (no `Lost`, no rebind).
- Service / endpoint set unchanged.
- `SELECT 1;` returns successfully.

Any drift — even a single pod restart — triggers investigation and a note to Tim **before** the cluster-wide change is declared done.

---

## Safety rule: protect-rw-onprem-workload

This is the binding rule under which the Cloud Platform team operates with respect to this repo:

> **Tim's `risingwave` namespace is production. We do not change it, we do not push to this repo, and we do not make invasive cluster-wide changes without (a) running the pre/post check pattern above and (b) coordinating with Tim ahead of any change that has non-trivial blast radius.**

Non-negotiable elements:

1. No direct manifest changes by Cloud Platform into the `risingwave` namespace.
2. No PR to this repo from Cloud Platform without Tim's review and ack.
3. Every cluster-wide Cloud Platform PR that **could** affect the `risingwave` namespace must include the pre/post checks in its PR description.
4. Invasive cluster-wide changes (Rook-Ceph, Cilium, Talos, Istio gateway) require an explicit ping to Tim **before** the change lands.
5. If a change unexpectedly disturbs the namespace, the Cloud Platform team owns the recovery and the post-mortem.

---

## Marathon non-touch confirmation (2026-06-23)

On 2026-06-23 the Cloud Platform team shipped 16+ PRs end-to-end across other repositories (cluster underlay, observability, Velero, etcd-backup, rw-2 validation instance, IRSA). **None of those PRs targeted this repo, and none modified the `risingwave` namespace.**

The pre/post check pattern was applied at session boundaries. Throughout the marathon:

- `risingwave` namespace pods remained `Running`.
- Restart counts on the RW pods remained at their pre-marathon values.
- PVC bindings remained intact.
- The connectivity probe continued to succeed across sessions.

Full pre/post records and the session arc are captured in the Cloud Platform team's `session_state_jun23` notes. This bullet exists in this README so that anyone reading the repo history later can confirm the marathon left this namespace undisturbed.

---

## Cluster-wide changes that CAN affect this namespace

The following classes of change carry RW blast radius and **must** be coordinated with Tim and gated by the pre/post pattern:

- **Rook-Ceph** upgrades, CRD changes, OSD topology shifts, mgr restarts — RW pods consume `ceph-block` / `ceph-filesystem` storage and a rebind event is observable.
- **Istio** MeshConfig changes, gateway redeploys, VirtualService restructuring, mTLS mode flips — Tim's ingress and any in-mesh peers ride this.
- **Cilium** upgrades, CNI restarts, NetworkPolicy or CiliumNetworkPolicy churn, ambient HBONE flips — RW inter-pod traffic depends on this.
- **Talos OS** upgrades, kubelet restarts, node reboots — especially on workers `.26`, `.28`, `.180`.
- **Worker node maintenance** affecting the three RW-pod-bearing workers (drain, cordon, hardware swap, RAM expansion).
- **Cluster-wide PSA / admission controller** changes — Tim's manifests need to remain admissible.
- **External-DNS, cert-manager, or gateway-API resource churn** that affects Tim's DNS records or TLS certs.
- **Flux** controller upgrades or source reconfiguration that affects how this repo is pulled.

If a planned Cloud Platform change touches any of the above, the PR description must include the pre/post diff and a note that Tim was informed.

---

## Documentation conventions

| Layer | Documented by | Documented where |
| --- | --- | --- |
| RisingWave application internals (chart values, sealed secrets, schemas, SQL pipelines, operator config) | Tim Preble | This repo |
| Cluster underlay troubleshooting (Talos, Cilium, Rook-Ceph, Istio, Flux, ESO) | Cloud Platform team | `variant-inc/iaac-talos` under `deploy/docs/troubleshooting/` |
| Cross-cluster patterns (ESO bridge, mirror-release, platform-app-expose) | Cloud Platform team | `variant-inc/iaac-talos-flux-platform` and adjacent platform repos |
| RW-2 validation patterns | Cloud Platform team | `variant-inc/iaac-risingwave-2` |

When in doubt: application-shaped questions go to Tim; cluster-shaped questions go to Cloud Platform.

---

## Phase status

- **Phase 1** — complete 2026-04-30. RisingWave on-prem operational in the `risingwave` namespace, Flux reconciliation green, baseline ingress and storage proven.
- **Phase 2 and beyond** — Tim's roadmap. The Cloud Platform team supports underlay requests that Phase 2 surfaces, but the phase definition and acceptance criteria are Tim's to set.

---

## Related repos

- **`variant-inc/iaac-risingwave-2`** — Cloud Platform team-owned RisingWave validation instance in the `risingwave-2` namespace on the same cluster. Used to prove patterns and absorb burn-in so this repo's instance stays stable.
- **`variant-inc/risingwave-pipeline`** — fork of Tim's PoC repo `usxpressinc/risingwave-poc`. Pipeline and PoC artifacts.
- **`variant-inc/iaac-talos`** — cluster foundation. Talos config, terraform, machine config, recovery procedures. Cluster-wide troubleshooting docs live under `deploy/docs/troubleshooting/`.
- **`variant-inc/iaac-talos-flux-cluster`** — Flux cluster scaffold (`clusters/bm-dev/`).
- **`variant-inc/iaac-talos-flux-platform`** — Flux platform layer (`infrastructure/<name>/` on the `op-dev` branch).

---

## Tickets

Any Jira ticket that touches the `risingwave` namespace is **co-owned with Tim** from the Cloud Platform side. The Cloud Platform team will not move such a ticket to a terminal state without Tim's acknowledgement that the namespace is undisturbed.

For context on what the Cloud Platform team executed on 2026-06-23 (none of which touched this repo or namespace), see umbrella ticket **INFRA-1544**. That ticket and the session notes record the pre/post evidence that this namespace remained stable through the marathon.

---

*This README is a Cloud Platform read-only acknowledgement. The RisingWave production instance, its configuration, its data, and its operational lifecycle are Tim Preble's.*
