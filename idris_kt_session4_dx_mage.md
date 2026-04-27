# Session 4 — DX & mage-runner

**Duration:** 90 min
**Goal:** Idris can run mage-runner locally end-to-end, trace a deploy from `git push` through ECR, mage, Octopus, terraform-variant-apps, into the cluster, and explain the on-prem fork gates in mage's Go code.
**Format:** Live code walk + local mage-runner execution.

---

## Why this is Session 4

Session 3 covered what TF actually does. This session covers the **orchestrator** that drives those TF modules — and where the fork gates live in code. It's the "shared with cloud" piece Idris will touch when he extends mage for RisingWave.

---

## Prerequisites

- Cloned `mage-runner` (variant-inc/mage-runner), checked out `feature/onprem-support`.
- Cloned `terraform-variant-apps` on `feature/onprem-support`.
- Go 1.22+ installed locally.
- Azure CLI installed, logged into USX Applications Dev subscription.
- AWS CLI configured with `playground` profile.

---

## Agenda (90 min)

| Time | Topic |
|------|-------|
| 0–5 | Recap |
| 5–10 | What is DX, what is mage-runner — the boundary |
| 10–25 | mage-runner repo layout + Go module structure |
| 25–45 | Pipeline stages: replicator → auth → apps/api |
| 45–60 | The on-prem fork gates in mage code |
| 60–75 | spec.yaml schema + how mage reads it |
| 75–85 | Hands-on: run mage locally against op-usxpress-dev |
| 85–90 | Q&A |

---

## Section 1 — DX vs mage-runner (5 min)

The "DX" name is overloaded. Clarify:

- **DX as a system** = the whole deployment platform: mage + Octopus library variable sets + DX-Apply scripts + GHA workflows.
- **DX-Apply** = a specific Octopus deployment process step that runs inline PowerShell. The patched on-prem version (Session 2) reads SSM and strips spec.yaml.
- **DX__Common, DX__EKSCluster, etc.** = library variable sets. Just naming convention.
- **DX repo** = there isn't really a single "DX repo". The DX-Apply script lives inside Octopus library variable sets (managed by `iaac-octopus-config` for cloud, `iaac-octopus-overrides` for on-prem).

**mage-runner** is the actual binary. It's the thing that:
1. Reads spec.yaml.
2. Validates against JSON schema.
3. Decides which terraform-variant-apps modules to run.
4. Runs them via terraform-exec (Go SDK, not shell).
5. Composes Helm chart values from TF outputs.
6. Passes results to Octopus.

So when we say "DX deploys app X", we mean the whole pipeline. When we say "mage-runner deploys app X", we mean the binary execution.

---

## Section 2 — mage-runner repo layout (15 min)

Open the repo in editor. Walk top-down.

```
mage-runner/
├── cmd/mage/magefiles/         # Mage tasks — entry points
│   ├── terraform.go            # TfDeploy namespace: Apply, Destroy, Infrastructure, Apps, ScriptRun
│   ├── common.go               # Common: Prepare, ParseSpec, ValidateSpec
│   ├── octopus.go              # CreateOctopusRelease, project/channel setup
│   └── github.go               # GHA integration
├── internal/                   # Core implementation
│   ├── context/
│   │   ├── context.go          # DXContext, DXSpec types
│   │   └── env.go              # Config struct + env tag mapping
│   ├── terraform/              # Module orchestrators
│   │   ├── terraform_functions.go  # ⭐ TfRun pipeline (the heart)
│   │   ├── common.go           # shouldRunTerraform, S3 state mgmt
│   │   ├── namespace.go        # K8s namespace + labels (FORK GATE HERE)
│   │   ├── auth.go             # auth module orchestrator
│   │   ├── replicator.go       # ConfigMap creation
│   │   ├── apps.go             # apps module orchestrator
│   │   ├── apps_functions.go   # Helm value composition
│   │   ├── buckets.go, kafka.go, postgres.go, dynamodb.go, mongodb_*.go, role.go
│   ├── kube/
│   │   ├── namespace.go        # K8s namespace label setup (ALSO FORK GATE)
│   │   ├── apps.go             # Pod cleanup, helm release mgmt
│   │   └── common.go           # Kubeconfig loading
│   ├── shared/
│   │   ├── spec.go             # YAML parsing + env override merge
│   │   ├── schema_validation.go
│   │   └── functions.go        # Bash exec helpers
│   └── octopus/                # Octopus SDK wrappers
├── hack/                       # Local dev test config
│   ├── spec.yaml               # Example spec
│   └── dpl2-terraform.tfvars.json  # Cluster overrides (now op-usxpress-dev)
└── go.mod
```

