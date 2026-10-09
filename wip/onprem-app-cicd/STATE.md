# On-prem ETL delivery — state as of 2026-10-09

## PR ledger

| Repo | PR | What | State |
|---|---|---|---|
| risingwave-pipeline | **#74** | `secret.yaml`: `jq -er` on 11 keys, temp-file `trap`, Teams webhook guard | ✅ merged |
| risingwave-pipeline | **#76** | the `risingwave-etl` Helm chart | ✅ merged |
| iaac-talos-flux-platform `op-dev` | **#173** | dev Application → `deploy/chart` + `values-dev.yaml` | ✅ merged, verified live |
| risingwave-pipeline | **#78** | `values-qa.yaml` (inert) | 🟡 open |
| ix-kafka-topics-users | **#303** | consumer-group grant | ✅ merged 2026-10-09 (jenni-ray + jshaw-usx); **dev deployed, QA NOT** |

## Dev — DONE AND PROVEN END TO END (2026-10-09 16:36Z)

A real change travelled the Helm path and the pipeline produces rows:

| layer | evidence |
|---|---|
| chart change -> Argo | synced to `503a1997`, 16:36:10 -> 16:36:24 |
| hook Job from the CHART's template | `Job/etl-pipeline-apply hookType=Sync hookPhase=Succeeded` |
| change reached the cluster | ExternalSecret `refreshInterval: 55m` |
| `apply.sh` | clean exit |
| **Kafka** | **`mv_brand` = 9 rows** |

The trigger was a deliberate one-line `refreshInterval` nudge in `values-dev.yaml`. It also
exposed that `deploy.yml`'s `paths-ignore` lists `deploy/overlays/**` but not
`deploy/chart/**`, so a values-only change rebuilds the image and cascades into a
`promote-to-qa` run. One-line fix, outstanding.

## Dev — earlier notes

`risingwave-etl` on op-dev sources `deploy/chart` with `values-dev.yaml`. Verified at every
layer: GitRepository `797a56c5` → Kustomization applied `797a56c5` → ApplicationSet carries
the helm block → Application `path=deploy/chart`, Synced/Healthy → **all four objects kept
their resourceVersion**. The render was identical, so Argo had nothing to apply.

**Not yet proven on dev:** the flip changed nothing, so the Helm path has never carried an
actual change. The first real test is a digest bump, where the tracked `etl-pipeline-image`
ConfigMap has to make Argo notice and fire the hook — the mechanism that was silently broken
2026-09-29 → 10-07.

**Also outstanding on dev:** `argocd` Kustomization is referenced by `argocd-apps` but never
declared in the cluster repo (`bm-dev` only; `op-usxpress-qa` and `op-usxpress-prod` both
declare it). A rebuild loses Argo CD. PR deliberately not raised yet — a wrong `path` there
prunes Argo CD's own 8 objects.

And the Application's **last sync operation is `Failed`** (21:47:53Z, the
`GroupAuthorizationFailed` applier run). A failed hook operation makes the next sync return
instantly replaying the old failure, so when the ACL lands this will likely need an explicit
retry rather than a fresh sync.

## QA — FLIPPED TO HELM 2026-10-09 17:50Z

| layer | evidence |
|---|---|
| GitRepository `infra` | `op-qa@sha1:625b1cc9` |
| Kustomization `argocd-apps` | applied `625b1cc9` |
| ApplicationSet | `path=deploy/chart`, `valueFile=values-qa.yaml`, helm block present |
| Application | `path=deploy/chart`, Synced/Healthy |
| all four objects | **resourceVersion unchanged** |

The gate was a render diff with the image digest **normalised out** — 81 fields each side,
identical. The digest had to be excluded because `promote-to-qa` moves it every 10 minutes
on a cron and auto-merges its own PR; a hand-pinned digest in `values-qa.yaml` would have
rolled QA back. risingwave-pipeline#82 makes that workflow write `values-qa.yaml` alongside
the overlay, so both sources carry the same digest and the flip could not regress the image.

**QA's end-to-end proof arrives on its own:** the next promotion writes a new digest into
`values-qa.yaml`, Argo sees tracked drift, and the hook Job fires.

**STILL MISSING ON QA: the Kafka consumer-group grant.** #303 merged and was deployed to
dev only, because the dev deploy gates the PR and nothing gated QA. Until someone deploys
`ix-kafka-topics-users` to the QA environment in Octopus, QA's `mv_brand` keeps failing with
`GroupAuthorizationFailed`.

## QA — earlier notes

`values-qa.yaml` renders byte-identical to `deploy/overlays/qa` (81 fields, sha
`3278343208d37c68`). Three lines differ from dev's: `environment`, `digest`, topic.

**Blocked on:** op-qa unreachable. Both `10.10.82.50` and `.51` time out at TCP while AWS SSO
resolves fine — VPN, not a cluster fault. QA's values are **overlay-derived**, a weaker basis
than dev's live-derived file, and that mattered once already (the hand-written dev file had
drifted from live in five places).

**Open question before the flip:** the overlay says `qa_brand_management_cdc_brand_avro`; a
2026-10-08 note records QA's live ConfigMap deliberately reading **dev's** topic. If live
disagrees, live wins and the topic change is a separate decision with Tim.

## Prod — not a conversion

Never wired. Six findings in `FINDINGS-2026-10-09-prod-etl-never-wired.md`: no `argocd-apps`
on `op-prod`, 3 objects not 4, a 64-zero placeholder digest, `PIPELINE_DIR=/pipeline/smoke`,
a different Postgres release (`postgres-postgresql` / `PG_DB=postgres`), and a dead `PG_USER`
in the ConfigMap. **`values-prod.yaml` deliberately not written** — it would have rendered
identical to that overlay and been wrong six ways.

Two decisions needed: is prod's Postgres a second install or drift, and does prod's first run
stay on the smoke payload.

## Messages drafted, not sent

- `MESSAGE-tim-dev-live-2026-10-08.md` — dev is live, how to deploy, how secrets work
- `MESSAGE-tim-kafka-pr-2026-10-09.md` — what closes #303 and why
- `MESSAGE-confluent-credential-rotation-2026-10-08.md` — needs a recipient list

## #303 — merged, dev deployed, QA outstanding

Jeff Shaw approved and **deployed to dev before the merge** — that deploy is a required
check on the PR, so the order is deploy-then-merge here, not merge-then-deploy
([[octopus-deploy-can-gate-the-pr]]). Merged 2026-10-09.

**QA still needs its own Octopus deploy.** Separate deployment, separate service account.
Unverified whether dev's ACL is actually live — op-dev has been unreachable (VPN) since the
merge, so nothing has been measured at the cluster.

## The one thing blocking data

#303. Until it is approved, merged **and** Octopus-deployed per environment, neither dev nor
QA produces Brand rows regardless of how they are delivered. `CREATE SOURCE` works,
`SELECT … LIMIT 1` works (batch scans use no consumer group), `CREATE MATERIALIZED VIEW`
fails.
