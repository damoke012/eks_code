# Dev wireup — runbook. Written 2026-10-08.

Goal: op-usxpress-dev delivers the RisingWave ETL the same way op-usxpress-qa does, so
dev↔QA is **parity**, not two mechanisms. Today dev has zero Argo Applications and an empty
`app-risingwave`.

**Mirror QA, do not pioneer Helm here.** The `usxpress-app` Helm chart is the agreed
direction and has **never been applied to a cluster**; QA's kustomize overlay is what
deployed successfully on 2026-10-07 22:52 UTC. Dev's job is to match the working environment.
Helm is a later change, made once, on QA2 first.

⚠️ **These files are drafts.** Build every PR from the branch and read `git diff
origin/<base>` in full. On 2026-08-20 a PR assembled by copying a `wip/` file over a branch
reverted an ApplicationSet's Git URL and took delivery down for 18 hours with every status
field green. The `rw-pipeline/` snapshot these were mirrored from predates 2026-09-11, so
treat every value as needing confirmation.

## Already done

| | |
|---|---|
| `apps` AppProject, `app-risingwave` ns, ApplicationSet CRD, ClusterSecretStore `default` | exist on dev |
| Deploy key `165827187` "op-usxpress-dev argocd", read-only | added 2026-10-08 |
| `op-usxpress-dev/platform/argocd` property `repo.risingwave-pipeline.sshPrivateKey` | written; `admin.password` intact |
| `op-usxpress-dev/risingwave/{root,postgres,kafka}` | exist |

## The order, and why

Three PRs in three repos. **Platform before cluster before pipeline** — an Argo Application
that appears before its repo credential fails with `authentication required`, which is
indistinguishable from having no credential at all.

### PR 1 — platform repo, branch `op-dev`

`variant-inc/iaac-talos-flux-platform`, base **`op-dev`**.

⚠️ Branch naming: bare `dev`, `qa` and `prod` branches exist beside `op-dev`/`op-qa`/`op-prod`,
so a branch called `dev/anything` is rejected at push as a *directory file conflict*. Use a
prefix that is not one of those three words.

1. `infrastructure/argocd/repo-ssh-externalsecret.yaml` — the file in `platform/argocd/` here.
2. One line adding it to `infrastructure/argocd/kustomization.yaml`. **That directory
   enumerates its resources**; a file not listed never applies, and nothing reports it.
3. `infrastructure/argocd-apps/applicationset-dev.yaml` + `kustomization.yaml` — the two in
   `platform/argocd-apps/` here.

Confirm before merge: `grep -c 'ssh://' infrastructure/argocd-apps/applicationset-dev.yaml`
is 1 and `grep -c 'https://git' ` is 0.

### PR 2 — cluster repo, branch `master`

`variant-inc/iaac-talos-flux-cluster`. Append the fragment in
`cluster/clusters/bm-dev/flux-system/infra.yaml.fragment` to the existing `infra.yaml`.

⚠️ **`dependsOn` differs from QA.** QA's `argocd-apps` depends on `argocd-config` +
`app-namespaces`. Dev has **no** `argocd-config` Kustomization — dev keeps Argo's config
inside `infrastructure/argocd/`. Copying QA's `dependsOn` produces a Kustomization that
waits forever on a dependency that does not exist, reported as `dependency ... is not
ready`, which reads as transient and is not.

After merge, confirm the revision **moved**:
`flux reconcile kustomization argocd-apps --with-source` and check the sha changed. There are
two GitRepositories on each cluster — `flux-system` (cluster repo, `master`) and `infra`
(platform repo, `op-dev`) — and reconciling the wrong one prints `✔ applied revision <old
sha>`.

### PR 3 — pipeline repo, branch `master`

`variant-inc/risingwave-pipeline`. The four files in `pipeline/deploy/overlays/dev/` plus
`promote-to-dev.yml`.

