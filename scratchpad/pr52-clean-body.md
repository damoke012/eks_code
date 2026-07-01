## Summary

Parameterizes deploy/terraform/ so Dev / QA / Prod all use the same code with per-env tfvars.

- New worker_pools map-of-object variable with legacy-scalar fallback (Dev's flat config keeps working)
- module.vsphere_worker now iterates per pool via for_each on local.effective_worker_pools
- New local.worker_pool_metadata list passed into modules/talos so per-pool labels + taints land on worker nodes via Talos machine config
- talosconfig-secret-import.tf ARN parameterized via var.talosconfig_secret_arn
- risingwave-2-imports.tf renamed to .tf.dev-only (Dev-Octopus renames it back on apply; QA / Prod don't load it)
- New envs/dev.tfvars: Dev's existing config migrated to the envs/ pattern (empty worker_pools, flat scalars retained)
- New envs/qa.tfvars: op-usxpress-qa three-pool architecture (system 2x8GB, platform 3x16GB, application 5x32GB)

## Backward compatibility

Dev's next Octopus TfApply is expected to show no infrastructure changes:

- worker_pools empty in dev.tfvars -> effective_worker_pools fallback path builds the same single default pool the old code did
- worker_pool_metadata empty -> modules/talos merge/length checks resolve to the pre-refactor behavior
- risingwave-2-imports.tf.dev-only renamed back to .tf by Dev's TfApply step

## Verification plan

- Octopus Dev environment terraform plan shows empty diff
- Once merged: iaac-talos QA environment gets a new Octopus environment/variable set
- QA plan runs against USX-QA (state bucket already exists)

## Refs

- INFRA-1585 (QA cluster stand-up)
- INFRA-1560 (QA prod-readiness epic)
- Confluence: QA cluster stand-up + production readiness (page 4589191169)
