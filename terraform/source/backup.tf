############################################################
# S3 backup bucket for ScyllaDB (source cluster).
#
# This project runs a plain StatefulSet instead of the ScyllaDB Operator
# and Manager (see kubernetes/scylla/04-scylla-statefulset.yaml), so backup
# is a script instead of a Manager Agent sidecar. This bucket and the IAM
# role below are what kubernetes/scylla/backup/backup.sh and restore.sh
# use, through the "scylla-backup" ServiceAccount, either from the
# in-cluster CronJob (kubernetes/scylla/backup/cronjob.yaml) or the GitHub
# Actions workflows (.github/workflows/scylla-backup.yml and
# scylla-restore.yml).
############################################################

resource "aws_s3_bucket" "scylla_backups" {
  bucket = "${var.cluster_name}-backups"

  tags = merge(var.tags, {
    Purpose = "scylla-backups"
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

# Ages out old backup generations instead of keeping them forever. Adjust
# or remove this if you want indefinite retention.
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

# --- IAM: least-privilege pod-identity role for the backup job ---
# Used by the "scylla-backup" ServiceAccount in namespace "scylla" (see
# kubernetes/scylla/backup/rbac.yaml), which the CronJob and the GitHub
# Actions workflows both run as, via EKS Pod Identity. No AWS keys stored
# anywhere.
data "aws_iam_policy_document" "scylla_backup_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scylla_backup" {
  name               = "${var.cluster_name}-scylla-backup"
  assume_role_policy = data.aws_iam_policy_document.scylla_backup_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "scylla_backup_s3" {
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

resource "aws_iam_role_policy" "scylla_backup" {
  name   = "${var.cluster_name}-scylla-backup-s3"
  role   = aws_iam_role.scylla_backup.id
  policy = data.aws_iam_policy_document.scylla_backup_s3.json
}

resource "aws_eks_pod_identity_association" "scylla_backup" {
  cluster_name    = module.cluster.cluster_name
  namespace       = "scylla"
  service_account = "scylla-backup"
  role_arn        = aws_iam_role.scylla_backup.arn

  depends_on = [module.cluster, aws_iam_role_policy.scylla_backup]
}

output "scylla_backup_bucket" {
  value = aws_s3_bucket.scylla_backups.bucket
}

output "scylla_backup_role_arn" {
  value = aws_iam_role.scylla_backup.arn
}

# These resources used to be named manager_agent (from when this project
# still planned on ScyllaDB Manager). The moved blocks tell Terraform to
# treat this as a rename in its state rather than an unrelated destroy and
# create. The IAM role's name argument changed too though, and that forces
# AWS to replace the role either way (IAM role names can't be updated in
# place), so plan on `terraform apply` recreating scylla_backup and briefly
# reassigning the pod identity association.
moved {
  from = data.aws_iam_policy_document.manager_agent_assume
  to   = data.aws_iam_policy_document.scylla_backup_assume
}
moved {
  from = aws_iam_role.scylla_manager_agent
  to   = aws_iam_role.scylla_backup
}
moved {
  from = data.aws_iam_policy_document.manager_agent_s3
  to   = data.aws_iam_policy_document.scylla_backup_s3
}
moved {
  from = aws_iam_role_policy.scylla_manager_agent
  to   = aws_iam_role_policy.scylla_backup
}
