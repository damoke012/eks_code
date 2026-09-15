Round 2 — e0d9d9f verified. All four blockers and all four advisories cleared. **Approving.**

**Cleared ✅ — each checked against the branch or the live QA cluster, not the summary**

1. **Prod out of scope** — the PR now touches `manifests/op-usxpress-qa/risingwave-console.yaml` only.
2. **`ON_ERROR_STOP` + transaction** — present on all three `psql` invocations, and `BEGIN;` / `COMMIT;` wrap **both** INSERTs, not just the first.
3. **Guard covers both objects, schema-qualified** — `information_schema.tables` filtered on `table_schema='public'`, plus a separate `information_schema.schemata` check for `anclax`. The unqualified-name problem is gone.
4. **Prometheus endpoint verified live on QA:** `kubectl -n prometheus get svc prometheus-stack-kube-prom-prometheus` returns ports `9090,8080`. The old address named a `monitoring` namespace that does not exist on that cluster.
5. **Digest pin** — `postgres@sha256:7958605b…`, the mutable tag replaced rather than appended.
6. **Skip is now distinguishable from success** — the log prints the two counts, so "nothing to do" no longer reads the same as "done".
7. **resources + `seccompProfile: RuntimeDefault`** present.
8. **`Recreate` justification confirmed true** — this file really does carry an RWO volume: `kind: PersistentVolumeClaim` (line 90), `accessModes: ["ReadWriteOnce"]` (95), `claimName: risingwave-console-data` (459). With `replicas: 1` a RollingUpdate would deadlock on multi-attach. Verified rather than taken on trust, because a comment that states a wrong reason is worse than no comment — the next reader believes it.

**One advisory for a follow-up, not a blocker on this PR**

A **connection failure still reports as a benign skip.** The guard captures counts via command substitution:

```
HAS_TABLES=$(psql ... -tAc "...")
```

`ON_ERROR_STOP` makes `psql` exit non-zero, but the script has no `set -e` and does not test that exit status — so if Postgres is unreachable, or the credentials are wrong, `HAS_TABLES` is simply empty, the `if` matches, and the container logs *"schema not yet initialized … skipping"* and exits 0. A real outage then looks exactly like a first deploy, and the console starts unsynced with nothing in the logs to say otherwise.

Two lines fix it, whenever it is convenient:

```
set -eu
... then check the substitution succeeded before comparing, e.g. treat an EMPTY
result as an error and only "" vs "0" vs "1" as the three distinct states.
```

Worth doing because it is the same shape as the bug this PR already fixed — the difference between *"it did nothing because there was nothing to do"* and *"it did nothing because it could not tell"*.

**For the prod promotion PR**

Carry the same eight fixes across, and note that **a merge to `main` on this repo IS a production deploy** — op-usxpress-prod's `kustomization/risingwave-onprem` reconciles this repo from `main` and has done for 13 days. There is no release, no approval environment and no promotion gate between a merge here and prod, unlike the branch-per-env repos. Worth a reviewer on that one before it lands.
