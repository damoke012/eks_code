Round 1 on 7fd05d7 — reviewed from the PR page, diff not yet read.

Good call on EXCLUDE_RE with /pipeline/pipelines as the stable root — that is the
option I argued for, and keeping the exclusions explicit in the overlay records the
decision where the next person will find it. The runtime validation before any database
connection is the right control in the right place; it is the one of my five blockers
that genuinely needed code rather than prose.

The follow-up list is honest and I would rather have it than a PR claiming more than it
does. It covers four of the five: the Terraform-owned secret records, the Flux/Argo
ownership boundary, the Brand Avro schema-registry mappings, and pipeline_applied backup.

Three things before I approve.

1. The production overlay carries a placeholder digest. Merged to master, that is the
   same shape as PLACEHOLDER_INJECT_REAL_LICENSE, which synced green on op-usxpress-prod
   yesterday, was rejected by the console, and crashlooped rw-bootstrap-service-accounts,
   a Job with nothing to do with licensing. It is inert only while nothing reconciles it,
   and creating the Argo Application that would reconcile it is item 3 on your own list.
   Either land it with a real digest, or split the prod overlay out of this PR and hold it
   until promotion supplies one.

2. You note kustomize rendering was not run, and six checks passed. Those are only both
   true if the checks do not render overlays. Two overlays changed here and rendering is
   the cheapest check there is. Please paste kustomize build for both, and tell me whether
   any of the six renders them — if none does, that is a CI gap and I will raise it
   separately rather than hold this PR for it.

3. Rollback. It is not in the diff and not on the follow-up list, and it is the only one
   of the five with no disposition. pipeline_applied records each file's SHA-256, skips
   unchanged files and refuses changed ones, so reverting the overlay to a previous digest
   gives the old container pointed at a RisingWave that already carries the new objects.
   Say plainly that the pipeline is forward-only, and give the break-glass path for objects
   a bad apply created — the CI guardrail blocks DROP, which is exactly the tension that
   needs a named approver.

One smaller thing: bash -n proves the file parses, not that the assertion fires. Please run
apply.sh once with a required variable unset and once with it set to the empty string, and
show a non-zero exit naming the variable in both cases. Empty is the one that gets missed,
and it is the case that actually occurs — when a remoteRef property is absent from the AWS
record, ESO still reports SecretSynced and the key is simply missing from the Secret, which
reaches the container as an empty variable rather than an unset one.

I will do a line-by-line pass on the diff next and come back with Round 2.
