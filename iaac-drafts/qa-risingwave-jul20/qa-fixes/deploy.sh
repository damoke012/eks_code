#!/usr/bin/env bash
# deploy.sh — Octopus runs this to apply the RisingWave Terraform.
#
# SCOPE: TERRAFORM ONLY.
#
# Manifests are reconciled by Flux from manifests/<environment>/, wired via
# iaac-talos-flux-cluster. This script must never run kubectl.
#
# What the previous version did wrong (none of it ever worked on-prem):
#   * `aws eks update-kubeconfig --name <cluster>` — op-usxpress-{dev,qa} are
#     on-prem Talos clusters. There is no EKS cluster by that name.
#   * `kubectl apply --server-side -k` — imperative; Flux owns the manifests.
#   * `-var="environment=" -var="aws_region="` — neither variable is declared in
#     variables.tf, so Terraform errors on undeclared vars. This failed for dev
#     too, which is consistent with the RisingWave Terraform never having been
#     applied (the dev state bucket contains no risingwave state, and dev's IAM
#     role was created by hand).
#   * bare `terraform init` — resolved to the backend hardcoded in main.tf, so
#     every environment shared one backend definition.
#   * `-var-file` was never passed, so <environment>.tfvars was ignored entirely.
#
# State separation is by BACKEND KEY (backend-<env>.hcl), not by workspace.
# There is no existing state to migrate.
set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:?ENVIRONMENT must be set, e.g. op-usxpress-qa}"

cd "$(dirname "$0")/../terraform"

# op-usxpress-qa -> backend-qa.hcl ; op-usxpress-dev -> backend-dev.hcl
BACKEND_CFG="backend-${ENVIRONMENT##*-}.hcl"
VAR_FILE="${ENVIRONMENT}.tfvars"

echo "==> [deploy.sh] Environment : ${ENVIRONMENT}"
echo "==> [deploy.sh] Backend     : ${BACKEND_CFG}"
echo "==> [deploy.sh] Var file    : ${VAR_FILE}"

# Fail loudly rather than silently falling back to another environment's state.
[[ -f "${BACKEND_CFG}" ]] || { echo "ERROR: missing ${BACKEND_CFG}" >&2; exit 1; }
[[ -f "${VAR_FILE}"    ]] || { echo "ERROR: missing ${VAR_FILE}"    >&2; exit 1; }

terraform init -input=false -reconfigure -backend-config="${BACKEND_CFG}"
terraform validate
terraform apply -input=false -auto-approve -var-file="${VAR_FILE}"

echo ""
echo "==> [deploy.sh] Terraform apply complete for ${ENVIRONMENT}."
echo "==> Manifests are reconciled by Flux — nothing further to do here."
