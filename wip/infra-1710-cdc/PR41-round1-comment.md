Round 1 — `c6cec3d`. Reviewed from the PR and from what the clusters were measured to be
on 2026-10-08. I could not reach a cluster while writing this, so every item below says what
would settle it.

Thanks for chasing the actual values rather than guessing — `wal_level=replica`,
`max_replication_slots=10`, `max_wal_senders=16` is exactly the right table to open with.

**Cleared**

- The two red checks are **not** about this change. `dpl` has failed 7/7 since 2026-08-12
  with zero successes ever, and `Manifest Lint / Terraform Validate` 5/5 since 2026-09-15,
  including PRs that merged (#38). Don't spend time on them. They do need their own tickets —
  a check that has never passed can't tell a real break from the floor.
- `max_replication_slots` and `max_wal_senders` are already sufficient. Agreed, no change
  needed.

**Still open**

**1. (BLOCKER) Which PostgreSQL did Tim mean?**

`pg-postgresql.risingwave.svc.cluster.local` is **RisingWave's own meta store** — the Bitnami
chart we deploy alongside it to hold catalog and cluster metadata. It holds no business data.

Tim asked whether CDC is enabled "on the PostgreSQL servers" because he wants RisingWave to
**ingest** change data. Logical replication on RisingWave's meta store doesn't give him that;
CDC sources are the upstream databases he's reading from, which I understand to be SQL Server
(`usxsqlrisingwave*`), not this PG.

If that's right, this change buys nothing and costs a meta-store restart on three clusters.
**Before anything else: can you confirm with Tim which database he needs CDC from?** Happy to
be wrong — if he genuinely wants to CDC out of the meta store, say so and the rest of this
review stands on its own.

**2. (BLOCKER) The test plan can't happen from this PR.**

The test plan reads dev → verify → QA → verify → prod. **This repo has no promotion gate.**
Every cluster's Flux `GitRepository` tracks `branch: main` at a 5-minute interval, so a single
merge to `main` reaches dev, QA **and prod** within minutes. There's no point between them to
verify anything.

Please split into three PRs, one per `manifests/op-usxpress-<env>/` directory, merged in order
with `SHOW wal_level;` confirmed and RisingWave confirmed reconnected between each. That's the
shape the console-hostname change used today and it worked cleanly.

**3. (BLOCKER) Dev and QA/prod use different mechanisms, so dev validates neither.**

Dev goes through `primary.extendedConfiguration` on the Bitnami Helm values; QA and prod get
`-c wal_level=logical` appended to StatefulSet container args. Two different paths to the same
setting, so a green dev tells us nothing about QA or prod.

Two things to confirm for the QA/prod half specifically:

- **Does the arg reach postgres?** The Bitnami image's entrypoint is a wrapper. Appending to
  `args` only works if the container command passes them through to `postgres`. Worth checking
  the live args and the image's entrypoint before relying on it.
- **Can it apply to the object that already exists?** A StatefulSet rejects changes to
  immutable fields, and a rejected dry-run fails the **whole** Kustomization, not just that
  object — `#36` froze this exact namespace's Kustomization for ~4 hours that way on
  2026-09-15, with everything else green.

```bash
for e in qa prod; do
  K=~/.kube/op-usxpress-$e.yaml
  echo "=== op-$e"
  kubectl --kubeconfig $K --context admin@op-usxpress-$e -n risingwave \
    get sts -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image' \
    --no-headers | grep -i postgres
  kubectl --kubeconfig $K --context admin@op-usxpress-$e -n risingwave \
    get sts pg-postgresql -o jsonpath='{.spec.template.spec.containers[0].command}{"\n"}{.spec.template.spec.containers[0].args}{"\n"}' 2>/dev/null
done
```

**4. (BLOCKER) This restarts RisingWave's meta store on prod.**

"RisingWave will temporarily lose meta store connectivity during the restart but reconnects
automatically" is the claim the whole change rests on, and it's currently an expectation. It
needs to be an observation from dev before prod goes anywhere near it: the meta pod's restart
count, its log on reconnect, and a query served afterwards.

Prod also has no Alertmanager delivery on-prem, so if it doesn't reconnect, nothing tells us.

**5. (advisory) QA/prod run PG as a raw StatefulSet while dev runs the Bitnami chart.**

That drift is worth its own ticket regardless of this change — it's why this PR needs two
different edits for one setting, and it means every future PG change costs double.

**Coordination ask — before merge**

- Tim's confirmation on item 1. `risingwave` is his namespace on op-dev and this restarts the
  database underneath it.
- Confirmation that the split in item 2 is acceptable, or an explanation of how sequencing
  works that I've missed.

Happy to pair on the split — the per-environment shape is already written up in
`wip/rw-dns/QA-PROD-ROLLOUT.md` from today's console work.
