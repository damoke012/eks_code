# Ticket draft — On-prem Talos + Kubernetes upgrade (dev → QA → prod)

**Status:** ready to raise. All inputs confirmed live 2026-08-03.
**Requested by:** Doke, 2026-08-03, in the QA-access thread. **Assignee:** Idris.
**Related:** INFRA-1594 is the *cloud EKS* equivalent — different fleet, different mechanism, keep separate.

---

## Summary

Upgrade Talos Linux and Kubernetes across the three on-prem Talos clusters, starting in dev.

## Why now

All three figures verified live on 2026-08-03:

| | on-prem dev | on-prem QA | cloud EKS |
|---|---|---|---|
| Kubernetes | **v1.32.0** | **v1.32.0** | v1.35 |
| Talos | **v1.11.1** | **v1.11.1** | n/a |
| Kernel | 6.12.45-talos | 6.12.45-talos | Bottlerocket |
| containerd | 2.1.4 | 2.1.4 | — |
| Nodes | 10 (3 CP + 7 flat workers) | 13 (3 CP + 10, pooled) | Karpenter |

Dev and QA are **identical** in version terms, which is good — one ladder works for both. They differ in
topology: dev has flat workers, QA has `application` / `platform` / `system` pools.

Two separate gaps:

- **Kubernetes: three minors behind the cloud fleet** (1.32 vs 1.35). 1.32 is at or near end of upstream
  patch support.
- **Talos: two minors behind** — the fleet runs v1.11.1 while v1.12 and v1.13 are both released (observed
  directly: Doke's talosctl client is v1.12.4, Idris's is v1.13.4, both against v1.11.1 nodes).

That is a materially stronger case than INFRA-1594, which covers clusters one minor behind where the value
is the repeatable process rather than the jump. Here the gap itself is the problem, and each additional
minor makes the eventual hop more expensive and more likely to break workloads.

## Scope

Two coupled but distinct upgrades per cluster:

1. **Talos OS** — `talosctl upgrade`, node by node, control planes first, etcd health verified between each.
2. **Kubernetes** — `talosctl upgrade-k8s`, which moves the static control-plane components.

Both are sequenced by a **support matrix**: each Talos release supports only a window of Kubernetes
versions. 1.32 → 1.35 will almost certainly require the Talos bump first, and may need more than one hop in
each dimension. **Determine the exact ladder before scheduling anything** — that determination is itself a
deliverable of this ticket.

Order: **dev → QA → prod**, with workload health verified at each stop before promoting.

## Known gates — each of these has already cost us time elsewhere

1. **~~talosconfig~~ — RESOLVED 2026-08-03, no longer blocking.** Neither the dev nor QA Terraform state
   exposes a `talosconfig` output (dev outputs are `control_plane_ips`, `flux_manifests_path`, `kubeconfig`,
   `worker_ips`) — but the client certificate material lives in the `talos_machine_secrets` resource inside
   the state, as `client_configuration.{ca_certificate, client_certificate, client_key}`, base64 PEM.
   Assemble a talosconfig from those three fields plus the control-plane IPs.
   - dev state: `s3://lazy-tf-state-65v583i6my68y6x9/iaac/talos/op-usxpress-dev.tfstate` (profile `usx-dev`,
     acct 700736442855). QA state: `s3://lazy-tf-state-425rbol87rmn6c7m/iaac/talos/op-usxpress-qa.tfstate`
     (profile `usx-qa`). Stream it (`aws s3 cp … -`), never write the state to disk.
   - Talos RBAC is enabled on the nodes, so **issue scoped configs rather than sharing the admin one**:
     `talosctl config new <out> --roles os:operator --crt-ttl 168h`. `os:operator` covers `upgrade` and
     `upgrade-k8s` while being denied `reset` and `get machineconfig` — verified live, not assumed.
   - Doke holds admin at `~/.talos/op-dev-admin.talosconfig`. Idris issued an `os:operator` config for dev,
     expiring 2026-08-11.

