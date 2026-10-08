# Dev then QA on the `usxpress-app` chart — 2026-10-08

Supersedes `../RUNBOOK.md`, which was written against kustomize overlays. Helm was wired on
2026-10-07; the chart's own README still says *"not yet landed in a repo"* and is stale.

Order: **dev first, then QA.** Dev has no Argo Application at all, so dev is a greenfield
install and cannot break anything. QA is a **conversion of a working environment**, which is
a different and riskier job — it only starts once dev is green.

---

## Two defects in the Helm path, found before writing any values

### 1. ⛔ The chart reintroduced the September no-op

`templates/workload.yaml` renders a `Job` with `argocd.argoproj.io/hook: Sync`, which keeps
it **out of** the Application's tracked resource set. The image digest appears **only** in
the Job. So a digest-only promotion changes nothing Argo watches: `sync.status` stays
`Synced`, no sync operation runs, and the hook never fires.

That is exactly the fault that made every promotion from 2026-09-29 to 2026-10-07 a no-op —
merged, green, nothing deployed. The kustomize fix was `deploy/overlays/qa/image-digest.yaml`.
The chart had no equivalent.

**Fixed here** in `wip/onprem-app-chart/charts/usxpress-app/templates/configmap.yaml`: when
`workload.kind` is `Job`, the ConfigMap also emits `IMAGE_DIGEST`. The ConfigMap **is**
tracked, so a promotion produces real drift → a sync → the hook fires. Chart-side rather than
per-values, because a per-values convention is a thing to forget.

Also note the Job gets **no** `checksum/config` annotation (Deployment and StatefulSet do).
For a Job that is acceptable — the ConfigMap is tracked, so a config change creates drift on
its own. Only the digest-only case was broken.

### 2. The chart's own RisingWave example is not a working config

`examples/risingwave-pipeline-qa.yaml` pulls **one** secret, and pulls `RW_PASSWORD` from
`op-usxpress-qa/risingwave/postgres` — the **Postgres** password, not RisingWave's root
password. `apply.sh` consumes the secret wholesale with `envFrom` and needs **twelve** keys.
Deployed as written it would authenticate to RisingWave with the wrong credential and have no
Kafka credentials at all. Treat the example as a sketch; `values-dev.yaml` here is the real set.

Two smaller ones: `externalSecrets.secretStore` defaults to `cluster-secret-store` and our
ClusterSecretStore is named **`default`**; and the Job's `hook-delete-policy` is
`BeforeHookCreation` only, where the kustomize base also had `HookSucceeded` — without it
succeeded hook Jobs accumulate.

---

## Step 0 — settle three unknowns before writing anything else

I cannot reach the clusters or corp GitHub from this session. Three facts decide the shape of
both PRs, and guessing any of them produces a manifest that fails at render or, worse, applies
and is wrong.

Paste this on WSL. It is **read-only**. Every line is short, there is no `exit`, and a missing
tool reports NOT MEASURED rather than a finding.

```bash
( echo "=== 1. where did the chart land ==="
  for R in risingwave-pipeline iaac-talos-flux-platform iaac-talos-flux-cluster; do
    echo "--- variant-inc/$R"
    gh api "repos/variant-inc/$R/git/trees/HEAD?recursive=1" \
      --jq '.tree[].path | select(test("usxpress-app|Chart.yaml|values-(dev|qa).yaml"))' \
      2>/dev/null || echo "  NOT MEASURED - api call failed"
  done )
```

```bash
( echo "=== 2. what does QA's Application point at TODAY ==="
  C=admin@op-usxpress-qa
  kubectl --context $C -n argocd get applications.argoproj.io -o json \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
for a in d.get("items",[]):
    s=a["spec"]
    print(a["metadata"]["name"], "|", s.get("source",{}).get("path"),
          "|", "helm" if "helm" in s.get("source",{}) else "kustomize",
          "|", s.get("source",{}).get("repoURL"))' \
    2>/dev/null || echo "  NOT MEASURED - cluster unreachable" )
```

