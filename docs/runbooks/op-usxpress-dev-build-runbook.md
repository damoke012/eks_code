op-usxpress-dev Cluster Build Runbook

Author:     Dare Oke
Date:       March 25, 2026
Purpose:    Document all issues encountered during initial build and fixes applied.
            Use this to tear down and rebuild seamlessly via GHA/Octopus pipeline.


ISSUES ENCOUNTERED AND FIXES APPLIED

Issue 1: Octopus development environment not available in lifecycle
  Problem:  The feature channel lifecycle (iaac-feature-manual) only had "dpl" as a
            deployment target. "development" was not available.
  Fix:      Updated lifecycle Lifecycles-1502 via Octopus API to add "development" as
            the first phase (non-optional), moved "dpl" to second phase (optional).
  Command:  Octopus API PUT /api/Spaces-2/lifecycles/Lifecycles-1502
  Status:   Fixed. New releases now show "development" in deploy dropdown.

Issue 2: GitHub token expired for Flux bootstrap
  Problem:  The TF_VAR_github_token PAT (talos-flux-dev) expired on March 13, 2026.
            Flux module couldn't clone iaac-talos-flux-cluster repo.
  Fix:      Generated new PAT at github.com/settings/tokens, authorized for variant-inc
            SSO, updated in Octopus project variables.
  Note:     Token needs SSO authorization after creation (Configure SSO -> Authorize).
  Status:   Fixed.

