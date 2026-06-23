# etcd-backup-role.tf
#
# IRSA + S3 wiring for the etcd snapshot CronJob on op-usxpress-dev.
#
# Companion to:
#   variant-inc/iaac-talos-flux-platform - etcd-backup CronJob at infrastructure/etcd-backup
#
# Trust policy is scoped to the SA the CronJob runs as:
#   system:serviceaccount:etcd-backup:etcd-backup
#
# Resources:
#   - etcd-snapshots-<cluster_name> S3 bucket (versioning + 30d lifecycle)
#   - <cluster_name>-etcd-backup IAM role with write-only S3 perms
#
# The CronJob runs `talosctl etcd snapshot` hourly at :17 and uploads the
# resulting snapshot.db to S3. The talosconfig is pulled from AWS SM via
# ExternalSecret (the etcd-backup IRSA does NOT have secretsmanager perms;
# ExternalSecrets Operator runs as its own SA with its own role).

# --- S3 bucket: etcd snapshot target ---
resource "aws_s3_bucket" "etcd_snapshots" {
  bucket = "etcd-snapshots-${var.cluster_name}"

  tags = {
    Cluster = var.cluster_name
    Purpose = "Talos etcd snapshot target - hourly CronJob"
    Owner   = "on-prem-platform"
  }
}

resource "aws_s3_bucket_public_access_block" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  rule {
    id     = "30-day-retention"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}

# --- IAM role: IRSA for etcd-backup SA ---
resource "aws_iam_role" "etcd_backup" {
  name        = "${var.cluster_name}-etcd-backup"
  description = "IRSA role for etcd snapshot CronJob on ${var.cluster_name}. Scoped to etcd-backup ns SA and etcd-snapshots-* bucket."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.irsa.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_hostpath}:sub" = "system:serviceaccount:etcd-backup:etcd-backup"
          "${local.oidc_issuer_hostpath}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Cluster = var.cluster_name
    Purpose = "etcd snapshot IRSA"
    Owner   = "on-prem-platform"
  }
}

# Inline policy: write-only S3 access for snapshot uploads
resource "aws_iam_role_policy" "etcd_backup_s3" {
  name = "s3-etcd-snapshots-bucket"
  role = aws_iam_role.etcd_backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = "${aws_s3_bucket.etcd_snapshots.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.etcd_snapshots.arn
      }
    ]
  })
}
