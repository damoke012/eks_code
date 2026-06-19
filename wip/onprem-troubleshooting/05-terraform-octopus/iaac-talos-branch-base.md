# iaac-talos Branch Base — master vs feature/op-usxpress-dev

**Symptom:**
- PR against `master` shows a catastrophic plan diff: hundreds of resource changes / destroys
- Apply against `master` would destroy the running cluster
- Local `git pull origin master` then plan against local state confuses everything

**Root cause:**
The `iaac-talos` repo has two long-lived branches:
- **`master`** — stuck at version `0.0.8` (stale; pre-on-prem)
- **`feature/op-usxpress-dev`** — current cluster source of truth, version `0.1.0+`

The `master` branch was never updated when the on-prem fork happened. PRs intended for the on-prem cluster MUST target `feature/op-usxpress-dev`. A PR against `master` would re-create the cluster from a stale baseline.

**IaC coverage:** ✓ (codified as a memory + branch protection ideal)

**IaC location:**
- Branch protection on `feature/op-usxpress-dev` ideally requires PR review (verify in GH UI)
- `iaac-talos/CONTRIBUTING.md` (planned) should document the branch base policy

### Resolution via IaC

The fix is procedural — PR base selection. There's no auto-detection that catches "PR was opened against wrong branch" beyond CI plan diff review.

### Manual confirmation procedure

```bash
# Verify current cluster is on feature branch
cd ~/work/iaac-talos
git branch -a | grep -E "feature/op-usxpress-dev|master"

# Switch to the on-prem feature branch
git checkout feature/op-usxpress-dev
git pull origin feature/op-usxpress-dev

# Confirm version matches cluster's reality
grep -i version variables.tf README.md 2>/dev/null | head -3
# Expect: 0.1.0+ (NOT 0.0.8)
```

When creating a PR:

```bash
git checkout -b feature/INFRA-XXXX-<short-name>

# ... make changes ...

git push -u origin feature/INFRA-XXXX-<short-name>

# CRITICAL: --base feature/op-usxpress-dev, NOT master
gh pr create \
  --base feature/op-usxpress-dev \
  --title "..." \
  --body "..."
```

### Verification

```bash
# After PR opens, verify base branch in URL or web UI
# URL pattern:
# https://github.com/variant-inc/iaac-talos/compare/feature/op-usxpress-dev...feature/INFRA-XXXX-yourbranch

# In the PR diff: changes should be MINIMAL (just your intended change)
# If you see hundreds of file changes → base is wrong, close PR + reopen with correct base
```

### Catastrophic-plan check (BEFORE merging)

```bash
# Octopus plan-only step will show diff size
# If "Plan: 1 to add, 15 to change, 1 to destroy" matches your intent → OK
# If "Plan: 50 to add, 200 to change, 30 to destroy" → STOP, base is wrong
```

### Prevention

- **Memory rule**: `[iaac-talos PR base = feature/op-usxpress-dev]` is binding
- **Branch protection** on `master`: lock down so PRs can't merge there inadvertently
- **CI: plan diff threshold**: if Octopus plan shows > N changes (say 30+), require explicit human ack before apply
- **Future**: rename `master` → `cloud-deprecated` or similar to make the wrong branch self-evident

### Related

- [[octopus-tfapply-variable]] — TfApply on `master`-based PRs would be catastrophic
- [[compact-data-source-race]] — base matters for PR #40 which fixed compact()
- Memory: `[iaac-talos PR base = feature/op-usxpress-dev]`

### Memory pointers

- `[feedback_iaac_talos_branch_base]` — codified gotcha (confirmed 2026-05-20 release 1.134)
- `[Confirm before executing]` — slow down before assuming PR base
