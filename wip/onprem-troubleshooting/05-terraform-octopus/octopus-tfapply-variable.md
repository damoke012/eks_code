# Octopus TfApply Variable — Plan-Only vs Apply

**Symptom:**
- Octopus deploy completed successfully but cluster state didn't change
- No `Apply complete!` line in deploy log — only plan output
- Or worse: state changed unexpectedly on a deploy you thought was plan-only

**Root cause:**
The `iaac-talos` Octopus project has a project variable `TfApply` (`true`/`false`). The step script reads this variable and conditionally runs `terraform apply` after the plan.

- `TfApply=false` (safety default): plan-only. Step logs plan output, then exits without applying.
- `TfApply=true`: plan + apply. Step runs `terraform apply tfplan` after the plan.

If you forget the current setting and trigger a deploy, you might:
- Plan-only when you expected apply (wasted cycle)
- Apply when you expected plan-only (cluster changes you didn't review)

**IaC coverage:** ✓ (codified as project variable; flip via Octopus UI)

**IaC location:**
- Octopus → iaac-talos → Project Variables → `TfApply` (default value, scope: all)

### Resolution via IaC

The variable IS the IaC. To control plan vs apply:

1. **Before flipping**: confirm current value in Octopus UI
2. **To apply**: flip `TfApply` → `true`, save, trigger release
3. **After applying**: flip `TfApply` → `false` immediately (safety default)
4. **Always plan-only first**: if uncertain, use `TfApply=false` for the initial review

### Manual confirmation procedure (before every deploy)

```bash
# Visit Octopus UI:
# https://<your-octopus>/app#/Spaces-1/projects/iaac-talos/variables

# Look for: TfApply
# Confirm: true or false
# If apply NOT intended → flip to false BEFORE triggering release
```

### Verification after deploy

```bash
# Find this line in the deploy log to confirm apply ran (not just plan)
# Octopus deploy log → search for: "Apply complete!"

# Example:
# Apply complete! Resources: 0 added, 17 changed, 0 destroyed.

# If only "Plan: X to add, Y to change, Z to destroy" appears with no Apply line,
# it was plan-only.
```

### Prevention

- **Always plan-only first** for new code (`TfApply=false`)
- **Flip back to `false`** immediately after a successful apply
- **PromRule on TfApply state** (planned): alert if `TfApply=true` for > 24h (someone forgot to flip back)
- **Octopus deploy approval gate**: configure release to require manual approval before apply (currently auto-deploys)

### Edge cases

- **Re-deploy of an existing release uses fresh variable values at deploy time** (NOT snapshotted at release creation). So flipping `TfApply` before a re-deploy DOES take effect.
- **Release-mirror workflow** auto-creates new releases when a PR merges to `feature/op-usxpress-dev`. Those default to `TfApply=false` unless flipped before manual deploy.

### Related

- [[iaac-talos-branch-base]] — what branch to PR against (matters for what gets mirrored)
- [[../../../iac-sweep-jun18/INCIDENT-COVERAGE-MATRIX-2026-06-19]] — current open IaC PRs
- Memory: `[Octopus TfApply variable controls plan vs apply]`

### Memory pointers

- `[reference_octopus_tfapply_variable]` — codified gotcha
- `[No auto re-deploy]` — workflow rule
- `[No manual CI/CD shortcuts]` — releases via GHA, deploys via Octopus UI
