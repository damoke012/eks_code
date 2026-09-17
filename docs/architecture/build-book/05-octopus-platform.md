# 05 — the Octopus platform: `iaac-octopus-server`, `iaac-octopus`, `iaac-octopus-onprem`

Read 2026-09-17 · `iaac-octopus-server` `55f5a45` · `iaac-octopus` `851c25c` · `iaac-octopus-onprem` `5318cb4`

Section 04 covered what Octopus *contains*. This is Octopus itself — the server, the workers that
execute every deployment, and the on-prem release mirror.

**The one fact to carry out of this section:** the on-prem Talos clusters are built by **three
tentacle pods running in AWS EKS in the `dpl` account**, which reach back to on-prem vSphere. The
cloud builds the on-prem estate, not the other way round.

```
iaac-flux-manifests (branch flux/dpl)   <-- rendered manifests are PUSHED here
        |  Flux reconciles
        v
Octopus SERVER  StatefulSet, namespace octopus, octopus.dpl.usxpress.io
        |  deploys
        v
Octopus WORKERS  3 tentacle pods, pool "devops", namespace octopus
        |  runs deploy.ps1 -> tofu apply
        v
vSphere on-prem  -->  op-usxpress-dev / -qa / -prod
```

---

## 5a. `iaac-octopus-server` — the server

### What it is

A StatefulSet of `octopusdeploy/octopusdeploy` with an MSSQL database, EFS-backed volumes, a
Gateway, a VirtualService, ExternalSecrets and its own Karpenter `nodepool`.

```yaml
# apps/values.yaml
octopus:
  image: { repository: octopusdeploy/octopusdeploy, tag: "2026.1" }
  secrets: { name: lazy/octopus-server, region: us-west-2 }
  storageClassName: efs-sc
  storageAccessMode: ReadWriteMany
  repositoryVolumeSize: 200Gi      # packages
  artifactVolumeSize:   10Gi       # terraform_outputs.yml lands here
  taskVolumeSize:       50Gi       # task logs
  host: octopus.dpl.usxpress.io
mssql:
  enabled: false
  persistence: { enabled: true, storageClass: gp3, size: 8Gi, resourcePolicy: keep }
```

Per-environment overrides sit beside it. There are at least two environments, `dpl` and `ops`:

```yaml
# dpl_config.yaml
environment: dpl
octopus:
  secrets: { name: lazy/octopus-server, region: us-east-1 }   # OVERRIDES us-west-2
  replicaCount: 1
  host:       octopus.dpl.usxpress.io
  publicHost: octopus.public.dpl.usxpress.io
mssql:
  enabled: true                                                # OVERRIDES false
bucket: lazy-tf-state-0k3nc997arlf7k1a
```

Layering is set by helmfile, last wins:

```yaml
environments:
  default:
    values:
      - values.yaml
      - ../{{ requiredEnv "CONFIG_YAML" }}    # dpl_config.yaml or ops_controller_config.yaml
      - tofu_outputs.yaml
releases:
  - name: octopusdeploy
    namespace: octopus
    chart: ./flux
```

### `run.sh` — the whole delivery path in four calls

```bash
MINOR_VERSION=$(yq '.octopus.image.tag' apps/values.yaml)   # "2026.1" -- a PREFIX, not a version
BUCKET=$(yq '.bucket' "$CONFIG_YAML")

resolve_version        # ask Docker Hub for every tag starting 2026.1, sort -V, take the last
yq -i ".octopus.image.tag = \"$SERVER_VERSION\"" apps/values.yaml
provision_infra        # tofu apply -> IRSA role -> tofu_outputs.yaml
deploy_app             # helmfile template --output-dir=../specs   (renders; does NOT install)
push_flux_manifests    # git push the rendered manifests into iaac-flux-manifests
```

**1. The version is resolved from Docker Hub at run time, not pinned in git.**

```bash
local url="https://hub.docker.com/v2/namespaces/${DOCKERHUB_REPO}/tags?page_size=100&name=${MINOR_VERSION}"
SERVER_VERSION=$(echo "$all_tag_names" | grep "^$MINOR_VERSION" | sort -V | tail -n 1)
```

Git says `2026.1`. What runs is whatever the newest matching tag was the last time the pipeline
ran. Two runs a week apart produce different servers from an unchanged commit, and the deploy
workflow has a weekly `cron`. The real version is only recoverable from the rendered manifests in
`iaac-flux-manifests`.

**2. Terraform here applies unconditionally.**

```bash
tofu apply -auto-approve -no-color
```

No `TfApply` gate, unlike `iaac-talos` and `iaac-octopus-config`. This is the one Octopus-adjacent
repo where a green run really did change infrastructure.

Its outputs become the IRSA annotation the chart needs:

```bash
cat <<EOF >../tofu_outputs.yaml
octopus:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: $(echo "$outputs" | jq -r '.iam_role_arn.value')
EOF
```

**3. Delivery is a git push into a Flux repo** — an eighth repo the book had not recorded:

```bash
flux_branch="flux/$(yq '.environment' "$CONFIG_YAML")"       # flux/dpl
git clone --single-branch --branch "$flux_branch" ... iaac-flux-manifests
rm -rf "${clone_dir:?}/${FLUX_MANIFESTS_DEST}"               # apps/misc/iaac-octopus-server
cp -r specs/octopusdeploy/flux/templates/* "${clone_dir}/${FLUX_MANIFESTS_DEST}/"
git commit -m "Update iaac-octopus-server manifests [skip ci]"   # GPG-signed
git push origin "$flux_branch"
```

