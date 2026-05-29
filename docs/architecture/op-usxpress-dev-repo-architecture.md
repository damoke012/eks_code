op-usxpress-dev Cluster Repository Architecture

Author:     Dare Oke
Date:       March 25, 2026
Purpose:    Complete breakdown of all repos tied to cluster creation, their structure,
            what was configured, and how they are triggered.


REPO 1: variant-inc/iaac-talos

Purpose:     Terraform that provisions the Talos Kubernetes cluster (VMs, bootstrap, Flux, IRSA)
Branch:      feature/op-usxpress-dev
Triggered by: Git push -> GitHub Actions -> Octopus release + deploy

Directory structure:

  iaac-talos/
    .github/
      workflows/
        octo.yaml                    GHA workflow: validates + pushes package to Octopus
    deploy/
      deploy.ps1                     Main deployment script (PowerShell)
      terraform/
        main.tf                     Root module: wires together all sub-modules
        providers.tf                Provider configs: vsphere, talos, flux, aws
        variables.tf                All input variables (cluster_name, vip, worker_count, etc.)
        modules/
          vsphere_vm/
            main.tf                 Creates VMs from OVA template in vSphere content library
          talos/
            main.tf                 Generates talos machine configs, bootstraps K8s, gets kubeconfig
          cilium/
            main.tf                 Applies Cilium CNI via inline manifests
          flux/
            main.tf                 Bootstraps Flux CD, pushes gotk manifests to flux-cluster repo
          irsa/
            main.tf                 Creates S3 bucket, CloudFront, IAM OIDC provider for IRSA
            scripts/
              jwks.sh               Generates JWKS from Talos SA signing key

GHA Workflow (octo.yaml):

  Trigger: Push to any branch
  Steps:
    1. Checkout code
    2. Setup Go, Terraform, TFLint
    3. Validate Terraform
    4. Package deploy/ folder using variant-inc/actions-octopus
    5. Push package to Octopus as "iaac-talos" with version from branch name
    6. Create Octopus release automatically in DevOps space

deploy.ps1 execution flow:

  1. Read all TF_* Octopus variables, set as environment variables
  2. Set S3_BUCKET, TF_STATE_KEY, AWS_DEFAULT_REGION from Octopus variables
  3. Check current AWS identity
  4. If AWS_ROLE_TO_ASSUME targets a different account, assume that role
     If already in target account, skip (avoid self-assume)
  5. Clear AWS CLI credential cache to force fresh sessions
  6. Run terraform init with S3 backend config
  7. If TfDestroy=true: terraform plan -destroy + apply
     If TfApply=true: terraform plan + apply + capture outputs

Terraform modules - what each creates:

  module "vsphere_cp"     3 control plane VMs from Talos OVA template
                          Names: talos-cp-op-dev-{1,2,3}
                          CPU: 2, RAM: 4096MB, Disk: 50GB
                          Network: 10.10.82 (vLAN 82) Prod
                          Folder: KubernetesD1/TalosD1/op-usxpress-dev

  module "vsphere_worker" 5 worker VMs from same template
                          Names: talos-wk-op-dev-{1..5}
                          CPU: 4, RAM: 4096MB, Disk: 50GB
                          60-second delay between VM creation for staggered boot

  module "talos"          Generates machine secrets (SA signing keypair, cluster ID)
                          Creates control plane + worker machine configs
                          Applies configs to each node via Talos API
                          Bootstraps first CP node
                          Waits for node readiness
                          Extracts kubeconfig

  module "cilium"         Installs Cilium CNI via inline Kubernetes manifests
                          L2 announcement mode (no BGP)

  module "flux"           Bootstraps Flux CD using flux_bootstrap_git resource
                          Creates clusters/bm-dev/flux-system/ in iaac-talos-flux-cluster repo
                          Generates gotk-components.yaml (Flux controllers)
                          Generates gotk-sync.yaml (self-referencing GitRepository + Kustomization)
                          Uses GitHub token for repo authentication

  module "irsa"           DISABLED (enable_irsa=false for initial provisioning)
                          When enabled:
                          - Creates S3 bucket for OIDC discovery documents
                          - Creates CloudFront distribution with OAC
                          - Uploads JWKS and OIDC discovery JSON to S3
                          - Creates IAM OIDC provider in target account
                          - Generates JWKS from Talos SA signing key via jwks.sh script

