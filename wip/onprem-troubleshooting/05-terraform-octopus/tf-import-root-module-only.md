# Terraform `import` Block in Child Module — Rejected

**Symptom:**
- Octopus deploy fails at `terraform validate` or `terraform plan` with:
  ```
  Error: Invalid import block placement
   on modules/<some-module>/imports.tf line N:
   Import block must be declared at the root module level.
  ```

**Root cause:**
Terraform 1.5+ introduced `import` blocks (config-as-code import). They must be declared in the **root module** with explicit addresses like `module.<name>[<idx>].<resource>`.

Putting `import { id = ..., to = ... }` inside a child module is silently invalid syntax — Terraform 1.5+ rejects it at validate.

**IaC coverage:** ✓ (codified as a memory + linting opportunity)

**IaC location:**
- N/A — this is a TF code authoring rule
- Could add to PR review checklist or pre-commit hook

### Resolution via IaC

Move all `import` blocks to a root-level `imports.tf` file (or `main.tf`). Address resources via their module path.

**Wrong (child module):**

```hcl
# modules/vsphere_vm/imports.tf
import {
  to = vsphere_virtual_machine.vm[0]
  id = "vm-uuid"
}
```

**Right (root module):**

```hcl
# imports.tf (at repo root, alongside main.tf)
import {
  to = module.vsphere_worker.vsphere_virtual_machine.vm[0]
  id = "vm-uuid"
}
```

### Manual resolution

```bash
# 1. Find all import blocks in modules
find deploy/terraform/modules -name "*.tf" | xargs grep -l "^import {"

# 2. For each one, extract the import statement
# 3. Construct the module-prefixed address
#    e.g., if it's in modules/vsphere_vm/imports.tf and the module is called as `module.vsphere_worker`:
#    OLD: to = vsphere_virtual_machine.vm[0]
#    NEW: to = module.vsphere_worker.vsphere_virtual_machine.vm[0]

# 4. Move to root-level imports.tf, delete the child-module version
# 5. terraform validate
# 6. PR with corrected placement
```

### Verification

```bash
cd ~/work/iaac-talos/deploy/terraform
terraform validate
# Expect: "Success! The configuration is valid."

terraform plan -out=tfplan
# Expect: import operations show up in plan output for the correct addresses
```

### Prevention

- **Memory rule**: `[TF import blocks must be in root module]`
- **Pre-commit hook**: scan for `^import {` inside `modules/` directory, reject
- **Code review checklist**: any new `import` block must be at root level with module-prefixed address

### Related

- [[iaac-talos-branch-base]] — PR base affects which validate runs
- Memory: `[TF import blocks must be in root module]`

### Memory pointers

- `[feedback_tf_import_root_module_only]` — codified gotcha