The destination directory is **deleted and rewritten every run**, so anything hand-added under
`apps/misc/iaac-octopus-server` is destroyed on the next deploy. The `${clone_dir:?}` guard means
an unset variable aborts rather than running `rm -rf /` — deliberate, and worth copying.

---

## 5b. `iaac-octopus` — the workers

The tentacles are pods. Image built from a `Dockerfile`, chart deployed **through Octopus itself**
(`actions-octopus`, `space_name: DevOps`), which is why the server cannot live here.

```yaml
# deploy/values.yaml -- one of only two values files, and they agree
replicaCount: 3
envs:
  SPACES: "Default,DevOps"
  WORKER_POOL: devops
ingress:
  domain: dpl.usxpress.io
cache: { size: 5Gi, increase: 10Gi, threshold: 2Gi, limit: 75Gi }
resources:
  requests: { cpu: 0.1, memory: 2Gi }
  limits:   { memory: 2Gi }
```

Registration, from `scripts/configure-tentacle.sh`:

```bash
ingress="${HOSTNAME}.${DOMAIN}"          # the POD NAME is the worker name

IFS=',' read -ra spaces_array <<<"$SPACES"
for i in "${spaces_array[@]}"; do
        tentacle register-worker \
                --name "$ingress" --server "$SERVER_URL" --apiKey "$API_KEY" \
                --workerPool "$WORKER_POOL" --space "$i" -h "${ingress}" -f
done
```

- **`WORKER_POOL: devops` in `values.yaml` is the base, not what any environment gets.** The chart
  is deployed *through Octopus*, which substitutes `WORKER_POOL` and `DOMAIN` per environment, so
  the repo shows one value while six deployments exist — `dev`, `qa`, `stage`, `prod`, `dpl`, `ops`
  — each with its own pool and hostname, all Healthy (verified against the API 2026-09-17).
  **Reading this repo alone gives you the default and hides the fleet.** Same lesson as the
  RisingWave `postRenderer`: the file in git is not the configuration that runs.
- The worker's identity is its pod name, so a rescheduled pod registers as a new worker. `-f`
  forces re-registration.
- The certificate is cached at `/meta/tentacle-default.config` and `configureTentacle` **recurses**
  if it is broken — delete and retry once.
- `image.repository` and `image.tag` are **empty in git**, set at deploy time. As with the server,
  the running version is not knowable from the repo.

Chart values come from Terraform outputs, same pattern as the server:

```yaml
releases:
  - name: octopusworker
    namespace: octopus
    chart: ./charts
    values: [values.yaml, tofu_outputs.yaml]
```

---

## 5c. `iaac-octopus-onprem` — the release mirror

Seven files, no infrastructure:

```
.github/workflows/release-mirror.yaml
scripts/mirror-release.py
scripts/onprem-enrolled-apps.yaml
scripts/fork-side-templates/mage-runner-onprem-dispatch.yaml
scripts/fork-side-templates/terraform-variant-apps-onprem-dispatch.yaml
```

Zero matches for tentacle, worker pool or register. It mirrors releases and dispatches to forks;
it does **not** stand anything up. *Contents not yet read — listed here for completeness.*

---

## What is NOT automated

| # | Gap | Consequence |
|---|---|---|
| 1 | **The Octopus server version is not pinned.** `2026.1` is a prefix resolved against Docker Hub on every run, including a weekly cron. | The estate's deployment system upgrades itself on a schedule. An unchanged commit does not reproduce an unchanged server. |
| 2 | **The `devops` worker pool is unaccounted for.** | The pool every deployment runs on is created by nothing we have found. |
| 3 | **The MSSQL database is one in-cluster pod on an 8Gi gp3 volume.** | If it fills or fails, every deployment to every environment stops. `resourcePolicy: keep` protects the volume from deletion, not from filling. |
| 4 | `apps/charts/values.yaml` ships a literal `tag: changeme`. | Always overridden today. It is the same shape as `TBD-qa-vip`, which was also always overridden until it wasn't. |
| 5 | **Not read:** `ops_controller_config.yaml`, every chart template, `apps/terraform/*.tf`, `mirror-release.py`, `onprem-enrolled-apps.yaml`. | 5c especially is a file listing, not a description. |

---

## Proven

- Workers are three tentacle pods in namespace `octopus`, all registering into pool `devops` in
  spaces `Default` and `DevOps`. Both values files checked; no per-environment variants exist.
- The worker ingress domain is `dpl.usxpress.io`, i.e. the `dpl` AWS account (`786352483360`).
- The server is delivered by pushing rendered manifests into `iaac-flux-manifests`, branch
  `flux/<environment>`; Flux applies them.
- `run.sh` runs `tofu apply -auto-approve` — no gate.
- The server image tag in git is a prefix, rewritten in place by `yq -i` before rendering.

## Tested and killed

- *"`iaac-octopus-onprem` stands up the Octopus workers."* It does not — it has no worker,
  tentacle or pool reference at all.
- *"A new environment needs a worker pool."* Every worker is in `devops`; a new pool would be
  created empty (section 04, trap 4a).

## Traps

1. **A green `iaac-octopus-server` run really does apply** — the opposite of every other repo here.
2. **The server version moves on its own**, weekly, from Docker Hub.
3. **`apps/misc/iaac-octopus-server` in `iaac-flux-manifests` is deleted and rewritten every run.**
4. **`secrets.region` is `us-west-2` in the base values and `us-east-1` in `dpl_config.yaml`.** A new
   environment config that forgets the override points at the wrong region — and an ExternalSecret
   failure reads as a missing secret, not a wrong region ([[eso-secretsynced-not-content-check]]).
5. **A worker's name is its pod name**, so worker identity churns with rescheduling.