**Build system:** [Mage](https://magefile.org/) — Go-based Make alternative. Targets defined as Go functions; invoked as `mage <target>`.

**Common targets:**
- `mage tfDeploy:apply` — full pipeline (infra + app)
- `mage tfDeploy:destroy` — tear down
- `mage tfDeploy:apps` — just app module
- `mage createOctopusRelease` — create a release in Octopus

---

## Section 3 — Pipeline stages (20 min)

Open `cmd/mage/magefiles/terraform.go`. Walk through `TfDeploy.Apply()`:

```go
func (TfDeploy) Apply() error {
    // 1. Validate environment + channel
    if dx.GlobalContext.Channel == "feature" &&
       !slices.Contains([]string{"dpl", "dpl2", "devops", "development", "qa", "dev"},
                        dx.GlobalContext.Environment) {
        return errors.New("feature channels can only deploy to dev/qa")
    }

    // 2. Run infrastructure modules
    if err := tfd.Infrastructure(ctx); err != nil { return err }

    // 3. Run apps module (exactly one app type)
    if err := tfd.Apps(ctx); err != nil { return err }

    // 4. Run post-deploy script + cleanup
    if err := tfd.ScriptRun(ctx); err != nil { return err }

    return nil
}
```

### Stage 1 — Infrastructure (Replicator + per-resource modules)

`TfDeploy.Infrastructure()` calls each TF module in sequence:

1. **Replicator** (`internal/terraform/replicator.go`)
   - Creates the `<app>-iaac-replicator` ConfigMap.
   - Records: name, image, version, repository, user. Labeled with environment, channel, space.
   - Flux uses this to detect drift.

2. **Namespace** (`internal/terraform/namespace.go` + `internal/kube/namespace.go`)
   - mage-runner creates the namespace via K8s SDK first (faster than TF).
   - Then TF namespace module reconciles labels.
   - **Fork gate here** (see Section 4).

3. **Buckets** (S3) — only if `infrastructure.buckets` in spec.
4. **Auth** (Azure AD) — only if `infrastructure.auth` in spec. **Stripped on-prem by DX-Apply.**
5. **Kafka** (Confluent) — only if `infrastructure.kafka`.
6. **Postgres** — only if `infrastructure.postgres`.
7. **DynamoDB** — only if `infrastructure.dynamodb`.
8. **MongoDB cluster + user** — only if `infrastructure.mongodb`. **User submodule short-circuited on-prem with v2 fork.**
9. **Role** — IAM role, always run if app type defined.

`shouldRunTerraform()` checks both spec content AND existing S3 state. For destroy, it checks state-only (so we can clean up resources even if the spec was changed).

### Stage 2 — Apps

`TfDeploy.Apps()` runs the apps module — exactly ONE of api, cron, handler, ui.

`internal/terraform/apps.go` and `apps_functions.go`:

```go
func (tf *TerraformImpl) TfApps(ctx context.Context) error {
    appType := determineAppType(tf.Context.Spec)  // api | cron | handler | ui
    chartValues := getChartValues(tf.Context, appType)
    return tf.TfRun(ctx, &optsTfRun{
        module:             appType,
        moduleRelativePath: "apps/" + appType,
        variables: map[string]interface{}{
            "tags":          tf.Context.Outputs.Tags,
            "labels":        tf.Context.Outputs.Labels,
            "spec":          tf.Context.Spec,
            "chart_values":  chartValues,
            "role_arn":      tf.Context.Outputs.RoleArn,
            "configmaps":    tf.Context.Outputs.ConfigMaps,
            "aws_secrets":   tf.Context.Outputs.AwsSecrets,
        },
    })
}
```

`getChartValues()` composes:
- App-specific values from `spec.api.*` or `spec.handler.*` etc.
- Tags + labels.
- IAM role ARN (from role module's TF output).
- ConfigMaps (from kafka, postgres, etc. modules' outputs).
- AWS secret references (from auth, kafka, mongo, etc.).
- Extra vars for destroy (dummy values to avoid TF complaints).

The merged YAML is fed to the helm_release resource in the apps/api TF module.

### Stage 3 — ScriptRun

`TfDeploy.ScriptRun()` runs `spec.octopus.postStep` if defined. Then writes outputs to `<TERRAFORM_APPS_PATH>/artifacts/outputs.yaml`. Then deletes /tmp files.

---

## Section 4 — On-prem fork gates in code (15 min)

Show real diffs. `cd mage-runner && git diff main..feature/onprem-support`.

### Gate A: env allow-list (cmd/mage/magefiles/terraform.go ~line 37)

```go
// BEFORE (cloud)
if dx.GlobalContext.Channel == "feature" &&
   !slices.Contains([]string{"dpl", "devops", "development", "qa"},
                    dx.GlobalContext.Environment) {
    os.Exit(0)
}

// AFTER (fork)
if dx.GlobalContext.Channel == "feature" &&
   !slices.Contains([]string{"dpl", "dpl2", "devops", "development", "qa", "dev"},
                    dx.GlobalContext.Environment) {
    os.Exit(0)
}
```

`dev` was added (and `dpl2` historically). Without this, on-prem feature deploys silently exit.

### Gate B: namespace labels (internal/kube/namespace.go ~lines 15-30)

```go
// BEFORE (cloud)
namespaceObject.Labels = map[string]string{
    "istio.io/dataplane-mode":     "ambient",
    "pod-security.kubernetes.io/enforce": "privileged",
    "cloudops.io/dxify":           "enabled",
}

// AFTER (fork)
useEksApi := os.Getenv("TF_VAR_use_eks_api") != "false"

namespaceObject.Labels = map[string]string{
    "cloudops.io/dxify": "enabled",
}
if useEksApi {
    namespaceObject.Labels["istio.io/dataplane-mode"] = "ambient"
    namespaceObject.Labels["pod-security.kubernetes.io/enforce"] = "privileged"
} else {
    namespaceObject.Labels["istio-injection"] = "disabled"
}
```

**Why:** the cloud labels assume the cluster has Istio ambient + EKS pod-security admission. On-prem Talos has its own PSA setup; we don't want mage to fight Flux which manages namespace labels declaratively. So when on-prem, just set `istio-injection: disabled` and let Flux own ambient labels via app-namespaces manifest.

This was the source of the bm-dev test bug back in March — Flux owned `istio-injection` label and mage tried to set it; conflict. Fork resolves by gating.

See [memory: magerunner_bm_dev_test.md].

### Gate C: nothing else in mage proper

The other on-prem differences live in **terraform-variant-apps fork** (Session 3) and **DX-Apply preflight** (Session 2). Mage just passes `TF_VAR_use_eks_api` through to TF.

---

## Section 5 — spec.yaml schema (10 min)

`internal/context/context.go` defines:

```go
type DXSpec struct {
    Name           string
    Octopus        OctopusStruct
    Tags           TagsStruct
    Git            GitStruct
    Infrastructure map[string]interface{}  // Free-form, validated against JSON schema

    // Exactly ONE of these must be set
    API     map[string]interface{}
    Cron    map[string]interface{}
    Handler map[string]interface{}
    UI      map[string]interface{}
}

type OctopusStruct struct {
    Space    string  // "DevOps"
    Group    string  // → K8s namespace
    PreStep  string  // bash before
    PostStep string  // bash after
}

type TagsStruct struct {
    Owner   string
    Team    string
    Purpose string
}

type GitStruct struct {
    Repository string
    User       string
    Version    string
    Image      string
    Language   string  // python|go|node — used for OTel auto-instrument
}
```

JSON schemas in `schemas/` validate the free-form maps (infrastructure.* and api/cron/handler/ui).

### Real spec example

`hack/spec.yaml`:

```yaml
name: mage-test
octopus:
  space: DevOps
  group: demo
  preStep: |
    echo "deploying..."
git:
  repository: demo-python-flask-variant-api
  user: cake-runner-test
  version: 1.0.1-f-cloud-1959-0001.631
  image: 064859874041.dkr.ecr.us-east-1.amazonaws.com/demo/python-flask-variant-api:0.1.0
  language: python
tags:
  owner: cake-runner
  team: cloudops
  purpose: test
api:
  service:
    targetPort: 5000
  secretVars:
    OCTOPUS_API_KEY: "test1"
```

---

## Section 6 — Environment variables (5 min)

`internal/context/env.go` has a `Config` struct with `env:"<NAME>"` tags. The `caarlos0/env` library populates from OS env.

| Variable | Purpose | Source |
|---|---|---|
| `S3_BUCKET` | TF state bucket | Octopus `DX__TFState` |
| `AWS_REGION` | AWS region | Octopus `DX__AWSAccounts` |
| `AWS_PROFILE` | Local AWS profile | Local dev only |
| `KUBECONFIG` | K8s client config (must be **absolute path**) | Local or DX-Apply preflight |
| `TERRAFORM_APPS_PATH` | Path to terraform-variant-apps fork | Octopus `DX__Common` |
| `HACK_FOLDER` | Local override tfvars | Local dev only |
| `TERRAFORM_DESTROY` | true/false | Octopus per-deploy |
| `OctopusEnvironmentName` | dev/qa/prod | Octopus runtime |
| `OctopusReleaseChannelName` | feature/main/feature-manual | Octopus runtime |
| `OctopusProjectName` | App project name | Octopus runtime |
| `LOG_LEVEL` | -10 (debug) / 0 (info) | Default -10 |
| `TF_VAR_use_eks_api` | **The on-prem gate** | Octopus `DX__Runner` (false on-prem) |
| `TF_VAR_cluster_name` | Cluster name | Octopus `DX__Runner` |
| `TF_VAR_*` (any) | Pass-through to TF | Anything |

**CRITICAL** for local: `set -a && source .env && set +a` — bash needs `-a` flag to export vars to subprocesses. Mage spawns subprocesses (terraform-exec, helm); they need the env. Variables set without `-a` won't propagate.

---

## Section 7 — How mage interacts with terraform (5 min)

Mage does NOT shell out to `terraform` CLI. It uses `hashicorp/terraform-exec` Go SDK.

In `internal/terraform/terraform_functions.go`, the `TfRun()` function:

1. **Construct module path**:
   ```go
   moduleFullPath := os.Getenv("TERRAFORM_APPS_PATH") + "/modules/" + opts.moduleRelativePath
   // e.g.: /home/doke/terraform-variant-apps/modules/common/replicator
   ```

2. **Generate auto.tfvars files** in the module directory:
   - `backend.auto.tfvars.json` — S3 backend config
   - `mage.auto.tfvars.json` — variables passed in (tags, spec, labels, etc.)
   - `hack.auto.tfvars.json` — local overrides if HACK_FOLDER is set

3. **Initialize tf-exec handle**:
   ```go
   tfe, err := tfexec.NewTerraform(moduleFullPath, "/usr/local/bin/terraform")
   ```

4. **Run init/plan/apply/output**:
   ```go
   tfe.Init(ctx, tfexec.BackendConfig("bucket="+s3Bucket), ...)
   tfe.Apply(ctx)
   outputs, _ := tfe.Output(ctx)
   ```

5. **Store outputs** in `dx.GlobalContext.Outputs[modulePath]` for later modules to consume.

6. **Persist `mage.auto.tfvars.json` to S3** for use during destroy. (Destroys need the same vars that were used for apply, but the spec.yaml may have changed.)

State location pattern:
- State: `s3://{S3_BUCKET}/{octopus.space}/{name}/{module_path}/terraform.tfstate`
- Vars cache: `s3://{S3_BUCKET}/{octopus.space}/{name}/{module_path}.tfvars.json`

For brands-api on-prem:
- State: `s3://op-usxpress-dev-tfstate/DevOps/brands-api/apps/api/terraform.tfstate`

---

## Section 8 — Hands-on: run mage locally (10 min)

Walk Idris through running mage locally against op-usxpress-dev. This is the same loop he'll use to develop RisingWave.

### Setup

```bash
# Clone
git clone git@github.com:variant-inc/mage-runner.git
cd mage-runner
git checkout feature/onprem-support
go build -o /usr/local/bin/mage ./cmd/mage

# Clone TF repo
git clone git@github.com:variant-inc/terraform-variant-apps.git ~/terraform-variant-apps
cd ~/terraform-variant-apps && git checkout feature/onprem-support

# Set up local kubeconfig
mkdir -p ~/.kube/configs
# Copy op-usxpress-dev kubeconfig from somewhere safe to ~/.kube/configs/op-usxpress-dev

# Configure AWS profile
aws configure --profile playground  # USX-Dev creds

# Login to Azure (for auth module — though stripped on-prem, mage still needs az for some modules)
az login --tenant <usx-dev-tenant-id>
az account set --subscription "USX Applications Dev"
```

### .env file

```bash
cat > .env <<EOF
KUBECONFIG=/home/doke/.kube/configs/op-usxpress-dev
TERRAFORM_APPS_PATH=/home/doke/terraform-variant-apps
HACK_FOLDER=/home/doke/mage-runner/hack
S3_BUCKET=op-usxpress-dev-tfstate
AWS_REGION=us-east-2
AWS_PROFILE=playground
OctopusEnvironmentName=dev
OctopusReleaseChannelName=feature
OctopusProjectName=mage-test
TF_VAR_use_eks_api=false
TF_VAR_cluster_name=op-usxpress-dev
LOG_LEVEL=-10
EOF
```

### Run

```bash
set -a && source .env && set +a
cd hack
mage tfDeploy:apply
```

Watch the output. Stages should run in sequence: replicator → namespace → role → apps/api.

### Hands-on for him

He won't actually run this in Session 4 — too much setup. Instead:
- **Read** the .env file and explain each variable.
- **Trace** what `mage tfDeploy:apply` does by stepping through `Apply()` in terraform.go.
- **Find** where `TF_VAR_use_eks_api` is read in mage code (it's in namespace.go) and where it's passed through to TF (the env propagates to terraform-exec subprocess).

Schedule a separate hands-on session in office hours to actually run it.

---

## Common pitfalls

- **Path with `~`**: KUBECONFIG=`~/.kube/...` does NOT work. Bash expands `~` only in interactive shells; mage subprocesses see the literal string. Always absolute paths.
- **Missing `-a`**: `source .env` without `set -a` doesn't export — subprocesses see empty env.
- **Stale TF plugin cache**: if `~/.terraform.d/plugin-cache` is corrupt, runs fail mysteriously. Delete and retry.
- **Octopus channel mismatch**: deploying main branch with channel=feature fails the env gate. Set `OctopusReleaseChannelName=main` for non-feature deploys.
- **Mage panic on missing var**: caarlos0/env will panic on missing required vars. Check env.go for required tags.
- **TF_VAR_use_eks_api as wrong type**: must be string `"false"` not bool. TF env vars are always strings.

---

## Homework before Session 5

1. Run mage locally end-to-end (with Dare in office hours).
2. Read the namespace.go fork gate. Understand exactly when each label is applied.
3. Trace one TF module call from mage Go code → terraform-exec → terraform-variant-apps module → AWS API.
4. Read [memory: magerunner_bm_dev_test.md] and [memory: dx_deployment_preparation.md].

---

## Reference cheat sheet

| Thing | Value |
|---|---|
| Repo | `variant-inc/mage-runner` |
| Fork branch | `feature/onprem-support` |
| Build | `go build -o /usr/local/bin/mage ./cmd/mage` |
| Main entry | `cmd/mage/magefiles/terraform.go` `TfDeploy.Apply()` |
| Pipeline core | `internal/terraform/terraform_functions.go` `TfRun()` |
| Fork gate (env) | `cmd/mage/magefiles/terraform.go` line ~37 (env allow list) |
| Fork gate (labels) | `internal/kube/namespace.go` lines ~15-30 |
| Spec types | `internal/context/context.go` |
| Env vars | `internal/context/env.go` |
| TF state | `s3://{S3_BUCKET}/{space}/{name}/{module}/terraform.tfstate` |
| Vars cache | `s3://{S3_BUCKET}/{space}/{name}/{module}.tfvars.json` |