AWS provider configuration:

  provider "aws" {
    region = var.aws_region       Currently us-east-1 (development-scoped)
  }
  No assume_role block. Uses ambient worker credentials.
  Worker runs as 700736442855:octopus-usxpress (cloud dev account).

Terraform state:

  Backend: S3
  Bucket: lazy-tf-state-65v583i6my68y6x9 (cloud dev account 700736442855)
  Key: iaac/talos/op-usxpress-dev.tfstate
  Region: us-east-2
  Encrypt: true

Octopus project configuration:

  Project: iaac-talos (Projects-8283)
  Space: DevOps (Spaces-2)
  Channel: feature (Channels-9403)
  Lifecycle: iaac-feature-manual (Lifecycles-1502)
    Phase 1: development (Environments-1) - non-optional
    Phase 2: dpl (Environments-430) - optional

  Development-scoped variable overrides (Environments-1):
    TF_STATE_KEY                      = iaac/talos/op-usxpress-dev.tfstate
    TF_VAR_cluster_name               = op-usxpress-dev
    TF_VAR_vm_folder                  = /KubernetesD1/TalosD1/op-usxpress-dev
    TF_VAR_control_plane_name_prefix  = talos-cp-op-dev
    TF_VAR_worker_name_prefix         = talos-wk-op-dev
    TF_VAR_flux_target_path           = clusters/bm-dev
    TF_VAR_irsa_oidc_bucket_name      = op-usxpress-dev-oidc-irsa
    TF_VAR_control_plane_vip          = 10.10.82.50
    TF_VAR_endpoint                   = https://10.10.82.50:6443
    TF_VAR_enable_irsa                = false
    TF_VAR_aws_region                 = us-east-1
    TF_VAR_content_library_name       = dev-cluster
    TF_VAR_worker_count               = 5

  Unscoped defaults (used for cloud clusters):
    TF_VAR_cluster_name               = #{environment_abbreviation}-cluster
    TF_VAR_vm_folder                  = /KubernetesD1/TalosD1/#{environment_abbreviation}-cluster
    TF_VAR_disk_size_gb               = 50
    TF_VAR_control_plane_count        = 3
    S3_BUCKET                         = (from variable sets, not overridden)
    AWS_DEFAULT_REGION                = us-east-2
    AWS_ROLE_TO_ASSUME                = (from variable sets, cloud dev role)


REPO 2: variant-inc/iaac-talos-flux-cluster

Purpose:     Flux CD bootstrap manifests - tells Flux WHAT to deploy and WHERE to find it
Branch:      master
Triggered by: Flux CD reconciliation (every 1 minute) + iaac-talos Terraform flux module writes here

