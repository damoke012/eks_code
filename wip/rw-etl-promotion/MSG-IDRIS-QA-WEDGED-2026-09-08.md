> **SUPERSEDED 2026-09-11.** The wedge described below is resolved: QA was unblocked
> 2026-09-10 and Brand was built on QA 2026-09-11. Do not send this. Kept for the
> reasoning; current state is in STATE.md.

Idris — one more, and it is the important one.

**QA's apply Job has been failing for 6 days 20 hours. 45,497 attempts.**
`etl-pipeline-apply-djbp9`, `CreateContainerConfigError`:

    couldn't find key POSTGRES_ENTITY_USER in Secret app-risingwave/etl-pipeline-credentials

The ExternalSecret asks for five keys; the Secret has three. Missing are
`POSTGRES_ENTITY_USER` and `POSTGRES_ENTITY_PASSWORD`, both from
`op-usxpress-qa/risingwave/entity-postgres/*` — records that do not exist in Secrets
Manager. That is Blocker 1 from the architecture review. We both filed it as "deferred";
it has actually been blocking QA since 1 September.

Two consequences worth knowing:

1. **The promotion I merged did not land.** That Job is a sync hook, so while it never
   completes Argo cannot finish the sync. QA is still running the 19 August image
   `d616242…`, not `5108f32…`. The merge was real and changed nothing.
2. **ESO wrote a partial Secret** — three of five keys — so the Secret looks populated.
   The ExternalSecret does say `SecretSyncedError`, which is honest, but nobody was
   watching that condition and nothing alerted for a week.

Order to fix, and it matters:

1. Create `entity-postgres/username` and `/password` in SM through the Octopus Terraform
   run. Not a local apply.
2. Confirm the Secret has five keys — list the keys, do not trust the condition.
3. Then delete the wedged Job so Argo recreates the hook on the new digest. Before step 1
   it just wedges again.

One question: does that Terraform create the Postgres **role** as well as the SM record?
If the credential exists in SM but not in the database, the failure moves from
container-create to connect-time, which is a lot harder to spot.

Happy to do steps 2 and 3 once the records exist — tell me when the Octopus run is through.

— Dare
