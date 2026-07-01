# QA cluster TF state backend.
# Provisions the S3 bucket + DynamoDB lock table in USX-QA (us-east-2) that
# iaac-talos QA branch (feature/op-usxpress-qa) will use as its terraform
# backend. Also sets up CRR to us-west-2 for regional durability.
#
# S3 CRR with SSE-KMS carries a triple-gotcha (see feedback_s3_crr_with_sse_kms_triple_gotcha):
#   1. Source-side kms:Decrypt required with kms:ViaService condition
#   2. source_selection_criteria.sse_kms_encrypted_objects must be Enabled
#      (otherwise KMS-encrypted objects are silently skipped)
#   3. Destination CMK required (default SSE-S3 is not sufficient once source uses KMS)
# All three are baked in below.

data "aws_caller_identity" "current" {
  provider = aws.source
}

# ---- Source bucket: primary state bucket in USX-QA us-east-2 ----

resource "aws_s3_bucket" "source" {
  provider = aws.source
  bucket   = var.source_bucket_name
  tags     = var.tags
}

resource "aws_s3_bucket_versioning" "source" {
  provider = aws.source
  bucket   = aws_s3_bucket.source.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_kms_key" "source" {
  provider                = aws.source
  description             = "CMK for QA tf-state source bucket in USX-QA"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "source" {
  provider      = aws.source
  name          = "alias/lazy-tf-state-usx-qa"
  target_key_id = aws_kms_key.source.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  provider = aws.source
  bucket   = aws_s3_bucket.source.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.source.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "source" {
  provider                = aws.source
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---- DynamoDB state-lock table (us-east-2) ----

resource "aws_dynamodb_table" "tf_lock" {
  provider     = aws.source
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = var.tags
}

# ---- Destination bucket: CRR replica in us-west-2 ----

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

resource "aws_kms_key" "replica" {
  provider                = aws.destination
  description             = "CMK for QA tf-state CRR replica bucket in us-west-2"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "replica" {
  provider      = aws.destination
  name          = "alias/lazy-tf-state-usx-qa-replica"
  target_key_id = aws_kms_key.replica.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "destination" {
  provider = aws.destination
  bucket   = aws_s3_bucket.destination.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.replica.arn
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

# ---- IAM role for S3-to-S3 replication ----

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
  name               = "lazy-tf-state-usx-qa-crr-replication-role"
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
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.source.arn]
  }
  statement {
    sid    = "SourceObjectRead"
    effect = "Allow"
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = ["${aws_s3_bucket.source.arn}/*"]
  }

  # Write on destination
  statement {
    sid    = "DestinationWrite"
    effect = "Allow"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]
    resources = ["${aws_s3_bucket.destination.arn}/*"]
  }

  # Gotcha #1: decrypt source-side KMS objects
  statement {
    sid       = "KMSSourceDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.source.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.us-east-2.amazonaws.com"]
    }
  }

  # Encrypt replicas with destination CMK
  statement {
    sid    = "KMSDestinationEncrypt"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:ReEncrypt*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.replica.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.us-west-2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "replication" {
  provider = aws.source
  name     = "lazy-tf-state-usx-qa-crr-replication-policy"
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
  bucket = aws_s3_bucket.source.id

  rule {
    id     = "replicate-all-to-us-west-2"
    status = "Enabled"

    filter {}

    # Gotcha #2: MUST be Enabled or KMS-encrypted objects are silently skipped
    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.destination.arn
      storage_class = "STANDARD"

      # Gotcha #3: must specify destination CMK
      encryption_configuration {
        replica_kms_key_id = aws_kms_key.replica.arn
      }
    }
  }
}
