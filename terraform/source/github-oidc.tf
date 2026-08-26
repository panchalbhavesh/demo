############################################################
# GitHub Actions OIDC federation for the backup workflow
# (.github/workflows/scylla-backup.yml).
#
# No static AWS keys stored in GitHub — the workflow exchanges a
# short-lived GitHub-issued OIDC token for temporary AWS credentials via
# this IAM role, scoped to exactly one repo.
#
# Everything here is a no-op (count = 0) until var.github_repo is set.
############################################################

data "tls_certificate" "github" {
  count = var.github_repo != null ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.github_repo != null ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]
  tags            = var.tags
}

data "aws_iam_policy_document" "github_actions_assume" {
  count = var.github_repo != null ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Restricts to this exact repo, any branch/tag/PR. Tighten to a specific
    # ref (e.g. "repo:${var.github_repo}:ref:refs/heads/main") if you only
    # want the workflow runnable from main.
    #
    # Two patterns because GitHub's `sub` claim format varies: the classic
    # "repo:owner/repo:ref:..." form, and a newer one that embeds numeric
    # owner/repo IDs — "repo:owner@<ownerId>/repo@<repoId>:ref:..." (added
    # to stop a deleted-and-recreated repo of the same name from inheriting
    # trust). Observed directly from this repo's actual token: confirmed via
    # a debug step decoding the OIDC JWT, not assumed from docs.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:*",
        "repo:${split("/", var.github_repo)[0]}@*/${split("/", var.github_repo)[1]}@*:*",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_backup" {
  count              = var.github_repo != null ? 1 : 0
  name               = "${var.cluster_name}-github-actions-backup"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume[0].json
  tags               = var.tags
}

# Needs to describe the cluster (for `aws eks update-kubeconfig`) and write
# to the same backup bucket as the in-cluster CronJob.
data "aws_iam_policy_document" "github_actions_backup" {
  count = var.github_repo != null ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [module.cluster.cluster_arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.scylla_backups.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.scylla_backups.arn}/*"]
  }
}

resource "aws_iam_role_policy" "github_actions_backup" {
  count  = var.github_repo != null ? 1 : 0
  name   = "${var.cluster_name}-github-actions-backup"
  role   = aws_iam_role.github_actions_backup[0].id
  policy = data.aws_iam_policy_document.github_actions_backup[0].json
}

# Maps the IAM role to a Kubernetes RBAC group ("scylla-backup-ci") once it
# authenticates — see rbac.yaml's Group-bound RoleBinding for what that
# group can actually do (same scoped exec permissions as the CronJob's
# ServiceAccount, nothing more).
resource "aws_eks_access_entry" "github_actions_backup" {
  count             = var.github_repo != null ? 1 : 0
  cluster_name      = module.cluster.cluster_name
  principal_arn     = aws_iam_role.github_actions_backup[0].arn
  kubernetes_groups = ["scylla-backup-ci"]
  type              = "STANDARD"
}

output "github_actions_backup_role_arn" {
  value       = var.github_repo != null ? aws_iam_role.github_actions_backup[0].arn : null
  description = "Set this as the AWS_ROLE_ARN input in .github/workflows/scylla-backup.yml"
}