```bash
( echo "=== 3. QA live ConfigMap + secret KEY NAMES (no values) ==="
  C=admin@op-usxpress-qa
  kubectl --context $C -n app-risingwave get cm etl-pipeline-endpoints \
    -o jsonpath='{.data}' 2>/dev/null | python3 -m json.tool \
    || echo "  NOT MEASURED - configmap unreachable"
  echo "--- secret keys, names and LENGTHS only"
  kubectl --context $C -n app-risingwave get secret etl-pipeline-credentials -o json \
    2>/dev/null | python3 -c 'import json,sys,base64
d=json.load(sys.stdin)["data"]
for k in sorted(d): print(f"  {k:36} {len(base64.b64decode(d[k]))}")
print("  TOTAL KEYS:", len(d))' || echo "  NOT MEASURED - secret unreachable" )
```

**What a pass looks like.** (1) prints a chart path in exactly one repo. (2) prints
`risingwave-etl` with `helm` or `kustomize` — that is what says whether QA was already
converted yesterday or not. (3) prints **TOTAL KEYS: 12** and no length of `0`.

A length of `0` is a blocker on its own: an empty value reads as configured and fails far
downstream. QA had three empty `schema_registry_*` properties for weeks that way.

---

## Step 1 — dev, greenfield

Three PRs. **Platform, then cluster, then pipeline** — an Argo Application that appears before
its repo credential fails with `authentication required`, indistinguishable from having no
credential.

### PR 1 — `variant-inc/iaac-talos-flux-platform`, base **`op-dev`**

1. `infrastructure/argocd/repo-ssh-externalsecret.yaml` — from `../platform/argocd/`.
2. **One line** adding it to `infrastructure/argocd/kustomization.yaml`. That directory
   **enumerates** its resources; an unlisted file never applies and nothing reports it.
3. `infrastructure/argocd-apps/applicationset-dev.yaml` — the Helm-sourced one in **this**
   directory, not the kustomize one in `../platform/argocd-apps/` — plus its
   `kustomization.yaml`.

⚠️ Branch naming: bare `dev`, `qa` and `prod` branches exist beside `op-dev`/`op-qa`/`op-prod`,
so a branch named `dev/anything` is rejected at push as a *directory file conflict*. And pin
the base explicitly: `--base op-dev`, never the GitHub default.

### PR 2 — `variant-inc/iaac-talos-flux-cluster`, base `master`

Append the fragment from `../cluster/clusters/bm-dev/flux-system/infra.yaml.fragment` to the
existing `infra.yaml`. Read the existing file from the branch first.

⚠️ **`dependsOn` differs from QA.** QA's `argocd-apps` depends on `argocd-config` +
`app-namespaces`. Dev has **no** `argocd-config` Kustomization — dev keeps Argo's config inside
`infrastructure/argocd/`. Copying QA's gives a Kustomization waiting forever on a dependency
that does not exist, reported as `dependency ... is not ready`, which reads transient and is not.

### PR 3 — `variant-inc/risingwave-pipeline`, base `master`

`values-dev.yaml` from this directory, at whatever path step 0 says the chart expects. Set the
digest to **the one QA is already running** — dev must not be the only consumer of an untested
image. And confirm the IRSA role name; if the Job makes no AWS call of its own, set
`serviceAccount.create: false` and drop `roleArn` rather than annotating a role that does not
exist. The pod-identity webhook is `failurePolicy: Ignore`, so a wrong role yields a pod with
no AWS credentials and no error anywhere.

### Verify dev, in this order. None of these is a status field.

1. `kustomize`/`helm` render locally if present, else NOT MEASURED.
2. **Secret key count is 12.** List the keys; do not read the ExternalSecret's condition.
3. **A Job exists.** A Sync hook is not tracked, so `Synced` is not evidence one ran.
4. The pod's image digest equals the ConfigMap's `IMAGE_DIGEST`.
5. The Job log's `exclude` lines — `apply.sh` reports what it skipped, and an excluded file
   looks identical to a passing one from the sync status.
