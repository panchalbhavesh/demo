############################################################
# S3 backup bucket for ScyllaDB (source cluster).
#
# The demo dropped ScyllaDB Operator + Manager in favor of a plain
# StatefulSet (see kubernetes/scylla/04-scylla-statefulset.yaml),
# so there's no Manager Agent sidecar to auto-upload backups yet. This
# bucket + IAM role are provisioned ahead of that: the role is scoped to a
# future "scylla-backup" ServiceAccount (e.g. a CronJob running
# `nodetool snapshot` + `aws s3 sync`) that doesn't exist yet. Not wired to
# anything until that job is built.
############################################################

resource "aws_s3_bucket" "scylla_backups" {
  bucket = "${var.cluster_name}-backups"

  tags = merge(var.tags, {
    Purpose = "scylladb-manager-backups"
  })
}

resource "aws_s3_bucket_versioning" "scylla_backups" {
  bucket = aws_s3_bucket.scylla_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "scylla_backups" {
  bucket = aws_s3_bucket.scylla_backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "scylla_backups" {
  bucket                  = aws_s3_bucket.scylla_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DEMO: age out old backup generations instead of keeping them forever.
# Adjust/remove if you want indefinite retention.
resource "aws_s3_bucket_lifecycle_configuration" "scylla_backups" {
  bucket = aws_s3_bucket.scylla_backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    expiration {
      days = 90
    }
  }
}

# --- IAM: least-privilege pod-identity role for a future backup job ---
# NOT wired to any running pod yet. service_account "scylla-backup" in
# namespace "scylla" is a placeholder for whatever CronJob/Job you build to
# actually run backups (nodetool snapshot + upload to this bucket). Create
# that ServiceAccount when you build the job, matching this name (or update
# this association to match whatever name you pick).
data "aws_iam_policy_document" "manager_agent_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scylla_manager_agent" {
  name               = "${var.cluster_name}-scylla-manager-agent"
  assume_role_policy = data.aws_iam_policy_document.manager_agent_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "manager_agent_s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.scylla_backups.arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectVersion",
      "s3:ListMultipartUploadParts",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.scylla_backups.arn}/*"]
  }
}

resource "aws_iam_role_policy" "scylla_manager_agent" {
  name   = "${var.cluster_name}-scylla-manager-agent-s3"
  role   = aws_iam_role.scylla_manager_agent.id
  policy = data.aws_iam_policy_document.manager_agent_s3.json
}

resource "aws_eks_pod_identity_association" "scylla_backup" {
  cluster_name    = module.cluster.cluster_name
  namespace       = "scylla"
  service_account = "scylla-backup"
  role_arn        = aws_iam_role.scylla_manager_agent.arn

  depends_on = [module.cluster, aws_iam_role_policy.scylla_manager_agent]
}

output "scylla_backup_bucket" {
  value = aws_s3_bucket.scylla_backups.bucket
}

output "scylla_backup_role_arn" {
  value = aws_iam_role.scylla_manager_agent.arn
}
