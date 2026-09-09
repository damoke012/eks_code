Holding this one, not rejecting it — the image is fine and it carries the `apply.sh`
hardening from #21.

It cannot deploy yet. The QA Sync-hook Job `etl-pipeline-apply` has been in
`CreateContainerConfigError` for eight days:

    couldn't find key POSTGRES_ENTITY_USER in Secret app-risingwave/etl-pipeline-credentials

`op-usxpress-qa/risingwave/entity-postgres/{username,password}` do not exist in Secrets
Manager, so ESO writes three of the five mapped keys and the pod never starts. Because that
Job is a sync hook, the sync never completes and no digest change reaches the cluster — #20
merged and QA is still running the 19 August image.

Order once the Octopus run has created the records:
1. Confirm the Secret has **five** keys — list the keys, do not read the ExternalSecret's
   condition.
2. Delete the wedged Job so Argo recreates the hook.
3. Merge this, and confirm the pod's `imageID` actually changes.

Ping me when step 1 is done and I will merge it the same day.
