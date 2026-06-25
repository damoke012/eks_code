data "aws_caller_identity" "current" {
  provider = aws.source
}

# ---- Source bucket: read existing, enable versioning ----

data "aws_s3_bucket" "source" {
  provider = aws.source
  bucket   = var.source_bucket_name
}

resource "aws_s3_bucket_versioning" "source" {
  provider = aws.source
  bucket   = data.aws_s3_bucket.source.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ---- Destination bucket: create in us-west-2 ----

resource "aws_s3_bucket" "destination" {
  provider = aws.destination
  bucket   = var.destination_bucket_name
  tags     = var.tags
}

resource "aws_s3_bucket_versioning" "destination" {
  provider = aws.destination
  bucket   = aws_s3_bucket.destination.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "destination" {
  provider = aws.destination
  bucket   = aws_s3_bucket.destination.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "destination" {
  provider                = aws.destination
  bucket                  = aws_s3_bucket.destination.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---- IAM role for replication ----

data "aws_iam_policy_document" "replication_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  provider           = aws.source
  name               = "lazy-tf-state-crr-replication-role"
  assume_role_policy = data.aws_iam_policy_document.replication_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "replication" {
  # Read on source
  statement {
    sid    = "SourceRead"
    effect = "Allow"
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket"
    ]
    resources = [data.aws_s3_bucket.source.arn]
  }
  statement {
    sid    = "SourceObjectRead"
    effect = "Allow"
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging"
    ]
    resources = ["${data.aws_s3_bucket.source.arn}/*"]
  }
  # Write on destination
  statement {
    sid    = "DestinationWrite"
    effect = "Allow"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags"
    ]
    resources = ["${aws_s3_bucket.destination.arn}/*"]
  }

  # Decrypt source objects (source uses SSE-KMS with alias/aws/s3)
  statement {
    sid     = "KMSSourceDecrypt"
    effect  = "Allow"
    actions = ["kms:Decrypt"]
    resources = [var.source_kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.us-east-2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "replication" {
  provider = aws.source
  name     = "lazy-tf-state-crr-replication-policy"
  role     = aws_iam_role.replication.id
  policy   = data.aws_iam_policy_document.replication.json
}

# ---- Replication configuration on source ----

resource "aws_s3_bucket_replication_configuration" "source" {
  provider = aws.source
  depends_on = [
    aws_s3_bucket_versioning.source,
    aws_s3_bucket_versioning.destination,
  ]

  role   = aws_iam_role.replication.arn
  bucket = data.aws_s3_bucket.source.id

  rule {
    id     = "replicate-all-to-us-west-2"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.destination.arn
      storage_class = "STANDARD"
    }
  }
}
