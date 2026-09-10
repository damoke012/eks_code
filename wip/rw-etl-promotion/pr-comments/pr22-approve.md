Approved at `9c63bc4`.

I pushed the fix to this branch rather than sending you back another round — it is the
two `op: replace` blocks for `/spec/data/3` and `/spec/data/4` deleted from the QA
overlay, and the identical pair from prod, since your base change broke both. Revert my
commit if you would rather do it yourself.

Verified on the rendered output, not the diff:

    $ kubectl kustomize deploy/overlays/qa        # 9c63bc4
    ExternalSecret entries: 3
       RW_PASSWORD    <- op-usxpress-qa/risingwave/root       ok
       PG_PASSWORD    <- op-usxpress-qa/risingwave/postgres   ok
       PG_USER        <- op-usxpress-qa/risingwave/postgres   ok
    Job env: no mandatory POSTGRES_ENTITY_* secret reference

`deploy/overlays/prod` renders clean too.

**What this PR now is:** the QA cutover, plus the removal of a requirement for a database
that does not exist. Your diagnosis of the wedge was right and the base change is the
correct fix — creating the Secrets Manager records would have produced a pod that starts
and then exits on the blank `POSTGRES_SERVER`.

## Before you merge, one thing that is not fixed

`Brand/100-sources.rw` needs three tokens QA supplies from nowhere:

    %KAFKA_TOPIC_BRAND%   %KAFKA_STARTUP_MODE%   %KAFKA_SCHEMA_REGISTRY_MESSAGE%

Neither `qa/endpoints.yaml` nor the ExternalSecret defines them, and there are no Kafka
credentials in QA Secrets Manager. `apply.sh` will refuse the file and name them.

That matters more than a failed run: **if the apply Job is a PreSync hook, a failing hook
means the sync never completes and the image digest still is not applied** — the same
end state as today, reached a different way. Worth checking which phase it carries before
you merge:

    kubectl -n app-risingwave get job etl-pipeline-apply \
      -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/hook}{"\n"}'

If it is PreSync or Sync, the Kafka values need to be in place for this cutover to
actually reach QA. Merging is still right — it clears the ESO error and lets the Secret
carry a complete set — but I would not call QA unblocked until those three tokens
resolve.

**(advisory, unchanged)** `RW_DB: dev` in the QA overlay — intended, or carried over from
dev?
