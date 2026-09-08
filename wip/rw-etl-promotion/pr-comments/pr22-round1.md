Round 1 on #22 — read the full diff, and re-checked the two #21 items against the code.

**Cleared ✅ — both of your pushbacks are right, and I've dropped those asks.**

- **Hashing the rendered SQL.** Confirmed in `build/apply.sh`: the `%TOKEN%` substitution
  runs into `rendered_content`, that is written to `$rendered`, and `sha256sum` reads
  `$rendered`. A changed variable value does produce a different hash. My ask was already
  satisfied.
- **Failing when `EXCLUDE_RE` matches everything.** Confirmed: `discovered_count > 0` with
  an empty selection exits 1 with a named error. Tested against a fixture tree — exits 1.
- **`EXCLUDE_RE` correctness.** I ran your regex against the actual file tree at
  `4873de43` rather than take the verification on trust. 24 `.sql`/`.rw` files discovered,
  22 excluded, and exactly `Brand/100-sources.rw` and `Brand/200-ingest.rw` selected.
  Your number and your net result are both exact.

`CUTOVER_SCOPE.md` is the right artifact — per-file with a reason each, not per-directory.
That is more than I asked for.

**Still open**

1. **(BLOCKER) The QA Job cannot start today, so this cutover cannot run.**
   `etl-pipeline-apply-djbp9` has been in `CreateContainerConfigError` for **6d20h,
   45,497 attempts**: `couldn't find key POSTGRES_ENTITY_USER in Secret
   app-risingwave/etl-pipeline-credentials`. The ExternalSecret requests five keys and the
   Secret holds three — `entity-postgres/{username,password}` do not exist in Secrets
   Manager. It reports `SecretSyncedError`, and ESO wrote the partial Secret anyway.
   Because that Job is a Sync hook, the sync never completes: **#20's digest was never
   applied either — QA is still on the 19 August image.** Merging this changes which
   failure you see, not whether it runs. The SM records go in first, through Octopus.

2. **(BLOCKER) This PR is seven files, not two.** The diff against `master` carries
   `build/apply.sh`, `PIPELINE_ARCHITECTURE.md`, `IMPLEMENTATION_CHECKLIST.md`,
   `README.md` and `deploy/overlays/prod/endpoints.yaml` as well as the two QA files. I
   assume it is branched off #21 rather than off `master`, which is reasonable — but as it
   stands, anyone merging #22 merges the whole `apply.sh` rewrite with it, and "overlay
   only, two files" is not what a reviewer sees. Either set its base to #21's branch, or
   say in the description that #21 lands first. The prod change is comment-only and
   harmless, but "prod is not touched" is not quite true.

3. **(BLOCKER) A wrong `PIPELINE_DIR` exits 0.** When the glob finds nothing at all,
   `apply.sh` prints "no .sql or .rw files under …" and exits 0, so the Job reports
   **success having applied nothing**. Tested: a one-character typo in the path gives
   exit 0 and a green Job. This is the PR that changes `PIPELINE_DIR`, and the failure it
   would produce is the silent kind — a cutover that looks done and did nothing. Please
   make an empty `PIPELINE_DIR` exit 1 too, or require an explicit
   `ALLOW_EMPTY_PIPELINE_DIR=true` for the smoke case.

4. **(question, possibly a blocker) Where do Brand's Kafka credentials come from?**
   `CUTOVER_SCOPE.md` says the Kafka secret must carry the bootstrap server, SASL
   credentials and all three schema-registry values. The live ExternalSecret maps five
   keys and **none of them is a Kafka key**. If `100-sources.rw` contains
   `%KAFKA_…%` tokens, `apply.sh`'s own validation will refuse to connect and name them —
   which is the control working, but it means the cutover fails on its first run. Settle
   it with:

       git show 4873de43:pipelines/Brand/100-sources.rw | grep -oE '%[A-Z][A-Z0-9_]*%' | sort -u

   and compare against the ExternalSecret's `spec.data` plus the endpoints ConfigMap.

5. **(advisory) `$rel` is interpolated straight into SQL.**
   `SELECT sha256 … WHERE path = '${rel}'` and the `INSERT` both build SQL by string
   substitution. Paths are repository-controlled so this is not urgent, but a filename
   containing an apostrophe breaks the tracking table rather than the file. `psql -v` with
   a bound parameter, or a quoting helper, closes it.

**Coordination ask — before merge:**

- These are Tim's Brand pipeline files, and this is their first real application to QA.
  **Tim is on vacation.** Is he content for this to land while he is away, or does it wait
  for him? That is a question for you and him, not a blocker I am raising on my own.
- Confirm the `entity-postgres` Octopus run is through and the Secret carries five keys —
  by listing the keys, not by reading the ExternalSecret's condition.

Once 1 and 3 are dealt with and 2 is either re-based or written down, I will approve this
same day. The scope document alone makes it reviewable in a way #21 never was.