Directory structure:

  iaac-talos-flux-cluster/
    clusters/
      dpl/
        flux-system/
          gotk-components.yaml      Flux controllers (generated by flux bootstrap)
          gotk-sync.yaml            GitRepository + Kustomization pointing to dpl path
          infra-source.yaml         GitRepository pointing to platform repo dpl branch
          infra.yaml                Kustomizations for each platform component
          kustomization.yaml        Kustomize resource list
      bm-dev/                       OUR CLUSTER
        flux-system/
          gotk-components.yaml      Flux controllers (auto-generated by Terraform flux module)
          gotk-sync.yaml            GitRepository: iaac-talos-flux-cluster master branch
                                    Kustomization: path ./clusters/bm-dev
          infra-source.yaml         GitRepository "infra":
                                      url: variant-inc/iaac-talos-flux-platform
                                      branch: op-dev
                                    GitRepository "gateway-api-upstream":
                                      url: kubernetes-sigs/gateway-api
                                      tag: v1.4.0
          infra.yaml                16 Kustomizations:
                                      cert-manager         -> ./infrastructure/cert-manager
                                      gateway-api          -> ./config/crd/standard (from gateway-api repo)
                                      istio-namespace      -> ./infrastructure/istio
                                      cert-manager-issuers -> ./infrastructure/cert-manager-issuers
                                        dependsOn: cert-manager, istio-namespace
                                      istio-csr            -> ./infrastructure/istio-csr
                                        dependsOn: cert-manager-issuers
                                      istio-base           -> ./infrastructure/istio/base
                                        dependsOn: istio-csr
                                      istio-istiod         -> ./infrastructure/istio/istiod
                                        dependsOn: istio-base
                                      istio-cni            -> ./infrastructure/istio/cni
                                        dependsOn: istio-istiod
                                      istio-ztunnel        -> ./infrastructure/istio/ztunnel
                                        dependsOn: istio-cni
                                      cilium-lb            -> ./infrastructure/cilium-lb
                                      external-secrets     -> ./infrastructure/external-secrets
                                        dependsOn: cert-manager
                                      external-secrets-config -> ./infrastructure/external-secrets-config
                                        dependsOn: external-secrets
                                      ecr-credentials      -> ./infrastructure/ecr-credentials
                                      keda                 -> ./infrastructure/keda
                                      prometheus           -> ./infrastructure/prometheus
          kustomization.yaml        Resources:
                                      - gotk-components.yaml
                                      - gotk-sync.yaml
                                      - infra-source.yaml
                                      - infra.yaml
      dpl2/                         OLD cluster (app manifests removed)
      dpl2.bak/                     Backup

Flux reconciliation flow:

  1. Terraform flux module bootstraps Flux on the cluster
  2. Flux reads gotk-sync.yaml -> watches iaac-talos-flux-cluster master, path ./clusters/bm-dev
  3. Flux finds kustomization.yaml -> includes infra-source.yaml and infra.yaml
  4. infra-source.yaml creates GitRepository "infra" -> iaac-talos-flux-platform op-dev branch
  5. infra.yaml creates 16 Kustomization resources
  6. Each Kustomization points to a path in the "infra" GitRepository
  7. Flux applies manifests in dependency order

Dependency chain (sequential):

  cert-manager
    -> cert-manager-issuers (+ istio-namespace)
      -> istio-csr
        -> istio-base
          -> istio-istiod
            -> istio-cni
              -> istio-ztunnel

Parallel (no dependencies):

  cilium-lb, gateway-api, ecr-credentials, keda, prometheus

Sequential (chained):

  external-secrets -> external-secrets-config


REPO 3: variant-inc/iaac-talos-flux-platform

Purpose:     Actual Kubernetes manifests for platform infrastructure components
Branch:      op-dev (created from dev, infrastructure copied from dpl2)
Triggered by: Flux CD reconciliation (every 5 minutes from flux-cluster reference)

