# Phase-1 gap — nothing bootstraps Flux on a greenfield cluster

**Found 2026-07-28 while merging `refactor/multi-env-parameterization` → `master` (PR #58).**
**Fails SILENTLY — worse than the SSM blocker, which at least fails loudly.**

## What the flux module actually does now

`deploy/terraform/modules/flux/main.tf`, on BOTH master and the refactor branch:

- `terraform_data.wait_for_cluster` — a TCP wait loop against the cluster endpoint
- `removed { from = flux_bootstrap_git.this }` — no-op on greenfield
- `removed { from = terraform_data.restore_infra_refs }` — no-op on greenfield

That is the whole module. It still declares the `fluxcd/flux` provider and still accepts
`target_path`, `github_token`, `github_owner`, `github_repository`, `github_branch`
(`main.tf:198-210`) and uses **none** of them. There is no `flux_bootstrap_git` resource
anywhere in the config.

**So `terraform apply` on greenfield prod produces a bare Talos cluster with no Flux:** no
`flux-system` namespace, no GitRepository, no Kustomizations, no platform stack.
`TF_VAR_flux_target_path=clusters/op-usxpress-prod` is consumed by nothing. Terraform exits 0.

## Why nobody hit it

`2f2ad95` (Option B, PR #27) removed `flux_bootstrap_git` because the flux provider treats
`repository_files` as Computed, so `lifecycle.ignore_changes` could not suppress drift that
re-pruned `infra-source.yaml` + `infra.yaml` from `kustomization.yaml` on every plan — it broke
the cluster 3x in 24h. Dropping it from state was the right fix **for clusters that already have
Flux installed**, which is dev and QA. Prod is the first greenfield cluster since.

The commit message states the trade-off explicitly:
> *"future Flux upgrades become manual (edit gotk manifests in git or run 'flux bootstrap' in a
> maintenance window)"*

Manual bootstrap is the accepted consequence. It was simply never written down as a stand-up
step, because no cluster had been stood up from scratch since.

## Fix — do NOT re-add the resource

Re-adding a `count`-gated `flux_bootstrap_git` is the tempting option and it is wrong twice over:

1. It cannot coexist with `removed { from = flux_bootstrap_git.this }` for the same address —
   Terraform errors. The `removed` blocks would have to be deleted, and they are what keeps
   dev/QA clean.
2. It would put `flux_bootstrap_git` into **prod's** state, reintroducing for prod exactly the
   drift cascade that broke dev three times in 24 hours.

**Instead: apply the already-committed gotk manifests directly.** `clusters/op-usxpress-prod/`
landed on `iaac-talos-flux-cluster` master via PR #28 and already contains `gotk-components.yaml`,
`gotk-sync.yaml`, `infra-source.yaml`, `infra.yaml`, `kustomization.yaml`.

This is strictly better than `flux bootstrap`, which is what caused the original cascade by
rewriting `kustomization.yaml`. Applying the committed manifests installs Flux and wires the
infra references in one step, with git as the source of truth and nothing in Terraform state.

```bash
# after the first successful prod apply, from the Octopus task's terraform output
terraform output -raw kubeconfig > /tmp/prod.kubeconfig
export KUBECONFIG=/tmp/prod.kubeconfig
kubectl get nodes                      # sanity: control plane up

cd ~/work/iaac-talos-flux-cluster && git checkout master && git pull --ff-only
kubectl apply -k clusters/op-usxpress-prod/flux-system/

kubectl -n flux-system get pods                    # controllers Running
flux get sources git                               # infra-source -> op-prod branch
flux get kustomizations                            # phase-1 core reconciling
```

Then RUNBOOK gate **B7 first**: confirm `flux get kustomizations` reports the merged SHA before
testing anything downstream.

## Related

- [PHASE1-SSM-VALIDATE-BLOCKER.md](PHASE1-SSM-VALIDATE-BLOCKER.md) — the other phase-1 blocker
  found the same day. That one fails loudly (`exit 1`); this one passes green.
- Both share a cause: dev and QA were only ever built **forward**, so no code path that only
  matters on a from-scratch build has ever run. Expect more of these, and prefer checks that
  prove the artifact over checks that read an exit code.