Issue 3: Worker assumed Playground role but couldn't access S3
  Problem:  The SetAWScredentials.sh bootstrap script reads AWS_ROLE_TO_ASSUME and
            chains to that role. When set to arn:aws:iam::786352483360:role/octopus-usxpress,
            the Playground role couldn't access ANY S3 bucket (not even in its own account).
            Confirmed via multiple tests: fresh STS sessions, explicit bucket policies,
            new dedicated buckets — all returned 403 Forbidden on HeadObject.
  Root Cause: Organization SCP or the octopus-usxpress role's inline S3 policy
            (s3:getr* doesn't match s3:GetObject) combined with cross-account credential
            chain restrictions.
  Fix:      Removed AWS_ROLE_TO_ASSUME override for development scope. The cluster
            provisioning uses the cloud dev worker's native IAM role
            (700736442855:octopus-usxpress) which has full S3 access.
            This matches how dpl2 was originally provisioned.
  Design Decision: Cluster provisioning (iaac-talos) uses cloud dev worker/role.
            IRSA setup done separately via local Terraform with Playground credentials.
            MageRunner app deployments will use on-prem workers (future).
  Status:   Fixed.

Issue 4: CLUSTER_NAME caused SetAWScredentials bootstrap to fail
  Problem:  The bootstrap script reads CLUSTER_NAME and runs
            "aws eks update-kubeconfig --name $CLUSTER_NAME". When deploying to
            development environment, CLUSTER_NAME resolved to "usxpress-dev" (from
            unscoped default), which doesn't exist as an EKS cluster in Playground.
            Error: ResourceNotFoundException - No cluster found for name: usxpress-dev.
  Fix:      Added empty CLUSTER_NAME project variable scoped to development. The
            bootstrap script checks "if [[ -n ${cluster_name:-} ]]" and skips
            EKS kubeconfig when empty.
  Note:     This was removed when we stopped using the Playground role.
            Not needed when using cloud dev role (CLUSTER_NAME resolves to usxpress-dev
            which exists in cloud dev account).
  Status:   Fixed (no longer needed with current approach).

Issue 5: Disk size mismatch on destroy
  Problem:  dpl2 cluster was created with 50GB disks but project variable
            TF_VAR_disk_size_gb defaulted to 20. vSphere refused to shrink disks
            during destroy plan: "virtual disks cannot be shrunk (old: 50 new: 20)".
  Fix:      Set TF_VAR_disk_size_gb to 50 (unscoped default).
  Status:   Fixed permanently.

Issue 6: Partial deployment left orphaned VMs
  Problem:  First deployment attempt created VMs but IRSA module failed. TF state
            was in the cloud dev account's S3 bucket (lazy-tf-state-65v583i6my68y6x9)
            not the Playground bucket. Octopus couldn't destroy because the state
            was in a different bucket than expected.
  Fix:      Used local Terraform from WSL2 to init with the correct backend
            (bucket=lazy-tf-state-65v583i6my68y6x9, key=iaac/talos/op-usxpress-dev.tfstate,
            region=us-east-2) and ran terraform destroy -auto-approve.
  Status:   Fixed. VMs destroyed.

Issue 7: Quay.io CDN 503 for cert-manager images
  Problem:  cert-manager pods couldn't pull images from quay.io. CDN returned
            503 Service Unavailable. Temporary quay.io infrastructure issue.
  Fix:      Waited for quay.io CDN to recover. Attempted Docker Hub fallback
            but jetstack images don't exist on Docker Hub. Deleted helm release
            and let Flux recreate after quay.io recovered.
  Status:   Resolved (transient).

Issue 8: Duplicate YAML key in cert-manager release.yaml
  Problem:  When adding Docker Hub image overrides, the "webhook" key was
            defined twice in the helm release values. Flux kustomize build failed:
            "mapping key webhook already defined at line 22".
  Fix:      Merged webhook values under single key.
  Status:   Fixed.

Issue 9: Missing newline between infra.yaml sections
  Problem:  When appending new kustomizations to infra.yaml via "cat >>",
            the last line of cilium-lb ("wait: true") merged with the "---"
            separator: "wait: true---". Caused kustomize build failure:
            "mapping key apiVersion already defined at line 1".
  Fix:      sed -i 's/  wait: true---/  wait: true\n---/'
  Status:   Fixed.

Issue 10: Istiod PEM decode error
  Problem:  Istiod pod started before cert-manager was ready. Could not load
            CA bundle: "could not decode pem". Port 15012 refused connections,
            ztunnel pods couldn't connect.
  Fix:      kubectl rollout restart deployment istiod -n istio-system
            After restart, istiod picked up valid certs from cert-manager/istio-csr.
  Status:   Fixed.

Issue 11: ecr-credentials init job failed
  Problem:  ECR credentials sync job needs IRSA to authenticate to ECR.
            IRSA is not set up yet (disabled for initial provisioning).
  Fix:      Expected. Will be fixed when IRSA is configured (Phase 3).
  Status:   Known, deferred.

Issue 12: VIP collision with DHCP-assigned node IP
  Problem:  Control plane VIP 10.10.82.30 was assigned by DHCP to worker node
            talos-wk-op-dev-4 as its primary IP. Talos VIP and node IP conflicted.
            API server unreachable on VIP, Flux bootstrap failed after 60 retries.
  Fix:      Changed VIP to 10.10.82.50 (less likely to collide with DHCP pool).
            Long-term: reserve VIP in DHCP server with network team.
  Status:   Fixed. Rebuild with .50 succeeded.

Issue 13: Flux wait_for_cluster timeout too short
  Problem:  Default 20 retries x 10 seconds (200s) not enough for VIP to come up.
            Even 60 retries (600s) failed due to VIP collision.
  Fix:      Increased default max_retries to 60 in modules/flux/variables.tf.
            Added retryInterval=2m to istiod and ztunnel kustomizations so Flux
            auto-retries instead of requiring manual kubectl restart.
  Status:   Fixed.

Issue 14: Accidentally destroyed dev-cluster
  Problem:  When deploying to "development" environment, the Octopus release 0.0.9
            (with TFDestroy=true) was deployed to development instead of dpl.
            This destroyed the cloud dev-cluster VMs (IPs 10.10.82.187, 10.10.82.25).
  Fix:      The dev-cluster was unused/orphaned. No impact.
  Lesson:   Always verify which environment a destroy targets before deploying.
  Status:   No action needed.


CLEAN REBUILD PROCEDURE (FOR TOMORROW)

Prerequisites:
  - WSL2 with AWS profiles configured (usx-dev, playground)
  - Octopus API key
  - GitHub PAT with SSO authorization for variant-inc

Step 1: Verify variables are correct
  All development-scoped variables in iaac-talos project should be set:
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
    TF_VAR_disk_size_gb               = 50 (unscoped)
    TfApply                           = true (unscoped)
    TfDestroy                         = false (unscoped)

  DO NOT set these for development scope (use unscoped defaults):
    AWS_ROLE_TO_ASSUME  (uses cloud dev octopus-usxpress)
    S3_BUCKET           (uses cloud dev bucket)
    AWS_DEFAULT_REGION  (uses us-east-2)
    CLUSTER_NAME        (uses usxpress-dev for EKS kubeconfig)

Step 2: Destroy existing cluster (if needed)
  Option A: Via Octopus UI
    - Set TfDestroy=true, TfApply=false in project variables
    - Create release, deploy to development
    - After success, reset TfDestroy=false, TfApply=true

  Option B: Via WSL2
    cd ~/iaac-talos/deploy/terraform
    AWS_PROFILE=usx-dev terraform init \
      -backend-config="bucket=lazy-tf-state-65v583i6my68y6x9" \
      -backend-config="key=iaac/talos/op-usxpress-dev.tfstate" \
      -backend-config="region=us-east-2" \
      -backend-config="encrypt=true" -reconfigure
    AWS_PROFILE=usx-dev terraform destroy -auto-approve

Step 3: Provision cluster via GHA/Octopus
  - Push to feature/op-usxpress-dev branch of iaac-talos (or any change)
  - GHA builds package, creates Octopus release automatically
  - Deploy release to "development" environment from Octopus UI
  - Takes ~5 minutes for VMs + Talos + Cilium + Flux bootstrap

Step 4: Verify cluster
  export KUBECONFIG=~/.kube/op-usxpress-dev.yaml
  kubectl get nodes  (expect 8 nodes, all Ready)

Step 5: Add platform infrastructure source
  Already done in iaac-talos-flux-cluster master branch:
    clusters/bm-dev/flux-system/infra-source.yaml  -> points to op-dev branch
    clusters/bm-dev/flux-system/infra.yaml         -> 16 kustomizations

  Flux will automatically deploy all platform components after cluster bootstrap.
  Wait ~5-10 minutes for the full dependency chain:
    cert-manager -> cert-manager-issuers -> istio-csr -> istio (base/istiod/cni/ztunnel)

Step 6: Verify platform stack
  kubectl get kustomizations -A  (expect all True except external-secrets-config)
  kubectl get pods -A            (expect all Running/Completed)

  If istio-ztunnel shows Failed, wait 2 minutes - retryInterval is configured
  and Flux will auto-retry. No manual intervention needed.

  14/15 kustomizations should be True:
    cert-manager, cert-manager-issuers, cilium-lb, external-secrets,
    flux-system, gateway-api, istio-base, istio-cni, istio-csr,
    istio-istiod, istio-namespace, istio-ztunnel, keda, prometheus
  Expected failure: external-secrets-config (needs IRSA)

Step 7: Set up IRSA (separate step, Phase 3)
  cd ~/iaac-talos/deploy/terraform
  AWS_PROFILE=playground terraform apply -target=module.irsa -auto-approve
  Then enable Pod Identity Webhook in Flux


SEAMLESS REBUILD TEST RESULTS (March 25, 2026)

  VIP changed from 10.10.82.30 to 10.10.82.50 (DHCP collision fix)
  Flux wait_for_cluster retries increased to 60 (10 min)
  Flux retryInterval added to istiod and ztunnel (auto-retry every 2 min)

  Tear down:        ~3 min via Octopus UI (TfDestroy=true, deploy to development)
  Rebuild:          ~7 min via Octopus UI (TfApply=true, deploy to development)
  Platform stack:   ~15 min auto-deployed via Flux (no manual intervention)
  Total:            ~25 min end-to-end
  Manual fixes:     0 (istiod/ztunnel auto-retry now configured)
  Components:       14/15 True (external-secrets-config expected - needs IRSA)


REPOS AND BRANCHES

iaac-talos
  Branch: feature/op-usxpress-dev
  Changes: deploy.ps1 with assume-role support (skip if same account)
  GHA: Builds package on push, creates Octopus release

iaac-talos-flux-cluster
  Branch: master
  Path: clusters/bm-dev/flux-system/
  Files: gotk-components.yaml, gotk-sync.yaml, infra-source.yaml, infra.yaml, kustomization.yaml

iaac-talos-flux-platform
  Branch: op-dev
  Path: infrastructure/
  Components: cert-manager, cert-manager-issuers, cilium-lb, ecr-credentials,
              external-secrets, external-secrets-config, istio (5 sub-components),
              keda, prometheus

iaac-octopus-config
  Branch: feature/onprem-space
  Changes: spaces.yaml (OnPremise added), worker_pools.yaml (onprem-development),
           configure_onprem_variables.sh


OCTOPUS PROJECT VARIABLES REFERENCE

Project: iaac-talos (Projects-8283)
Space: DevOps (Spaces-2)
Channel: feature (Channels-9403)
Lifecycle: iaac-feature-manual (Lifecycles-1502)
  Phase 1: development (Environments-1)
  Phase 2: dpl (Environments-430, optional)

S3 Backend:
  Bucket: lazy-tf-state-65v583i6my68y6x9 (cloud dev account 700736442855)
  Key: iaac/talos/op-usxpress-dev.tfstate
  Region: us-east-2

Worker: octopusworker-2.dev.usxpress.io (cloud dev EKS)
IAM Role: 700736442855:octopus-usxpress (worker's ambient role)


CLUSTER DETAILS

Cluster Name:   op-usxpress-dev
Kubernetes:     v1.32.0
Talos:          v1.11.1
API Server:     https://10.10.82.50:6443
VIP:            10.10.82.50
Nodes:          3 CP (talos-cp-op-dev-{1,2,3}) + 5 Worker (talos-wk-op-dev-{1..5})
vSphere Folder: KubernetesD1/TalosD1/op-usxpress-dev
Datastore:      USXD1NTXPROD-SC1
Network:        10.10.82 (vLAN 82) Prod
Content Library: dev-cluster

Control Plane IPs: 10.10.82.21, 10.10.82.139, 10.10.82.22
Worker IPs:        10.10.82.28, 10.10.82.26, 10.10.82.27, 10.10.82.23, 10.10.82.138
