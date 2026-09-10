Round 3 — `b04a394` verified.

## Cleared ✅

- **Rebase is real.** `ae5176c` is an ancestor of `b04a394` — checked with
  `git merge-base --is-ancestor`, not by reading the commit list.
- **The digest revert is gone.** `deploy/overlays/qa/kustomization.yaml` carries
  `5108f32…`, byte-identical to master.
- **Empty `PIPELINE_DIR` now fails.** `exit 1` at `build/apply.sh:57-58`, and the
  excluded-everything case exits 1 at `:55`. Both asks from the change request are done.
- **The base cleanup is the right call, and the cluster agrees with your reasoning.**
  I checked op-usxpress-qa directly: `POSTGRES_SERVER` and `POSTGRES_ENTITY_DB` are
  **empty strings** in the live `etl-pipeline-endpoints`, and QA has exactly three
  services on 5432 — istio's passthrough, `ghostunnel-rw-postgres`, and `pg-postgresql`.
  There is no application database. Dropping the demand beats creating Secrets Manager
  records that would point at nothing.

## Still open

**1. (BLOCKER) The QA overlay no longer renders.**

`deploy/overlays/qa/kustomization.yaml` still patches `/spec/data/3` and `/spec/data/4`
— the two entries you just removed from the base:

    $ kubectl kustomize deploy/overlays/qa      # at b04a394
    error: replace operation does not apply: doc is missing path: /spec/data/3/remoteRef/key: missing value

Argo reports a sync error and applies nothing, so merging this leaves QA exactly as
wedged as it is now, through a different door. Fix is to delete both `op: replace`
blocks:

```yaml
      - op: replace
        path: /spec/data/3/remoteRef/key
        value: op-usxpress-qa/risingwave/entity-postgres
      - op: replace
        path: /spec/data/4/remoteRef/key
        value: op-usxpress-qa/risingwave/entity-postgres
```

`deploy/overlays/prod/kustomization.yaml` carries the identical pair at lines 28 and 31
and will fail the same way. The base change is what broke it, so it belongs in this PR.

Worth noting for the future: index-based JSON patches against a list that another file
owns will break silently every time that list changes length. Targeting by `secretKey`
value rather than position would make this class of failure impossible.

**2. (BLOCKER) `Brand/100-sources.rw` needs three tokens QA cannot supply.**

    %KAFKA_TOPIC_BRAND%
    %KAFKA_STARTUP_MODE%
    %KAFKA_SCHEMA_REGISTRY_MESSAGE%

This branch's `qa/endpoints.yaml` defines none of them, and the ExternalSecret maps no
Kafka key. `apply.sh` will refuse the file and name them — your own validation working
— but the cutover fails on its first run. `200-ingest.rw` carries no tokens, so this is
the one file.

Note the Kafka credentials are not in QA Secrets Manager either, which is the same shape
as `entity-postgres`: worth settling where they come from before adding them to the
ExternalSecret, rather than discovering it on the next run.

**(advisory)** `RW_DB: dev` in the QA overlay. Is a RisingWave database named `dev`
intended on QA, or is that carried over from the dev overlay?

## Verification

Everything above is from the branch and the live cluster, not the displayed diff:
`kubectl kustomize deploy/overlays/qa` at `b04a394` for the render, `git merge-base
--is-ancestor` for the rebase, `kubectl -n app-risingwave get cm etl-pipeline-endpoints`
on op-usxpress-qa for the empty values. No credential value was read or printed.

Fix 1 and I will approve same day — 2 changes what happens on the first run, not
whether the PR is correct, so tell me if you would rather land the overlay and settle
Kafka separately.
