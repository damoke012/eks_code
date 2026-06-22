# OnPremise Octopus space + environment + project for on-prem bootstrap automation.
#
# This is the IaC home for any one-time-per-cluster manual seed operation that
# can't be expressed via the cluster's own Flux Kustomizations (e.g., the
# cross-cluster ESO token bridge — INFRA-1535).

resource "octopusdeploy_space" "onprem" {
  name        = var.onprem_space_name
  description = "On-prem cluster bootstrap + runbooks managed by the on-prem team."
  is_default  = false
  space_managers_team_members = []   # set via UI to your platform-team account(s) after first apply
  space_managers_teams        = ["teams-everyone"]
}

resource "octopusdeploy_environment" "target" {
  name        = var.target_environment_name
  description = "On-prem dev cluster target for OnPremise space runbooks."
  space_id    = octopusdeploy_space.onprem.id
  use_guided_failure = false
  allow_dynamic_infrastructure = true
}

resource "octopusdeploy_project_group" "bootstrap" {
  name        = "Bootstrap"
  description = "One-time-per-cluster seed runbooks."
  space_id    = octopusdeploy_space.onprem.id
}

resource "octopusdeploy_project" "onprem_platform_bootstrap" {
  name             = "onprem-platform-bootstrap"
  description      = "Per-cluster bootstrap runbooks (Seed Cross-Cluster ESO Token, etc.)."
  space_id         = octopusdeploy_space.onprem.id
  project_group_id = octopusdeploy_project_group.bootstrap.id
  lifecycle_id     = octopusdeploy_lifecycle.onprem_default.id
  default_to_skip_if_already_installed = true
  default_guided_failure_mode          = "EnvironmentDefault"
  is_disabled                          = false
}

resource "octopusdeploy_lifecycle" "onprem_default" {
  name        = "On-Prem Default"
  description = "Default lifecycle for on-prem runbooks (single phase, target env)."
  space_id    = octopusdeploy_space.onprem.id
  phase {
    name                                  = var.target_environment_name
    optional_deployment_targets           = [octopusdeploy_environment.target.id]
    minimum_environments_before_promotion = 1
    is_optional_phase                     = false
  }
}
