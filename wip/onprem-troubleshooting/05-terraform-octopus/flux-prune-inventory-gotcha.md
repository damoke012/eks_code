# Flux Prune Inventory Gotcha — Removing a File Deletes the Live Resource

**Symptom:**
- You remove a YAML file from a Flux-managed Kustomization (intending to detach it from GitOps)
- Live resource gets DELETED on next reconcile
- Past applies failed and the resource was added directly via kubectl — but Flux had it in inventory and prunes it anyway

**Root cause:**
Flux Kustomizations with `prune: true` (default) maintain an INVENTORY of resources they've applied. On reconcile, Flux deletes any resource in inventory that's no longer in source.

The inventory tracking is RETROACTIVE: even if a past `kubectl apply -f` failed, if Flux ever applied (or tried to apply) the resource and recorded it in inventory, that resource is now "Flux-owned" from Flux's perspective. Removing the file → Flux prunes the live resource.

**Real incident**: 2026-05-22 — Tim's RW NodePort got pruned when someone removed the file thinking it had never deployed (it had).

**IaC coverage:** ⚠ (detach procedure documented; no auto-guard)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/<workload>/` — any file here that was ever applied by Flux is in inventory

### Resolution via IaC

There's no IaC "auto-fix" — the Flux behavior is by design. The fix is procedural: **detach before removing**.

### Manual resolution — PROPER DETACH PROCEDURE

Before removing a file from a Flux-managed Kustomization:

**Step 1 — Annotate the live resource to detach it from Flux:**

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

NS=<namespace>
KIND=<kind>     # e.g., service, configmap, deployment
NAME=<name>

# Both annotations needed:
# - kustomize.toolkit.fluxcd.io/prune=disabled → exempt from prune on next reconcile
# - kustomize.toolkit.fluxcd.io/reconcile=disabled → exempt from update on next reconcile
kubectl $KCONFIG -n $NS annotate $KIND $NAME \
  kustomize.toolkit.fluxcd.io/prune=disabled \
  kustomize.toolkit.fluxcd.io/reconcile=disabled \
  --overwrite
```

**Step 2 — Verify the annotation:**

```bash
kubectl $KCONFIG -n $NS get $KIND $NAME -o yaml | grep -A 2 "fluxcd.io/prune\|fluxcd.io/reconcile"
```

**Step 3 — NOW remove the file from the Flux source repo:**

```bash
cd <repo>
git rm path/to/file.yaml
git commit -m "chore: remove <resource> from Flux (already detached via annotation)"
git push
```

**Step 4 — Verify on next Flux reconcile that the resource SURVIVED:**

```bash
# Wait for reconcile
sleep 60
kubectl $KCONFIG -n $NS get $KIND $NAME
# Expect: still exists, no deletion event
```

### What to do if you ALREADY pruned a resource

**Step 1 — Confirm the resource was actually pruned (vs evicted/crashed):**

```bash
# Check Flux event log
kubectl $KCONFIG -n flux-system get events | grep -i prune

# Check the Kustomization's last reconcile status
kubectl $KCONFIG -n flux-system get kustomization <name> -o yaml | grep -A 5 inventory
```

**Step 2 — Recreate the resource:**

If you have the spec saved (e.g., in git history of the removed file), apply directly:

```bash
git show HEAD~1:path/to/removed-file.yaml > /tmp/recover.yaml
kubectl $KCONFIG apply -f /tmp/recover.yaml
```

**Step 3 — Apply the detach annotation IMMEDIATELY** (step 1 above) before next Flux reconcile.

### Prevention

- **Always detach before removing** — make this a code review checklist item
- **PR template**: include a checkbox: "Did you annotate live resources with prune=disabled before removing source files?"
- **CI lint** (planned): if a PR removes YAML files from `infrastructure/`, comment a warning with the detach procedure
- **Flux inventory diff tool** (planned): pre-merge job that compares HEAD vs the PR's diff and reports what would be pruned

### Related

- [[../02-storage/stuck-finalizer-removal]] — different deletion-semantics gotcha
- [[iaac-talos-branch-base]] — accidental wrong-base PR could prune lots of things
- Memory: `[Flux prune inventory gotcha]`

### Memory pointers

- `[feedback_flux_prune_inventory_gotcha]` — codified gotcha (proven by 2026-05-22 incident)
- `[Protect RW on op-usxpress-dev]` — relevant: RW NodePort was the resource pruned
