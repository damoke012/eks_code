# Flux bootstrap Terraform module — INFRA-1542 scaffold

**Purpose:** Replace the manual `flux bootstrap github` step in `iaac-talos-flux-cluster/README.md` with a Terraform module that runs after Talos cluster up. Closes the bootstrap automation gap.

**Status:** Scaffold. Verify against your iaac-talos provider versions + run order before committing to iaac-talos.

## What it does

1. Reads kubeconfig from iaac-talos state output (`talos_machine_secrets`)
2. Runs `flux install` on the cluster (controllers + CRDs)
3. Configures GitRepository pointing at iaac-talos-flux-cluster/master
4. Configures the root Kustomization pointing at `clusters/bm-dev/`
5. Optionally seeds the deploy-key for the GitHub repo (or uses GitHub App)

## Provider versions

```hcl
required_providers {
  flux = {
    source  = "fluxcd/flux"
    version = ">= 1.4.0"
  }
  github = {
    source  = "integrations/github"
    version = ">= 6.0"
  }
  kubernetes = {
    source  = "hashicorp/kubernetes"
    version = ">= 2.27"
  }
}
```

## Run order in iaac-talos

After existing talos + machine config steps, append:
1. `module.flux_bootstrap` — installs Flux on cluster, configures source + root Kustomization
2. Cluster watches GitHub, applies all Kustomizations under `clusters/bm-dev/`
3. Within ~10 minutes, every Kustomization should be Ready=True

## Inputs needed

- `cluster_endpoint` — Talos API VIP (10.10.82.50:6443)
- `cluster_ca` / `cluster_cert` / `cluster_key` — from talos_machine_secrets
- `github_token` — PAT with repo scope (or GitHub App credentials)
- `flux_repo_owner` — variant-inc
- `flux_repo_name` — iaac-talos-flux-cluster
- `flux_repo_branch` — master
- `flux_path` — clusters/bm-dev

## Skeleton

```hcl
module "flux_bootstrap" {
  source = "./modules/flux-bootstrap"
  cluster_endpoint = "https://10.10.82.50:6443"
  cluster_ca       = data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate
  cluster_cert     = data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate
  cluster_key      = data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key

  github_token     = var.github_token

  flux_repo_owner  = "variant-inc"
  flux_repo_name   = "iaac-talos-flux-cluster"
  flux_repo_branch = "master"
  flux_path        = "clusters/bm-dev"
}
```

## Why this is a scaffold (not the full module)

Standing up the actual Terraform module requires:
1. Choosing GitHub credential strategy (PAT vs App vs OIDC)
2. Deciding whether to commit the bootstrap-generated manifests back to git (default) or use stateless apply
3. Testing on a non-prod cluster first

These are 1-2 hours of careful work + needs the existing iaac-talos provider versions verified. Not safe to write end-to-end in this session.

## Acceptance criteria

When INFRA-1542 closes, a fresh `terraform apply` on iaac-talos should:
- Bring up Talos cluster
- Install Flux on cluster
- Configure GitRepository + root Kustomization
- Without ANY manual `flux bootstrap` invocation

## Refs

- Provider docs: https://registry.terraform.io/providers/fluxcd/flux/latest/docs
- Example: https://github.com/fluxcd/flux2-kustomize-helm-example
- Related: INFRA-1543 (Octopus IaC pairs with this for full automation)
