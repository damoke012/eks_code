## What

`dev` now resolves to the `risingwave` namespace and the `poc` role, the same as `qa` and
`prod`. `RW_NS` and `ROLE_KIND` leave the `case` statement entirely, which now sets only
`AWS_ACCOUNT_ID`.

## Why

The pipeline was reading `op-usxpress-dev/risingwave-2/*` with the
`gha-op-usxpress-dev-risingwave-pipeline-secrets` role, so on dev it was pointed at the
platform team's sandbox instead of the application's dev environment.

Confirmed on the cluster, 2026-09-15, over `rw_catalog` in both dev instances:

| namespace | sources | materialized views |
|---|---|---|
| `risingwave` | `brand_source_kafka` | `brand_mv_raw`, `brand_mv_state`, `brand_mv_flat` |
| `risingwave-2` | none | none |

`risingwave` is the application's dev environment and holds the only Brand objects on the
cluster. `risingwave-2` was stood up on 2026-05-27 as the platform team's own space so our
CI/CD work could not disturb Tim's; it has never held any of the application's objects.
Confirmed with Idris: "rw. rw-2 is ours." `risingwave-2` is being retired, so no environment
will name it.

## Why the variables leave the case statement

They no longer vary by environment, and yesterday's defect was precisely that they could.
Before #33 the role was hardcoded to `pipeline` while the namespace varied, so the pair fitted
dev alone, by coincidence; #33 made the role track the namespace. Making both constants closes
the class rather than the instance — there is no longer a place to set them per environment,
so they cannot drift apart again.

## Scope and safety

- No change to `qa` or `prod` behaviour: same account, same namespace, same role as before.
- Read-only against the cluster to produce the evidence above; nothing was applied.
- The dev IAM role `gha-op-usxpress-dev-risingwave-poc-secrets` already exists and already
  grants `secretsmanager:GetSecretValue` on `op-usxpress-dev/risingwave/*`.

## Not in this PR

`RISINGWAVE_HOST` and `RISINGWAVE_PORT` on the GitHub `dev` environment still resolve to
`risingwave-2`. `RW_NS` selects the Secrets Manager path and the OIDC role; it does not decide
where `psql` connects. Both are needed before a dev run is meaningful, and the second is a
settings change, not a code change.