Directory structure:

  iaac-talos-flux-platform/ (branch: op-dev)
    README.md
    design_doc_magerunner_bare_metal.md
    infrastructure/
      cert-manager/
        namespace.yaml              Namespace: cert-manager
        release.yaml                HelmRelease: cert-manager v1.19.1
                                    Chart: cert-manager from jetstack HelmRepository
                                    Values: CRDs enabled, prometheus enabled, webhook timeout 30s
        repository.yaml             HelmRepository: https://charts.jetstack.io

      cert-manager-issuers/
        issuer.yaml                 ClusterIssuer: istio-ca (self-signed CA for Istio mTLS)
        root-ca-secret.yaml         Job: creates root CA secret for cert-manager

      cilium-lb/
        resources.yaml              CiliumL2AnnouncementPolicy: announces service IPs on L2
                                    CiliumLoadBalancerIPPool: IP pool for LoadBalancer services

      ecr-credentials/
        namespace.yaml              Namespace: ecr-credentials
        cronjob.yaml                CronJob: runs every 6h, calls aws ecr get-login-password
                                    Creates docker-registry secrets in all app namespaces
                                    REQUIRES: IRSA (ServiceAccount with ECR read IAM role)
        rbac.yaml                   ServiceAccount + ClusterRole + ClusterRoleBinding
                                    Allows creating/updating secrets across namespaces

      external-secrets/
        namespace.yaml              Namespace: external-secrets
        helmrelease.yaml            HelmRelease: external-secrets-operator
                                    Chart from external-secrets Helm repo
        kustomization.yaml          Kustomize resource list

      external-secrets-config/
        clustersecretstore.yaml     ClusterSecretStore: points to AWS Secrets Manager
                                    Region: us-east-1 (Playground account)
                                    Auth: uses ServiceAccount (needs IRSA for real auth)
        kustomization.yaml          Kustomize resource list

      istio/
        namespace.yaml              Namespace: istio-system (with ambient label)
        base/
          release.yaml              HelmRelease: istio-base (Istio CRDs)
          repository.yaml           HelmRepository: istio-release.storage.googleapis.com
        istiod/
          release.yaml              HelmRelease: istiod (control plane)
          values.yaml               Values: ambient profile, mesh config, pilot settings
        cni/
          release.yaml              HelmRelease: istio-cni
          values.yaml               Values: ambient mode, CNI plugin config
        ztunnel/
          release.yaml              HelmRelease: ztunnel (L4 proxy for ambient)
          values.yaml               Values: ztunnel config

      istio-csr/
        release.yaml                HelmRelease: cert-manager-istio-csr
                                    Integrates cert-manager with Istio for certificate issuance
        repository.yaml             HelmRepository: charts.jetstack.io
        values.yaml                 Values: issuer ref, certificate settings

      istio-namespace/
        namespace.yaml              Namespace: istio-system (created before Istio components)

      keda/
        namespace.yaml              Namespace: keda
        helmrelease.yaml            HelmRelease: keda (event-driven autoscaling)
        kustomization.yaml          Kustomize resource list

      prometheus/
        namespace.yaml              Namespace: monitoring
        helmrelease.yaml            HelmRelease: kube-prometheus-stack
        kustomization.yaml          Kustomize resource list

    NOT included (removed from dpl2):
      app-namespaces/               Removed - MageRunner creates these
      app-secrets/                  Removed - MageRunner creates these
      pod-identity-webhook/         Removed - needs IRSA first (Phase 3)

How Flux deploys each component:

  1. Flux pulls this repo (op-dev branch) every 5 minutes
  2. Each Kustomization in infra.yaml references a path (e.g., ./infrastructure/cert-manager)
  3. Flux applies all YAML files in that path
  4. For HelmRelease resources:
     - Flux helm-controller reads the HelmRepository reference
     - Downloads the chart from the Helm repo
     - Installs with the specified values
  5. For raw manifests (namespace.yaml, rbac.yaml):
     - Flux applies directly via kubectl

Branches in this repo:
  prod     <- production (default branch, HEAD)
  dev      <- design doc only, no infrastructure
  dpl      <- original platform stack (cert-manager, istio, cilium-lb only)
  dpl2     <- full platform stack (all components including app manifests)
  op-dev   <- OUR BRANCH: full stack minus app manifests and PIW
  qa       <- QA environment
  stage    <- Staging environment


REPO 4: variant-inc/iaac-octopus-config

Purpose:     IaC for Octopus Deploy configuration (Spaces, variable sets, script modules)
Branch:      feature/onprem-space
Triggered by: Octopus pipeline (run_spaces.ps1, run_variables.ps1)

