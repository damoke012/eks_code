variable "octopus_api_key" {
  description = "Octopus Deploy admin API key. Rotate fresh per session; never commit."
  type        = string
  sensitive   = true
}

variable "source_cluster_kubeconfig_secret_arn" {
  description = "AWS SM ARN of the secret holding the cloud EKS kubeconfig (used to pull the reader SA token)."
  type        = string
  default     = "arn:aws:secretsmanager:us-east-1:786352483360:secret:cloud-eks-bootstrap-kubeconfig-XXXX"
}

variable "source_cluster_reader_sa_namespace" {
  description = "Namespace on the source cloud EKS where the reader service account lives."
  type        = string
  default     = "external-secrets"
}

variable "source_cluster_reader_sa_name" {
  description = "Name of the reader service account on the source cloud EKS."
  type        = string
  default     = "cloud-eks-reader"
}

variable "target_environment_name" {
  description = "Octopus environment name for the on-prem cluster target."
  type        = string
  default     = "op-usxpress-dev"
}

variable "onprem_space_name" {
  description = "Name of the OnPremise Octopus space."
  type        = string
  default     = "OnPremise"
}
