# 04 — `iaac-octopus-config`

**Repo:** `variant-inc/iaac-octopus-config` · read at `master` `9d155c8`, tag `v2.7.4`, 2026-09-17

It builds the **stage** Octopus deployments perform on: spaces, environments, worker pools,
lifecycles, script modules and the *names* of library variable sets. It is OpenTofu against the
`octopusdeploy` provider, driven entirely by seven YAML files.

**It does not manage projects, and it does not manage project variables.** That single fact
decides how a new environment gets stood up, so it is worth stating plainly before anything else:

```
$ grep -rn "TF_VAR_\|iaac-talos" deploy/config/
$                       # no output -- not one match in any config file
```

The 121 `TF_VAR_*` that actually build a Talos cluster are project-scoped on the `iaac-talos`
project. Nothing in this repo — or any repo — creates them.

---

## 1. What triggers it

| Path | Runs | Manages |
|---|---|---|
| `deploy/run_spaces.ps1` | the space and everything structural in it | environments, worker pools, lifecycles, script modules, library variable *sets* |
| `deploy/run_variables.ps1` | the *values* inside library variable sets | `deploy/config/vars.yaml` |

Both are invoked from `.github/workflows/deploy.yml`. **Not yet read** — see §7.

## 2. The file layout

```
deploy/
  config/                     <- the whole input surface: seven YAML files
    spaces.yaml               which spaces exist, and per-space prefixes
    environments.yaml         the environment list                    <- QA2 goes here
    worker_pools.yaml         the worker pool list                    <- and here
    lifecycles.yaml           promotion paths                         <- and here
    script_modules.yaml       which script modules to publish
    feeds.yaml                package feeds
    vars.yaml                 library variable set CONTENTS
    common.yaml
  run_spaces.ps1              renders config -> tofu plan/apply, once per space
  run_variables.ps1           the variable-value half
  spaces/
    main.tf                   the space itself
    config.gotmpl             -> config.hcl, the per-space S3 backend
    modules/common/
      common.tfvars.gotmpl    -> common.tfvars.yaml (rendered from config/)
      main.tf                 every resource this repo creates
  scripts/
    Bash/*, PowerShell/*      script module bodies; the DIRECTORY is the syntax
```

## 3. How config becomes Terraform

`run_spaces.ps1`, top to bottom. This is the whole mechanism:

```powershell
gomplate -c data=./full_config.yaml `
  -f spaces/modules/common/common.tfvars.gotmpl `
  -o spaces/modules/common/common.tfvars.yaml     # YAML in, one merged YAML out

$AllowedSpaces | ForEach-Object {
  $space = $_

  @{ space = $space } | ConvertTo-Json `
  | gomplate -c data=stdin: -f config.gotmpl -o config.hcl   # a backend PER SPACE

  Remove-Item .terraform -Recurse -Force -ErrorAction SilentlyContinue
  $env:TF_VAR_space_name = $space
  tofu init -backend-config="config.hcl" -input=false -no-color

  # ../scripts/import_spaces.ps1 $space        <- COMMENTED OUT in the repo

  tofu plan --out=tfplan -input=false -no-color
  if ($SpacesVariablesTfApply -eq "true") { tofu apply tfplan }
}
```

Four things in nine lines:

1. **One Terraform run per space, each with its own state.** `.terraform` is deleted between
   iterations because the backend changes underneath it.
2. **`$AllowedSpaces` comes from `spaces.yaml`.** Today: `Default` and `DevOps`. A resource added
   to `environments.yaml` is therefore created in **both**.
3. **The import step is commented out.** Existing Octopus objects are not adopted on each run;
   state is assumed to already hold them.
4. **`SpacesVariablesTfApply` gates the apply.** Default is a plan. See §6.

The module then reads the rendered YAML directly:

```hcl
locals {
  config = yamldecode(file("${path.module}/common.tfvars.yaml"))
}
```

## 4. What it creates — all five resources

### Environments — `environments.yaml`

```yaml
environments:
  - plan
  - development
  - qa
  - staging
  - production
```

```hcl
resource "octopusdeploy_environment" "environment" {
  for_each = {
    for i, e in local.config.environments : e => { name = e, index = i }
  }

  jira_extension_settings {
    environment_type = lookup(local.jira_environments, each.value.name,
                              local.jira_environments["default"])   # -> "unmapped"
  }

  name       = each.value.name
  sort_order = sum([each.value.index, 10])      # position = position in the LIST
}
```

**`sort_order` is derived from list position.** Inserting an entry renumbers every entry after
it, so the plan shows updates to environments nobody touched. **Append.**

**`jira_environments` has no `qa2` key**, so a new environment silently becomes `unmapped` unless
the map is extended too.

### Worker pools — `worker_pools.yaml`

```yaml
worker_pools:
  - usxpress-development
  - usxpress-qa
  - usxpress-staging
  - usxpress-production
```

Same `for_each`/`sort_order` shape. The pool is created here; the **workers that register into
it** are not — that is expected to be `iaac-octopus-onprem` (section 05, *unverified*).

### Lifecycles — `lifecycles.yaml`

Eleven of them (`feature`, `feature-manual`, `feature-plan`, `feature-external`, `release`,
`release-external`, `release-auto`, `develop`, `release-production`, `release-production-auto`).
Each phase names environments explicitly, and the module resolves them to ids:

```hcl
optional_deployment_targets = [
  for x in try(phase.value["environments"]["manual_deploy"], []) : local.environments[x].id
]
automatic_deployment_targets = [
  for x in try(phase.value["environments"]["auto_deploy"], []) : local.environments[x].id
]
```

> **An environment that appears in no lifecycle phase exists in the UI and can never receive a
> deployment.** Adding a name to `environments.yaml` and stopping there produces a green PR and
> a dead environment. This is the single most important line in this document.

Retention is per phase, and prod is deliberately different — items, not days:

```yaml
- name: production
  release_retention: { quantity: 10, unit: Items }
  package_retention: { quantity: 7,  unit: Days }
