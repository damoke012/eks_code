# IAM roles + S3 buckets for backup infrastructure (INFRA-1540 + INFRA-1541).
#
# Adds to iaac-talos repo on feature/op-usxpress-dev branch.
# Two new IRSA-bound roles and two S3 buckets:
#   1. velero      -> velero-op-usxpress-dev bucket (PVC + namespace backups)
#   2. etcd-backup -> etcd-snapshots-op-usxpress-dev (hourly etcd snapshots)
#
# Both bind to OIDC issuer d3a7wcnazdrd6p.cloudfront.net.

locals {
  cluster_name = "op-usxpress-dev"
  oidc_issuer  = "d3a7wcnazdrd6p.cloudfront.net"   # from `kubectl get --raw /.well-known/openid-configuration`
  aws_account  = "700736442855"                      # USX-Development
  region       = "us-east-2"
}

# === S3 buckets ===

resource "aws_s3_bucket" "velero" {
  bucket = "velero-${local.cluster_name}"
  tags = {
    "app.kubernetes.io/part-of"  = "backup"
    "app.kubernetes.io/component" = "velero"
    "managed-by"                  = "iaac-talos"
  }
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
    expiration {
      days = 30
    }
    filter {
      prefix = "backups/"
    }
  }
}

resource "aws_s3_bucket" "etcd_snapshots" {
  bucket = "etcd-snapshots-${local.cluster_name}"
  tags = {
    "app.kubernetes.io/part-of"   = "backup"
    "app.kubernetes.io/component" = "etcd-backup"
    "managed-by"                  = "iaac-talos"
  }
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

# === IAM trust policy template ===

data "aws_iam_policy_document" "irsa_trust" {
  for_each = {
    velero      = "system:serviceaccount:velero:velero"
    etcd-backup = "system:serviceaccount:etcd-backup:etcd-backup"
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${local.aws_account}:oidc-provider/${local.oidc_issuer}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = [each.value]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# === Velero role ===

resource "aws_iam_role" "velero" {
  name               = "${local.cluster_name}-velero"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["velero"].json
  tags = {
    "app.kubernetes.io/part-of"   = "backup"
    "app.kubernetes.io/component" = "velero"
  }
}

data "aws_iam_policy_document" "velero" {
  statement {
    sid = "VeleroS3"
    actions = [
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.velero.arn,
      "${aws_s3_bucket.velero.arn}/*",
    ]
  }
  # EBS snapshot perms not needed — we're using Kopia file-system backup (not CSI snapshots)
  # If we add CSI snapshots later, append EC2 snapshot perms here.
}

resource "aws_iam_role_policy" "velero" {
  role   = aws_iam_role.velero.name
  policy = data.aws_iam_policy_document.velero.json
}

# === etcd-backup role ===

resource "aws_iam_role" "etcd_backup" {
  name               = "${local.cluster_name}-etcd-backup"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["etcd-backup"].json
  tags = {
    "app.kubernetes.io/part-of"   = "backup"
    "app.kubernetes.io/component" = "etcd-backup"
  }
}

data "aws_iam_policy_document" "etcd_backup" {
  statement {
    sid = "EtcdSnapshotS3Write"
    actions = [
      "s3:PutObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.etcd_snapshots.arn,
      "${aws_s3_bucket.etcd_snapshots.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "etcd_backup" {
  role   = aws_iam_role.etcd_backup.name
  policy = data.aws_iam_policy_document.etcd_backup.json
}

# === Outputs (Octopus consumes these) ===

output "velero_role_arn" {
  value = aws_iam_role.velero.arn
}

output "etcd_backup_role_arn" {
  value = aws_iam_role.etcd_backup.arn
}

output "velero_bucket" {
  value = aws_s3_bucket.velero.bucket
}

output "etcd_snapshots_bucket" {
  value = aws_s3_bucket.etcd_snapshots.bucket
}