2. **iaac-talos deploys through Octopus only — and Octopus currently applies nothing outside production.**
   `TfApply` is scoped `(all) = false` with `true` only on `production`. Octopus runs plan, prints the diff,
   skips apply, and **reports Success having changed nothing**. Five QA deploys did exactly this in July. If
   the upgrade is driven by bumping `talos_version` / `kubernetes_version` in Terraform, assume nothing landed
   unless the log contains `Apply complete!`. Never `terraform apply` iaac-talos locally.

3. **Octopus reads `TF_VAR_*` (env.auto.tfvars), not `-var-file`.** A value placed in `envs/<env>.tfvars` is
   ignored by real deploys. Version variables must be set as project variables scoped to the environment, and
   an existing release pins a **variable snapshot** — adding a variable does not reach a release already cut.

4. **Deprecated API removal across 1.32 → 1.35.** Scan workloads before moving, not after. Applies to
   RisingWave (two namespaces on dev), Istio, Cilium, ESO, Flux, Argo CD, and the Wiz sensor.

5. **Component compatibility.** Cilium, Istio and the CSI/storage layer each have their own supported-version
   windows against Kubernetes. Confirm each before the hop, and expect at least one of them to need upgrading
   first.

6. **Control-plane sizing on dev.** Dev control planes are 3×8GB and have OOM-cascaded before (2026-06-17).
   Upgrades put transient extra load on them. QA control planes are spec'd 16GB; dev is the fragile one, and
   it is also the first cluster in the sequence.

## Proposed sequence

1. Obtain/confirm Talos API access (talosconfig) for all three clusters. **Blocking.**
2. Establish the version ladder from the Talos support matrix — exact intermediate versions, in order.
3. Inventory deprecated APIs and component compatibility per cluster.
4. Back up etcd and confirm the backup is restorable — a green `SecretSynced`/job status is not proof; QA
   etcd-backup has previously reported success while producing nothing usable.
5. Dev: Talos OS upgrade, node by node, CPs first. Verify etcd quorum and node `Ready` between each.
6. Dev: `upgrade-k8s`. Verify platform stack, then RisingWave (both namespaces) and the Wiz sensor.
7. Soak dev. Then QA — same steps, treating QA as prod-standard.
8. Prod last, scheduled, with a rollback position agreed in advance.

## Acceptance criteria

- All three clusters on the agreed target Talos and Kubernetes versions.
- Documented, repeatable procedure — including the talosconfig story and the Octopus apply gate — good enough
  that the next upgrade is not a research project.
- Platform stack green on each cluster after the hop: Cilium, Istio, ESO, Flux, Argo CD, Wiz sensor.
- RisingWave healthy on dev (and QA, if deployed there by then).
- etcd backup verified restorable before each cluster's upgrade.
- No unplanned workload restarts in prod outside the agreed window.

## Out of scope

- Cloud EKS upgrades — that is INFRA-1594.
- RDS PostgreSQL 14 → 16/17, which is due in the same window but is separate work.

## Dependencies outside this ticket

- **The RisingWave licence expired 2026-07-31.** Dev's RisingWave console is only still running because it
  hasn't restarted since 17 July — it caches the licence at startup. **Any node drain restarts it and it
  will not come back.** Renewal must land before the first dev node is touched, or the upgrade will appear
  to have broken RisingWave when it didn't. Owner: Tim / RW support.
- Prod cluster is `10.10.82.52`; the prod stand-up has open source gaps of its own.

## Open questions

- Is `TfApply=true` going to be made permanent on dev/QA, or does each upgrade deploy need it toggled? This
  needs deciding once, for all iaac-talos work, not per ticket.
- Target versions: latest stable Talos, or the newest that keeps us one minor behind on Kubernetes as the
  cloud fleet does? The cloud fleet's rule is deliberately "never on latest".
- Does the Talos hop go 1.11 → 1.12 → 1.13, or straight to 1.13? Depends on the supported-upgrade path in
  the Talos release notes — determine before scheduling.