```

### Script modules — `scripts/**`

```hcl
files = [for f in tolist(fileset(path.root, "scripts/**")) : {
  module    = basename(dirname(f))     # "Bash" or "PowerShell" -> the SYNTAX
  file_name = replace(basename(f), "/\\.[0-9a-zA-Z]+$/", "")
  path      = f
}]
```

The **parent directory name is the script syntax**. A file in `scripts/Bash/` is published as a
Bash script module. Move it to `scripts/PowerShell/` and its language changes with no other edit.

### Library variable sets

```hcl
for_each = {
  for t in local.config.variable_sets : replace(t, "deprecated-", "") => t
}
name = each.value      # the FULL name, prefix included
```

The Terraform *address* strips `deprecated-`; the Octopus *name* keeps it. So renaming a set to
`deprecated-foo` marks it in the UI **without destroying and recreating it**. Deliberate, and easy
to undo by accident.

**Only the set is created here — not the variables inside it.** Those come from `vars.yaml` via
`run_variables.ps1`:

```yaml
vars:
  AWSAccounts:
    v:
      AWS_ACCOUNT_dev:  { unscoped: '700736442855', scoped: '' }
      AWS_ACCOUNT_qa:   { unscoped: '527101283767', scoped: '' }
```

## 5. Changed from default

| Change | Where | Why it matters |
|---|---|---|
| `prevent_destroy = true` on the space | `spaces/main.tf` | a space holds every project; a plan can never propose removing it |
| `ignore_changes = [is_default, space_managers_teams, space_managers_team_members]` | same | team membership is edited in the UI and would otherwise revert every run |
| `sort_order = index + 10` | `modules/common/main.tf` | UI ordering is list ordering — and a hidden coupling |
| `replace(t, "deprecated-", "")` as the map key | same | deprecation is a rename, not a replacement |
| directory name as script syntax | same | no per-script metadata to keep in sync |
| `description = "\`Created by Terraform\`"` | everywhere | backticks are Octopus markdown — it renders as code in the UI |
| import step commented out | `run_spaces.ps1` | drift is not re-adopted; a hand-made object collides on name |
| `SpacesVariablesTfApply` gate | `run_spaces.ps1` | see below |

## 6. Machine sizes

**None.** This repo sizes nothing. It names worker *pools*; the machines that join them are
elsewhere. Recorded here only because the question is asked of every section.

## 7. What is NOT automated

| # | Gap | Consequence |
|---|---|---|
| 1 | **Projects and project variables.** No `octopusdeploy_project`, no `octopusdeploy_variable`. | Every `TF_VAR_*` that builds a Talos cluster is typed into a web form. This is where `TBD-qa-vip`, the wrong Flux repository name and dev's 2 vCPU all came from. |
| 2 | **The apply is gated.** `if ($SpacesVariablesTfApply -eq "true")`. | A green run means a plan was printed. Second repo with this exact pattern — `iaac-talos` has `TfApply` — so treat it as a house convention, not an oddity. [[octopus-green-but-no-apply]] |
| 3 | **Imports are disabled.** | An object created by hand does not get adopted; the next run tries to create it and fails on a duplicate name. |
| 4 | `space_vars` defines prefixes for `Engineering`, `USXpress` and `OnPrem`, none of which are in `allowed_spaces`. | Either three spaces are managed elsewhere, or the map is dead. Unresolved. |
| 5 | **Not yet read:** `run_variables.ps1`, `scripts/setup.ps1`, `.github/workflows/deploy.yml`, `config.gotmpl`, `common.tfvars.gotmpl`, both import scripts, `vars.yaml` past line 40. | §1 and the variable-value half of §4 are therefore partial. |

## 8. Standing up QA2 here

Three edits, one PR:

```yaml
# deploy/config/environments.yaml   -- APPEND, never insert
environments:
  - plan
  - development
  - qa
  - staging
  - production
  - qa2            # appended: no other environment's sort_order moves

# deploy/config/worker_pools.yaml
  - usxpress-qa2

# deploy/config/lifecycles.yaml     -- without this, qa2 can never be deployed to
```

Then `SpacesVariablesTfApply=true`, or nothing is applied.

**Blast radius:** additive in both `Default` and `DevOps`. No existing environment, pool or
lifecycle is modified, *provided the append rule is followed*. Nothing deploys to a new
environment until a project targets it.

**Still manual afterwards:** every `TF_VAR_*` on the `iaac-talos` project.

---

## Proven

- The repo creates exactly five object types; `octopusdeploy_project` and
  `octopusdeploy_variable` appear nowhere. Verified by `grep -rn '^resource "'`.
- `grep -rn "TF_VAR_\|iaac-talos" deploy/config/` returns nothing.
- `allowed_spaces` is `Default` and `DevOps`; the module runs once per space with its own state.
- The apply is conditional on `SpacesVariablesTfApply`.
- Lifecycle phases resolve environments by name through `local.environments[x].id`.

## Tested and killed

- *"Octopus variables for `iaac-talos` are managed as code somewhere."* They are not.
- *"Adding an environment is one line."* It is three, and the lifecycle line is the one that
  makes the environment usable.

## Traps

1. **An environment in no lifecycle phase cannot be deployed to.** It looks fine in the UI.
2. **Insert into `environments.yaml` and you renumber the rest.** Append.
3. **`jira_environments` falls back to `unmapped`** for any name not in the map.
4. **Green means planned, not applied.**
5. **`allowed_spaces` has two entries, `space_vars` has five.** Do not read that map as the list
   of managed spaces.
