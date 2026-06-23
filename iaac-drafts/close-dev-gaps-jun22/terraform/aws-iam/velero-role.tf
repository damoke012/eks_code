# velero-role.tf
#
# IRSA + S3 wiring for Velero on the op-usxpress-dev cluster.
#
# Companion to:
#   variant-inc/iaac-talos-flux-platform - Velero HelmRelease at infrastructure/velero
#
# Trust policy is scoped to the chart's default SA:
#   system:serviceaccount:velero:velero
#
# Resources:
#   - velero-<cluster_name> S3 bucket (versioning + 30d lifecycle on backups/)
#   - <cluster_name>-velero IAM role with bucket-scoped S3 perms
#
# Velero is configured to use Kopia file-system backup mode (not CSI volume
# snapshots), so EC2 snapshot perms are intentionally not granted. If we
# later opt into CSI snapshots, append ec2:CreateSnapshot etc. here.

# --- S3 bucket: Velero backup target ---
resource "aws_s3_bucket" "velero" {
  bucket = "velero-${var.cluster_name}"

  tags = {
    Cluster = var.cluster_name
    Purpose = "Velero backup target - PVC + namespace state"
    Owner   = "on-prem-platform"
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket = aws_s3_bucket.velero.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }

    expiration {
      days = 30
    }
  }
}

# --- IAM role: IRSA for velero SA ---
resource "aws_iam_role" "velero" {
  name        = "${var.cluster_name}-velero"
  description = "IRSA role for Velero on ${var.cluster_name}. Scoped to velero ns SA and velero-* bucket."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.irsa.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_hostpath}:sub" = "system:serviceaccount:velero:velero"
          "${local.oidc_issuer_hostpath}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Cluster = var.cluster_name
    Purpose = "Velero backup IRSA"
    Owner   = "on-prem-platform"
  }
}

# Inline policy: bucket-scoped S3 access for Velero (Kopia mode)
resource "aws_iam_role_policy" "velero_s3" {
  name = "s3-velero-bucket"
  role = aws_iam_role.velero.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = "${aws_s3_bucket.velero.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.velero.arn
      }
    ]
  })
}
