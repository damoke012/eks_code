# Append to: iaac-talos/deploy/terraform/modules/irsa/main.tf
#
# Source IAM role for the on-prem cert-manager deployment. Same chain-into-
# iaac-route53-zone pattern as `extd-usxpress-io-${cluster_name}` — the
# wildcard trust on `iaac-route53-zone` already accepts `cert-manager-*` from
# the USXpress AWS Org (verified 2026-05-18, see memory
# onprem_route53_wildcard_trust_discovery). NO network-team patch required.
#
# Permissions: ONLY sts:AssumeRole on the cross-account Route53 zone role.
# All ACME DNS-01 challenge writes happen via the assumed role.

resource "aws_iam_role" "cert_manager" {
  # Name MUST start with `cert-manager-` to match the wildcard trust on
  # iaac-route53-zone:
  #   arn:aws:iam::*:role/cert-manager-*
  name = "cert-manager-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.irsa.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # SA namespace + name MUST match the Helm chart's ServiceAccount.
          "${local.oidc_issuer_hostpath}:sub" = "system:serviceaccount:cert-manager:cert-manager"
          "${local.oidc_issuer_hostpath}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Cluster = var.cluster_name
    Purpose = "cert-manager source role (chains into iaac-route53-zone for DNS-01)"
  }
}

# The ONLY permission this role has is to chain into the network-team-owned
# Route53 zone role. iaac-route53-zone holds Route53 write permission on the
# usxpress.io zones.
resource "aws_iam_role_policy" "cert_manager_assume_zone" {
  name = "assume-iaac-route53-zone"
  role = aws_iam_role.cert_manager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::155768531003:role/iaac-route53-zone"
    }]
  })
}