6. `/tmp` is writable. The chart sets `tmpVolume: true` by default; confirm the rendered pod
   actually has the emptyDir. Its absence broke every `mktemp` and QA applied nothing for weeks.

---

## Step 2 — QA, a conversion

**Only after dev is green.** QA currently works; the goal is to change the *tool* and nothing
else, so the test is behaviour-identity, not correctness in the abstract.

**Do not derive `values-qa.yaml` from `values-dev.yaml`.** I deleted a sed-derived copy for
this reason: a copied manifest carries every difference between the two environments, not just
the ones you meant. On 2026-08-20 a PR assembled that way reverted an ApplicationSet's Git URL
and took delivery down for 18 hours with every status field green.

Build it instead from step 0's output:

1. Take QA's **live** ConfigMap (step 0, part 3) and copy its keys into `config:` verbatim —
   including anything that looks wrong. Fix nothing during a tool migration.
2. Take QA's twelve secret key names and write the `externalSecrets.data` list against them,
   with QA's **lowercase** `kafka__*` spelling.
3. Render: `helm template risingwave-etl <chart> -f values-qa.yaml -n app-risingwave`.
4. **Diff the render against the live objects**, not against dev:
   `kubectl --context admin@op-usxpress-qa -n app-risingwave get cm,externalsecret,job -o yaml`.
   Every difference is either intended or a bug. There is no third category.
5. Only then switch QA's Application source. The digest stays **exactly** what QA runs now.

Anything QA's live ConfigMap carries that is wrong — a placeholder
`KAFKA_SCHEMA_REGISTRY_MESSAGE`, a stale topic — is a **separate PR after** the conversion.
One change at a time is what makes a failure attributable.

---

## Proven

- The chart renders a Job as an Argo Sync hook with the digest only in the Job, so digest-only
  promotions could not fire the hook. Fixed chart-side.
- The chart's RisingWave example pulls 1 of 12 secrets and takes `RW_PASSWORD` from the
  Postgres secret.
- Dev's Brand topic is `dev_brand_management_cdc_brand_avro`, confirmed from Tim's `_dev.env`
  and from QA's live overlay, which reads that same dev topic deliberately.

## Tested and killed

- "Dev mirrors QA's kustomize overlay." Helm was wired 2026-10-07; the overlay files in
  `../pipeline/` are superseded and kept only as the behaviour reference for step 2.
- A sed-derived `values-qa.yaml`. Deleted.

## Traps

- The chart's README says it has not landed. It has. A status line in a doc is not a
  measurement.
- `externalSecrets.secretStore` defaults to `cluster-secret-store`; ours is `default`.
- Dev's secret properties are `KAFKA__*`, QA's are `kafka__*`. A wrong spelling resolves to
  nothing, silently.

---

## 2026-10-08 — step 0 run. One PR landed, two facts found, two blocked.

### ✅ PR 1 is open: variant-inc/iaac-talos-flux-platform **#171** → `op-dev`

One line inserted above `namespace.yaml` in `infrastructure/argocd/kustomization.yaml`, plus
the new ExternalSecret. The guard chain held: `INSERTED`, a two-file diff, then the PR URL.
Note dev's `argocd/kustomization.yaml` carries a comment warning against a top-level
`namespace:` transformer — that trap once rewrote a Velero Schedule out of its namespace.

### ✅ Dev's kafka secret is measured, and `values-dev.yaml` matches it exactly

`op-usxpress-dev/risingwave/kafka`, **9 properties, zero empty**:

    KAFKA__api_key                      16
    KAFKA__api_secret                   64
    KAFKA__bootstrap_server             55
    KAFKA__resource_id                  10
    KAFKA__rest_endpoint                51
    KAFKA__schema_registry_api_key      16
    KAFKA__schema_registry_api_secret   64
    KAFKA__schema_registry_endpoint     48
    KAFKA__service_account              10

