# Append to: iaac-talos/deploy/terraform/modules/irsa/main.tf
#
# Source IAM role for the on-prem external-dns deployment. Mirrors cloud's
# `extd-usxpress-io` role pattern, but with op-usxpress-dev's CloudFront-fronted
# OIDC issuer as the trust federation.
#
# Permissions: ONLY sts:AssumeRole on the cross-account Route53 zone role in
# account 155768531003 (Infrastructure-Networking). All Route53 + DynamoDB
# writes happen via the assumed role; the source role itself touches nothing.

resource "aws_iam_role" "extd_usxpress_io" {
  # Name MUST start with `extd-usxpress-io-` to match the existing wildcard
  # trust pattern on `iaac-route53-zone` in account 155768531003:
  #   arn:aws:iam::*:role/extd-usxpress-io-*
  # Verified 2026-05-18 by inspecting iaac-route53-zone's trust policy. With
  # this naming, NO additional trust patch is required from the network team.
  name = "extd-usxpress-io-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.irsa.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_hostpath}:sub" = "system:serviceaccount:external-dns:extd-usxpress-io"
          "${local.oidc_issuer_hostpath}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Cluster = var.cluster_name
    Purpose = "external-dns source role (chains into iaac-route53-zone)"
  }
}

# The ONLY permission this role has is to chain into the network-team-owned
# Route53 zone role. Trust-side change (on 155768531003) is required and
# documented in iaac-route53-zone-trust-patch.md.
resource "aws_iam_role_policy" "extd_usxpress_io_assume" {
  name = "assume-iaac-route53-zone"
  role = aws_iam_role.extd_usxpress_io.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::155768531003:role/iaac-route53-zone"
    }]
  })
}
