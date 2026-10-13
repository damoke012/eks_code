---
name: a-version-declared-twice-will-drift
description: "RisingWave's console records the cluster version in its own database, written ONLY when the row is absent, so an engine upgrade leaves the UI reporting the old version for ever"
metadata:
  type: project
---

Upgrading RisingWave to v3.0.5 (2026-10-08..12) moved the engine and the operator and left
the **console** reporting **v2.8.2** to every user, in all three environments. Measured
2026-10-13 against `cluster_connection_info` in the `metadata` database on
`pg-postgresql.risingwave.svc.cluster.local`: **dev 8 org rows, QA 5, prod 1 — every one
v2.8.2.**

The mechanism, and why the obvious fix does nothing:

- the version is declared in `manifests/op-usxpress-<env>/risingwave-console.yaml`, inside
  the `risingwave-console-init` ConfigMap's `init.yaml`, as `version: v2.8.2`
- the console writes that into `cluster_connection_info` **only when the row is absent**
- `init-db` merely does `CREATE DATABASE metadata` if missing — it writes no cluster rows
- QA's `sync-orgs` copies the `org_id = 1` row to other orgs behind a `NOT EXISTS` guard, so
  it propagates rows and never updates one

So editing the ConfigMap merges, reconciles, reports Ready, and **changes nothing live**.

✅ Fixed on **dev** by iaac-risingwave-onprem#52 (merged 2026-10-13): an idempotent
`sync-cluster-version` init container that reads the version out of the same ConfigMap
(mounted at `/init-config`, the `init` volume, which is a plain configMap with no `items`)
and runs `UPDATE … WHERE version IS DISTINCT FROM`. Verified: pod replaced 15:55:25Z, Ready
15:55:55Z, all 8 rows `v3.0.5`. **QA and prod still stale.**

**The general rule:** when a version is declared in two places, one of them goes stale and
nothing reports it. Ask, on every upgrade: *what else records this version?* Here it was the
CR and the console's `init.yaml`. The fix is not to remember — it is to make the second place
read from the first.

**Proven:** the row contents before and after; that the console seeds only on absence; that
the `init` volume mounts as a directory.
**Tested and killed:** "the console keeps its own Postgres" — no. `postgres:17` in that file
is the `init-db` **init container**; the pod's running containers are only
`risingwave-console` and `dex`, and the database is the shared `pg-postgresql`.
**Traps:** a `kubectl apply --dry-run=server` on dev warns `PodSecurity "restricted:latest"`
for `fix-data-dir` (`runAsUser=0`) — **pre-existing**, warn not enforce, and it would block
admission the day that namespace moves to enforce. Related:
[[gitops-has-four-stale-layers]], [[config-can-outrun-the-image]],
[[rw-version-uniform-but-eos]], [[server-side-apply-keeps-dropped-fields]].