Directory structure:

  iaac-octopus-config/
    deploy/
      config/
        spaces.yaml                 Defines allowed_spaces list + space_vars map
                                    SpaceSpecific variable values looked up by space name
        environments.yaml           Defines: plan, development, qa, staging, production
        vars.yaml                   All 11 DX variable sets:
                                      AWSAccessKeys, AWSAccounts, EKSCluster, Common,
                                      CCloud, MongoDBAtlas, Tags, TFState, AzureAD,
                                      Network, Runner, Cake (deprecated)
                                    Each variable has:
                                      unscoped: default value
                                      scoped: environment-scoped value
                                      type: String, Sensitive, WorkerPool, SpaceSpecific
        common.yaml                 create_common: false, environment: dpl
        lifecycles.yaml             Lifecycle definitions:
                                      feature, feature-manual, feature-plan, feature-external,
                                      release, release-external, release-auto, develop,
                                      release-production, release-production-auto
        worker_pools.yaml           Worker pools:
                                      usxpress-development, qa, staging, production
                                      + onprem-development (NEW)
        feeds.yaml                  NuGet + S3 feed configs
        script_modules.yaml         Script module references

      scripts/
        setup.ps1                   Merges all config/*.yaml -> full_config.yaml
                                    Reads allowed_spaces from spaces.yaml
                                    Sets env vars: S3_BUCKET, OCTOPUS_URL, OCTOPUS_APIKEY
        import_variables.ps1        Variable import helper
        import_spaces.ps1           Space import helper
        onprem/
          configure_onprem_variables.sh   NEW: Sets OnPremise space overrides via Octopus API

      run_spaces.ps1                Main script: loops through allowed_spaces
                                    For each space: renders config, runs tofu plan/apply
                                    Creates: Space, environments, lifecycles, worker pools,
                                    variable sets, script modules

      run_variables.ps1             Main script: loops through allowed_spaces
                                    For each space: renders tfvars from vars.yaml template
                                    Creates all variables in each variable set
                                    SpaceSpecific vars: looks up space_vars[var_name][space_name]

      spaces/
        main.tf                     Creates octopusdeploy_space resource
        modules/
          common/
            main.tf                 Creates environments, lifecycles, worker pools,
                                    variable sets, script modules in each space
            common.tfvars.gotmpl    Go template: renders environments, worker pools,
                                    script modules, variable set names from full_config.yaml
        scripts/
          Bash/
            SetAWScredentials.sh    Worker bootstrap script:
                                    1. Clears existing AWS credentials
                                    2. Reads AWS_ROLE_TO_ASSUME from Octopus variables
                                    3. Creates "deployment" AWS profile that chains:
                                       base (worker IRSA) -> deployment (target role)
                                    4. Sets AWS_PROFILE=deployment
                                    5. If CLUSTER_NAME set: runs aws eks update-kubeconfig
                                    6. Runs aws ecr get-login-password for Helm
                                    7. Unsets AWS_WEB_IDENTITY_TOKEN_FILE
          PowerShell/
            DX__SetupVariables.ps1
            CommonFunctions.ps1
            FluxRenovate.ps1
            MultiAccountConfigurator.ps1
            (+ others)

      variables/
        main.tf                     Creates octopusdeploy_variable for each var in each set
                                    Handles scoped vs unscoped, sensitive, WorkerPool types
        terraform.tfvars.gotmpl     Go template: renders vars.yaml per space
                                    SpaceSpecific: index(space_vars[var_name])[space_name]

Pipeline flow:

  1. setup.ps1 runs:
     - yq merges all config/*.yaml files into full_config.yaml
     - Reads allowed_spaces: [Default, DevOps, OnPremise]
     - Sets OCTOPUS_URL, OCTOPUS_APIKEY env vars

  2. run_spaces.ps1 runs:
     - For each space in allowed_spaces:
       - Renders backend config (S3 key: octopus/iaac/spaces/{SpaceName}.json)
       - tofu init + plan + apply
       - Creates: Space, environments, lifecycles, worker pools, variable sets, script modules

  3. run_variables.ps1 runs:
     - Gets all spaces from Octopus API
     - Filters to allowed_spaces
     - For each space:
       - Renders terraform.tfvars.gotmpl using full_config.yaml + space context
       - SpaceSpecific variables get per-space values from space_vars
       - tofu init + plan + apply
       - Creates all variables in all variable sets

What we configured:

  spaces.yaml:
    allowed_spaces: added "OnPremise"
    space_vars:
      AWS_IAM_PREFIX.OnPremise = "op-usxpress-dev-"
      aws_resource_name_prefix.OnPremise = "op-usxpress-dev-"

  worker_pools.yaml:
    Added "onprem-development"

  configure_onprem_variables.sh (new):
    Bash script that sets OnPremise space variable overrides via Octopus REST API
    Variables set:
      DX__EKSCluster: CLUSTER_NAME=op-usxpress-dev, CLUSTER_REGION=us-east-1,
                      TF_VAR_use_eks_api=false
      DX__AWSAccounts: AWS_ACCOUNT_dev=786352483360, AWS_REGION_dev=us-east-1
      DX__AWSAccessKeys: AWS_DEFAULT_REGION=us-east-1,
                         AWS_ROLE_TO_ASSUME=arn:aws:iam::786352483360:role/octopus-usxpress,
                         DOMAIN=dev.usxpress.io
      DX__TFState: S3_BUCKET=op-usxpress-dev-tfstate
      DX__Tags: owner=cloud-platform, purpose=on-prem-dev, team=cloudops


HOW ALL REPOS CONNECT

  iaac-octopus-config                    iaac-talos
  (Octopus config as code)               (Cluster provisioning Terraform)
         |                                       |
         | Creates Spaces,                       | GHA builds package
         | Variable Sets,                        | on push to any branch
         | Script Modules                        |
         v                                       v
  Octopus Deploy Server                  Octopus Deploy Server
  (DevOps Space)                         (DevOps Space, iaac-talos project)
         |                                       |
         | SetAWScredentials.sh                  | deploy.ps1 runs on worker
         | runs before every step                |
         v                                       v
  Octopus Worker                         Terraform Apply
  (EKS pod in cloud dev)                        |
                                                |
         +--------------------------------------+
         |
         | Creates VMs + Bootstraps K8s + Installs Cilium + Bootstraps Flux
         |
         v
  Flux CD on op-usxpress-dev cluster
         |
         | Reads gotk-sync.yaml
         | (auto-generated by Terraform flux module)
         v
  iaac-talos-flux-cluster (master)
  clusters/bm-dev/flux-system/
         |
         | infra-source.yaml points to platform repo
         | infra.yaml defines 16 kustomizations
         v
  iaac-talos-flux-platform (op-dev)
  infrastructure/
         |
         | Flux applies each component in dependency order
         v
  Platform Stack on Cluster:
    cert-manager -> cert-manager-issuers -> istio-csr
    -> istio-base -> istiod -> istio-cni -> istio-ztunnel
    + cilium-lb, gateway-api, external-secrets, keda, prometheus, ecr-credentials


CLUSTER DETAILS

  Cluster Name:   op-usxpress-dev
  Kubernetes:     v1.32.0
  Talos:          v1.11.1
  API Server:     https://10.10.82.50:6443
  VIP:            10.10.82.50
  Nodes:          3 CP + 5 Worker = 8 total
  vSphere:        D1-Datacenter, KubernetesD1/TalosD1/op-usxpress-dev
  Datastore:      USXD1NTXPROD-SC1
  Network:        10.10.82 (vLAN 82) Prod
  Content Library: dev-cluster (talos-v1.11.1 OVA)

  Control Plane:  talos-cp-op-dev-1 (10.10.82.21)
                  talos-cp-op-dev-2 (10.10.82.139)
                  talos-cp-op-dev-3 (10.10.82.22)

  Workers:        talos-wk-op-dev-1 (10.10.82.28)
                  talos-wk-op-dev-2 (10.10.82.26)
                  talos-wk-op-dev-3 (10.10.82.27)
                  talos-wk-op-dev-4 (10.10.82.23)
                  talos-wk-op-dev-5 (10.10.82.138)

  Platform Components (15/16 deployed):
    cert-manager           Running    TLS certificate management
    cert-manager-issuers   Running    CA issuers for Istio mTLS
    cilium-lb              Running    L2 LoadBalancer for bare-metal
    ecr-credentials        Failed     Needs IRSA (Phase 3)
    external-secrets       Running    AWS Secrets Manager integration
    external-secrets-config Running   ClusterSecretStore configuration
    gateway-api            Running    Gateway API CRDs
    istio-base             Running    Istio CRDs
    istio-cni              Running    Istio CNI plugin (ambient mode)
    istio-csr              Running    Istio certificate signing via cert-manager
    istio-istiod           Running    Istio control plane
    istio-ztunnel          Running    Istio L4 proxy (ambient mode)
    keda                   Running    Event-driven autoscaling
    prometheus             Running    Monitoring stack
    pod-identity-webhook   Deferred   Needs IRSA (Phase 3)