All nine names in `values-dev.yaml` are confirmed, uppercase `KAFKA__` confirmed, and the
48-char registry endpoint matches the 2026-09-11 reading. **There is no
`kafka__group_id_prefix` on dev** — QA has one in Secrets Manager, dev does not, so dev's
group prefix must come from the ConfigMap. `values-dev.yaml` already puts it there.

### ❌ The chart is NOT in the three repos I searched

Searching `risingwave-pipeline`, `iaac-talos-flux-platform` and `iaac-talos-flux-cluster` for
`usxpress-app|Chart.yaml|values-(dev|qa)` returned one unrelated hit,
`infrastructure/octopus-worker/chart/Chart.yaml`. So wherever Helm was wired on 2026-10-07, it
is not those three. Candidates to search next: `iaac-risingwave-cicd`, `iaac-risingwave-onprem`,
`usx-cicd-workflows`, `actions-collection`, and the `usxpressinc` org.

### ❌ Both clusters unreachable — and that was MY error, not an outage

I used `--context admin@op-usxpress-qa`. The on-prem clusters are in **separate kubeconfig
files**, not the default, and op-qa's context is **`op-usxpress-qa-sso`**:

| cluster | file | server |
|---|---|---|
| op-dev | `~/.kube/op-usxpress-dev-fresh.yaml` | `https://10.10.82.50:6443` |
| op-qa | `~/.kube/op-usxpress-qa-sso.yaml` (context `op-usxpress-qa-sso`) | `https://10.10.82.51:6443` |

QA also needs **two** SSO logins — `usx-qa` for the AWS API and `op-qa` for the cluster's
`aws-iam-authenticator` exec plugin. A green one says nothing about the other, and the symptom
of the wrong one is an expired-session trace that reads like an unreachable cluster.

**And a second defect of mine:** the blocks piped `kubectl` straight into `python3`, so when
kubectl failed python printed a JSONDecodeError traceback *before* the `NOT MEASURED` line. A
transport failure rendered as a stack trace is the thing the handover skill exists to prevent,
inside a block written to that skill. Capture to a file, test it is non-empty, then parse.

**Still unmeasured, therefore still unwritable:** QA's live ConfigMap, QA's running digest,
QA's secret key count, and whether QA's Application is already Helm. `values-qa.yaml` stays
unwritten until those are read — deriving it is the trap this runbook already warns about.

## 2026-10-08 — `usxpress-app` is NOT in the org. The house library is `variant-inc/helm-charts`.

A whole-org scan (control passed: `octopus-worker/chart/Chart.yaml` found) returned **no repo
containing `usxpress-app`**. The chart in `wip/onprem-app-chart/` never landed. Every
`values-dev.yaml` written against it is therefore written against a chart that does not exist
outside this repo.

**What does exist, and is the house standard:**

| repo | contents |
|---|---|
| `variant-inc/helm-charts` | `dx-api`, `dx-cron`, `dx-handler`, `dx-test`, `dx-ui`, `routes`, `extras`, `fluxcd-release`, and a shared `library` of named templates |
| `variant-inc/dx-schemas` | `values.schema.json` per chart — `dx-api`, `dx-cron`, `dx-handler`, `dx-test`, `dx-ui`, `extras`, `fluxcd-release`, `library`, `routes` |
| `variant-inc/lazy-helm-charts` | older `variant-api` / `variant-cron` / `variant-handler` / `variant-ui` family |

`dx-handler` and `dx-cron` already render Deployment/CronJob + ConfigMap + **ExternalSecret** +
ServiceAccount + HPA + PDB + ServiceMonitor, with a schema that fails the render on a bad
values file. That is the same object matrix `usxpress-app` was drafted to cover.

**So the question is not "where did our chart go" but "which existing chart does the ETL Job
use".** And standardising on `dx-*` has a second benefit: it is the family the cloud side
already deploys, so Tim's DX mental model and the on-prem flow converge instead of diverging.

⚠️ **My scan was defective twice.** The pattern `charts?/` matched any repo with a `charts/`
directory — a vendored Boost tree, a PHP charting library — so the signal drowned. And an empty
repository's 409 JSON body was printed as a HIT. A widened pattern is not a better search; it
is a different question. Narrow the selector, keep the control.

