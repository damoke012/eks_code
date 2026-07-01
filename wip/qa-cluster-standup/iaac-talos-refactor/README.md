# iaac-talos parameterization refactor — preview + apply commands

**Ticket:** INFRA-1585 (QA cluster stand-up) — this is the code refactor blocker

**Goal:** single iaac-talos code path, per-env tfvars files, ready for Dev + QA + Prod.

## What's in this directory

```
iaac-talos-refactor/
├── README.md                                          # you are here
├── patches/
│   ├── 01-variables-additions.tf                      # ADD to variables.tf
│   ├── 02-main-vsphere-worker-block.md                # REPLACE the vsphere_worker + parts of talos block in main.tf
│   ├── 03-risingwave-2-imports-gate.md                # git mv the file to .tf.dev-only
│   └── 04-talosconfig-secret-import-parameterize.md   # tiny edit to talosconfig-secret-import.tf
└── deploy/terraform/envs/
    ├── dev.tfvars                                     # NEW file — Dev's current values in envs/ pattern
    └── qa.tfvars                                      # NEW file — QA's three-pool architecture values
```

## Apply — from WSL, in your iaac-talos clone

**Assumes you're on a fresh feature branch off `feature/op-usxpress-dev`.**

```bash
cd ~/work/iaac-talos
git checkout feature/op-usxpress-dev
git pull
git checkout -b refactor/multi-env-parameterization

# 1. Copy the drafted files into place (from wherever your eks_code clone is)
EKS_CODE_DIR=~/work/eks_code   # adjust if different
REFACTOR_DIR="$EKS_CODE_DIR/wip/qa-cluster-standup/iaac-talos-refactor"

# 1a. Append the new variables to variables.tf
cat "$REFACTOR_DIR/patches/01-variables-additions.tf" >> deploy/terraform/variables.tf

# 1b. Create the envs directory + copy the two tfvars files
mkdir -p deploy/terraform/envs
cp "$REFACTOR_DIR/deploy/terraform/envs/dev.tfvars" deploy/terraform/envs/dev.tfvars
cp "$REFACTOR_DIR/deploy/terraform/envs/qa.tfvars" deploy/terraform/envs/qa.tfvars

# 1c. Gate the RW-2 imports (rename so TF stops loading it in QA)
git mv deploy/terraform/risingwave-2-imports.tf deploy/terraform/risingwave-2-imports.tf.dev-only

# 2. Edit main.tf and talosconfig-secret-import.tf per the patches/*.md instructions
# These require targeted block-replacements, not automatable safely — open the
# two .md files and follow the "Find this / Replace with" blocks in your editor.
code deploy/terraform/main.tf
code deploy/terraform/talosconfig-secret-import.tf
```

## Verify — no changes required to Dev's actual infrastructure

The whole point of migrating Dev's config to the envs/ pattern is that
`terraform plan -var-file=envs/dev.tfvars` should produce **an empty diff**
against Dev's live state. If it wants to change anything, the migration is
wrong and needs revisiting.

```bash
cd deploy/terraform

# Format + validate
terraform fmt -check -recursive
terraform validate

# Init against Dev's backend
export AWS_PROFILE=usx-dev
terraform init \
  -backend-config="bucket=lazy-tf-state-65v583i6my68y6x9" \
  -backend-config="key=iaac/talos/op-usxpress-dev.tfstate" \
  -backend-config="region=us-east-2" \
  -backend-config="dynamodb_table=lazy_tf_state" \
  -backend-config="encrypt=true"

# Plan with Dev's env-file (Octopus normally provides the secret vars;
# for local verification supply them via a private tfvars or -var flags)
terraform plan \
  -var-file=envs/dev.tfvars \
  -var="vsphere_user=<...>" \
  -var="vsphere_password=<...>" \
  -var="vsphere_server=<...>" \
  -var="github_token=<...>" \
  -var="datacenter=<...>" \
  -var="datastore=<...>" \
  -var="vm_cluster_name=<...>" \
  -var="vm_folder=<...>" \
  -var="network_name=<...>" \
  -var="content_library_name=<...>" \
  -var="content_library_item_name=<...>" \
  -out=plan.tfplan

# EXPECTED: "No changes. Your infrastructure matches the configuration."
# If not, the refactor changed something semantically — do NOT apply.
```

## QA plan (dry-run only — nothing exists yet)

```bash
# Switch to QA backend (already exists per earlier finding)
export AWS_PROFILE=usx-qa
rm -rf .terraform
terraform init \
  -backend-config="bucket=lazy-tf-state-425rbol87rmn6c7m" \
  -backend-config="key=iaac/talos/op-usxpress-qa.tfstate" \
  -backend-config="region=us-east-2" \
  -backend-config="dynamodb_table=lazy_tf_state" \
  -backend-config="encrypt=true"

# Dry-run QA plan — expected: TONS of adds (new cluster), zero destroys, zero changes
terraform plan \
  -var-file=envs/qa.tfvars \
  -var="vsphere_user=<...>" \
  ...
  -out=qa-plan.tfplan
```

## Modules/talos changes — still pending

For pool labels/taints to actually land on the QA worker nodes, `modules/talos/main.tf` needs to accept the `worker_pools` structure and apply labels+taints per-worker in the machine config.

Please paste `deploy/terraform/modules/talos/main.tf` and `deploy/terraform/modules/talos/variables.tf` when you can — I'll draft that patch and add it as `patches/05-modules-talos-*.md`.

Until that lands, `worker_pools` sets sizing but nodes come up without pool labels.

## Follow-up tickets to file

- INFRA-15XX: iaac-talos-flux-platform op-qa branch scaffolding
- INFRA-15XX: seed talosconfig SM secret in USX-QA (op-usxpress-qa/talosconfig)
- INFRA-15XX: cloud team ONPREM_BOOTSTRAP_ROLE_ARN_QA + GHA secret
- INFRA-15XX: RW-2 gating cleanup (migrate from `.tf.dev-only` rename to for_each pattern)
