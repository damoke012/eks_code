# Gate risingwave-2-imports.tf on `var.enable_rw2_imports`

## Problem

`deploy/terraform/risingwave-2-imports.tf` hardcodes `op-usxpress-dev` and always runs. QA doesn't have RW-2 in Phase 1; Prod won't either until later. Currently blocks environment reuse.

## Fix

Wrap each `import` block (and any adjacent resource declarations in the file) with `count = var.enable_rw2_imports ? 1 : 0`.

`import` blocks (Terraform 1.5+) do not accept `count` directly. Two options:

## Option A (cleanest): use `for_each` on the imported resources with a conditional set

If the file uses `import { ... }` blocks that reference existing `resource` definitions elsewhere, gate those resource definitions with `count` or `for_each` and let the import become a no-op when the resource isn't declared.

## Option B (simplest): use `moved` semantics + Terraform 1.6 `import` with `for_each`

Starting Terraform 1.6, `import` blocks support `for_each`. Change each import block from:

```hcl
import {
  to = aws_s3_bucket.risingwave_data
  id = "risingwave-data-op-usxpress-dev"
}
```

to:

```hcl
import {
  for_each = var.enable_rw2_imports ? toset(["enabled"]) : toset([])
  to       = aws_s3_bucket.risingwave_data
  id       = "risingwave-data-op-usxpress-dev"
}
```

And ensure the target resource (`aws_s3_bucket.risingwave_data`) is also gated with `for_each = var.enable_rw2_imports ? toset(["enabled"]) : toset([])`.

## Option C (safest fastest — for the refactor PR): move the file out of the always-loaded set

Rename `risingwave-2-imports.tf` to `risingwave-2-imports.tf.dev-only`. Terraform ignores non-`.tf` files.

For Dev: symlink or copy it back to `risingwave-2-imports.tf` inside the Octopus TfApply step for the Dev environment only.

For QA/Prod: leave it as `.tf.dev-only` — never loaded.

**Recommended: Option C for the refactor PR.** Cleanest, no logic changes. Follow-up ticket to migrate to Option B pattern once we validate Option C works in Dev's Octopus pipeline.

## The change in one command

```bash
# Inside iaac-talos on your feature branch:
git mv deploy/terraform/risingwave-2-imports.tf deploy/terraform/risingwave-2-imports.tf.dev-only

# For the Dev Octopus project step, add a pre-plan script:
# if [ "$OCTOPUS_ENVIRONMENT" = "development" ]; then
#   cp deploy/terraform/risingwave-2-imports.tf.dev-only deploy/terraform/risingwave-2-imports.tf
# fi
```

Or if Octopus already handles this via env-gated file inclusion, adjust to that pattern.