Build `promote-to-dev.yml` by **diffing against `promote-to-qa.yml` on the branch** — mine is
a derivation written without that file in hand. Four things differ: overlay path, ConfigMap,
branch name, PR title. Its `workflows:` trigger must match the build workflow's `name:`
exactly or it silently never runs.

## Two values that must be read before Brand can run

1. **`KAFKA_SCHEMA_REGISTRY_MESSAGE` is empty on purpose.** It must be the Avro subject's
   namespace + record for `dev_brand_management_cdc_brand_avro-value`. Tim's file has
   `abc123`; an older QA overlay had `message_name`. **Both pass every non-empty check in
   the path** and then fail inside RisingWave at decode time. A blank fails loudly.
2. **The image digest.** Set it to the digest **QA is already running**, not a fresh build —
   dev should not be the only consumer of an untested image on its first run.

Until (1) is read, `EXCLUDE_RE` holds `/Brand/`. Run 1 proves the delivery path only: image
pulled, Job created, secrets resolved, `apply.sh` ran. Removing `|/Brand/` afterwards is a
ConfigMap edit — no rebuild, no new digest.

## Verify, in this order. None of these is a status field.

1. **Secret key count.** The ExternalSecret asks for 12 keys. List them and count:
   `kubectl --context admin@op-usxpress-dev -n app-risingwave get secret
   etl-pipeline-credentials -o jsonpath='{range $k,$v := .data}{$k}{"\n"}{end}' | sort | nl`
   — **12**. ESO writes the keys it *can* resolve, so 11 looks populated and the pod dies at
   container creation with `RESTARTS 0`, invisible to restart alerts.
2. **The Job was created at all.** `kubectl -n app-risingwave get jobs`. A Sync hook is not in
   Argo's tracked resource set; between 09-29 and 10-07 a digest bump changed nothing Argo
   watched and the hook never fired, while the Application stayed `Synced`.
3. **The pod pulled the digest you promoted** — compare the pod's image to
   `image-digest.yaml`.
4. **`apply.sh` applied files, and which.** Read the Job log for `exclude` lines. An excluded
   file looks identical to a passing one from the sync status; `PIPELINE_DIR` and `EXCLUDE_RE`
   decide what runs.
5. **`readOnlyRootFilesystem: true` with no `emptyDir`.** This broke every `mktemp` and the
   QA Job could not apply a single file for weeks. The snapshot I mirrored still has no
   volume — confirm the branch has one before blaming anything else.

## Deliberately not doing tonight

- **Converging dev onto the `argocd-config/` layout.** Moving a live ExternalSecret between
  two Kustomizations that both prune can delete and recreate it, and one of them backs the
  Argo admin password. Separate change, separate day.
- **Making QA's promotion wait on dev.** That is the change that turns dev into a real gate,
  and it edits a workflow that currently works. Raise it as its own PR after dev is green.
  Until then dev simply gets the digest first and fails first.

## Proven

- Dev's Brand topic is `dev_brand_management_cdc_brand_avro` — confirmed twice, from Tim's
  `_dev.env` and from QA's own overlay, which reads that same dev topic deliberately.
- `KAFKA_GROUP_ID_PREFIX: dx__dev_risingwave_risingwave_dev` is the house convention, not a
  typo. QA's is `dx__qa_risingwave_risingwave_qa`.

## Tested and killed

- "Dev's Kafka topic is unknown and needs Tim." It was in our own QA overlay the whole time.
- "The doubled `risingwave_risingwave` in the group prefix is a defect." It is the
  convention, and the two environments must not share it.

## Traps

- The platform repo's bare `dev`/`qa`/`prod` branches reject a branch name of that form.
- `infrastructure/argocd/kustomization.yaml` enumerates: an unlisted file is silent.
- Dev's Secrets Manager properties are `KAFKA__*` (upper); QA's are `kafka__*` (lower). A
  wrong spelling resolves to nothing, with no error.