## Traps added

- `wip/onprem-app-chart/` reads like a landed artefact. It is a draft. Its README says
  "not yet landed in a repo" and that line is the only accurate status in it.

## 2026-10-08 — `dx-cron` read from the branch. It implies a different trigger model.

`variant-inc/helm-charts`, `charts/dx-cron`, version **2.1.10**, appVersion 1.5.0. Templates:
`cron.yaml`, `configmap.yaml`, `external-secret.yaml`, `secrets.yaml`, `serviceaccount.yaml`,
`_jobspec.yaml`, `_helpers.tpl`, `NOTES.txt`.

**Published to ECR OCI**, not a Helm repo: the chart's own `library` dependency is
`oci://064859874041.dkr.ecr.us-east-2.amazonaws.com/helm-charts` at `~2.1.0-0`, and the repo's
workflows are `ecr-release.yml` and `publish-schema.yml`. So consuming it on-prem needs the
cluster to authenticate to that ECR **for Helm**, which is a different credential path from the
`ecr-pull-secret` that `ecr-credentials-sync` writes for images.

### What the schema actually demands

    required: ['cronJob']
    cronJob  required: ['schedule']     # strict cron regex, 5 fields

So the chart renders a **CronJob** and will not render without a schedule. It cannot produce a
bare Job, and therefore cannot carry `argocd.argoproj.io/hook: Sync`. **That is not a defect in
the chart — it is a different trigger model**, and the choice is ours:

| | sync-hook Job (QA today) | scheduled CronJob (`dx-cron`) |
|---|---|---|
| applies | on every Argo sync, i.e. on deploy | on a clock |
| logs | Argo UI, where the RW team watch deploys | CronJob job history |
| alignment | on-prem only | same chart family as the cloud estate |
| `apply.sh` fit | fine | fine — it is idempotent, so a clock converges the DB |

### Two things that would still need fixing to use it on-prem

1. **`global.cluster_name` is an enum of cloud clusters only** — `devops-playground`,
   `ops-controller`, `usxpress-dev`, `qa-one`, `usxpress-stage`, `usxpress-prod`. No
   `op-usxpress-*`. The field ships null so it may be omittable, but it cannot be set
   correctly, and anything in the templates keyed on it renders empty. A real fix is a PR to
   `variant-inc/dx-schemas` adding the three on-prem names.
2. **`awsSecrets` is marked "User input not supported — see configVars or secretVars"**, so the
   `external-secret.yaml` template is driven by values DX's infrastructure injects. Whether
   `secretVars` reaches that template or the plain `secrets.yaml` decides if our twelve keys can
   come from `op-usxpress-<env>/risingwave/*` at all. **Unmeasured** — it needs
   `external-secret.yaml` and `secrets.yaml` read, not inferred from values.yaml.

`global.environment` (`dev|qa|prod`) and `fullEnvironment` (`development|qa|production`) are
both fine for on-prem.

### Useful defaults it already gets right

`readOnlyRootFilesystem: false` (so no `mktemp` trap), `restartPolicy: Never`,
`ttlSecondsAfterFinished: 86400`, `concurrencyPolicy: Replace`. And
`usxpressCACertBundle.enabled: true` mounts a `custom-ca-certs` secret — **confirm that secret
exists in `app-risingwave` on-prem**, or the pod will not start for a missing volume source.

## Decision pending

Dev ships on the kustomize overlay, which is proven on QA and needs nothing from another team's
repo. The `dx-cron` alignment is a separate piece of work with two prerequisites (the schema PR
and the ECR-OCI Helm credential) and one design question (sync-triggered vs scheduled), and it
belongs with whoever owns `helm-charts`.

## Correct in place

⛔ I recommended `dx-cron` from a directory listing before reading its schema, and called it
"the better call". The schema says it cannot render this workload as currently designed. Read
the artefact before recommending it — the same lesson as [[proxy-is-not-the-property]], and the
third time in this session.
