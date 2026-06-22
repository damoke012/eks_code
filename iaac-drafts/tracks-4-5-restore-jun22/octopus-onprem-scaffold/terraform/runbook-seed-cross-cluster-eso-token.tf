# Runbook: Seed Cross-Cluster ESO Token
#
# Fetches a Kubernetes ServiceAccount token + CA cert from the SOURCE cloud EKS
# cluster (via its kubeconfig stored in AWS SM), then writes them as a Secret
# named 'cloud-eks-reader-token' in the 'external-secrets' namespace of the
# TARGET on-prem cluster.
#
# The ExternalSecrets Operator's `cloud-eks` ClusterSecretStore points at this
# Secret. Once seeded, the CSS becomes Ready and downstream ExternalSecrets
# auto-sync.

resource "octopusdeploy_runbook" "seed_cross_cluster_eso_token" {
  name        = "Seed Cross-Cluster ESO Token"
  description = <<-DESC
    Bridges the cloud EKS service account credentials into the on-prem cluster's
    external-secrets namespace. Run ONCE per cluster after initial Flux bootstrap.

    Pre-reqs:
      1. Source cloud EKS kubeconfig stored in AWS SM (variable: source_cluster_kubeconfig_secret_arn)
      2. Reader ServiceAccount exists on source cluster (e.g., external-secrets/cloud-eks-reader)
      3. Target Octopus environment configured + reachable
  DESC
  project_id              = octopusdeploy_project.onprem_platform_bootstrap.id
  multi_tenancy_mode      = "Untenanted"
  default_guided_failure_mode = "EnvironmentDefault"
  force_package_download  = false
  environment_scope       = "Specified"
  environments            = [octopusdeploy_environment.target.id]
  retention_policy {
    quantity_to_keep    = 5
    should_keep_forever = false
  }
}

resource "octopusdeploy_runbook_process" "seed_cross_cluster_eso_token" {
  runbook_id = octopusdeploy_runbook.seed_cross_cluster_eso_token.id

  step {
    condition           = "Success"
    name                = "Pull source kubeconfig + write cloud-eks-reader-token"
    package_requirement = "LetOctopusDecide"
    start_trigger       = "StartAfterPrevious"

    run_script_action {
      script_syntax = "PowerShell"
      script_body   = file("${path.module}/../runbook-scripts/seed-cross-cluster-eso-token.ps1")
      properties = {
        "Octopus.Action.RunOnServer" = "true"
      }
      environments = [octopusdeploy_environment.target.id]
      worker_pool_id = data.octopusdeploy_worker_pools.default.worker_pools[0].id
    }
  }
}

data "octopusdeploy_worker_pools" "default" {
  ids          = []
  partial_name = "OnPrem"   # must match the on-prem worker pool created by INFRA-1485 series
  skip         = 0
  take         = 1
}
