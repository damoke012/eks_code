Round 1 — d8623b6 verified against live QA and prod.

**Cleared ✅**
- `sync-orgs` is an **initContainer** (line 128 `initContainers:`, 190 `sync-orgs`, 325 `containers:`), so there is no restart loop from a script that exits 0.
- Prod has both prerequisites the init container needs: `svc/pg-postgresql` and `secret/pg-credentials` in `risingwave`.
- QA has `svc/pg-postgresql` and `secret/pg-credentials` with `username` + `password` keys.

**Blockers**

1. **Merging this deploys to PRODUCTION, immediately and ungated.** op-usxpress-prod runs `kustomization/risingwave-onprem` against this repo's `main`, currently `Applied revision: main@sha1:c4b360…`, Ready, 13d. So a merge replaces prod's console Deployment with no release, no approval and no promotion step — and `strategy: Recreate` terminates the running pod before the new one starts. `reviewDecision` is empty, so nothing blocks it.
   **Ask:** is the prod file meant to change in this PR? If the intent is "fix QA first, promote after", split the prod manifest into a second PR and land it deliberately. If prod is meant to change now, say so in the description so whoever merges knows what they are doing.

2. **`psql` runs without `-v ON_ERROR_STOP=1`, so a failed sync exits 0.** The heredoc holds two INSERTs. If the first fails, psql runs the second and the init container still succeeds — the console then starts against a half-synced metadata DB and everything reports healthy. There is also no transaction wrapper, so a partial sync commits. Please add `-v ON_ERROR_STOP=1` and wrap the two statements in `BEGIN; … COMMIT;`.

3. **The guard does not cover what the SQL reads.** It tests for `cluster_connection_info`, then the query joins `anclax.orgs` — a schema only the console creates. If `cluster_connection_info` exists and `anclax.orgs` does not, the guard passes and the SQL fails. We have hit `anclax` ordering before: `rw-bootstrap-service-accounts` sits in permanent CrashLoopBackOff because it reconciles against `anclax.users`. The existence check is also unqualified — `information_schema.tables WHERE table_name='cluster_connection_info'` matches that table name in *any* schema. Please test both objects, schema-qualified.

4. **QA's Prometheus endpoint points at a namespace that does not exist, and this PR deletes the comment that said so.** The config keeps `http://prometheus-server.monitoring.svc.cluster.local:9090` while removing `# TODO: confirm platform Prometheus service address in QA`. Verified just now: `kubectl -n monitoring get svc` on op-usxpress-qa returns **`namespaces "monitoring" not found`**. On dev, `prometheus-server` lives in the `risingwave-2` namespace. So the address is wrong and the TODO was correct — please confirm the real QA address rather than dropping the reminder. Worth checking prod's value in the same pass, since the two files now differ here.

**Advisory**

5. `image: postgres:17` is an unpinned Docker Hub tag pulled at pod start, on a production pod. Pin by digest or mirror to ECR — this puts Docker Hub availability and rate limits on the console's startup path.

6. **The sync is one restart behind on a fresh environment.** If the console creates the schema on first start, the init container on that same deploy sees no tables, skips, and exits 0 — correct behaviour, but the sync does not actually run until the *next* pod start, and nothing says so. Worth an `echo` that distinguishes "skipped, schema absent" from "synced N rows", so a no-op is visible in the log rather than looking identical to success.

7. No `resources` requests/limits on the new container, and no `seccompProfile` in its securityContext while the others in this file set `capabilities.drop`.

8. `strategy: Recreate` is reasonable for a single console sharing one metadata DB, but it is a deliberate downtime window on every update. A one-line comment saying why would stop someone "fixing" it back to RollingUpdate later.

**Coordination ask — before merging, please confirm:**
- Whether prod is in scope for this PR (blocker 1). Prod reconciles from `main` today.
- What the QA symptom actually was, so we can confirm this fix addresses it rather than something adjacent.
