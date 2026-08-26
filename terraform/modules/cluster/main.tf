############################################################
# modules/cluster
#
# Reusable EKS cluster: VPC (3 AZ, private + public subnets),
# KMS-encrypted secrets, EKS control plane, one managed node
# group (fixed size, Cluster Autoscaler-discoverable), and the
# IAM role Cluster Autoscaler needs via Pod Identity.
############################################################

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = merge(var.tags, {
    Project     = var.cluster_name
    ManagedBy   = "Terraform"
    Environment = "demo"
  })
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for index in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 4, index)]
  public_subnets  = [for index in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 4, index + 8)]

  # One shared NAT Gateway to keep this demo cheap. For resilience you'd
  # want one per AZ instead, set one_nat_gateway_per_az = true for that.
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false
  enable_dns_hostnames   = true
  enable_dns_support     = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  # Cluster Autoscaler discovers this node group's ASG through these tags.
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"               = "1"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"             = "true"
  }

  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_destination_type            = "cloud-watch-logs"

  tags = local.tags
}

# Skipping customer-managed KMS envelope encryption for Kubernetes Secrets
# in this demo. Secrets are still encrypted at rest through AWS's default
# etcd encryption. Add a module "eks_kms" block and an `encryption_config`
# on module.eks if you want customer-managed key envelope encryption.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.2"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # API is always reachable from inside the VPC. Public access is opt-in via
  # enable_public_endpoint, restricted to whatever CIDRs you pass in
  # public_access_cidrs. This demo's tfvars sets it to 0.0.0.0/0 on purpose,
  # so Terraform and kubectl can run from outside the VPC without a
  # bastion or VPN. Tighten this to your own IP range for anything real.
  endpoint_private_access       = true
  endpoint_public_access        = var.enable_public_endpoint
  endpoint_public_access_cidrs  = var.enable_public_endpoint ? var.public_access_cidrs : null

  # CloudWatch control-plane logging is off to keep this cheap. Flip
  # enabled_log_types and create_cloudwatch_log_group to turn it on.
  # create_cloudwatch_log_group defaults to true regardless of
  # enabled_log_types, so it needs to be turned off explicitly or the
  # module creates the log group anyway.
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  # One managed node group, fixed at var.node_desired_size (default 3), one
  # per AZ. Cluster Autoscaler is installed (see the helm release in
  # source/main.tf) so this group can scale between node_min_size and
  # node_max_size if those are widened later, but for now min=desired=max
  # so capacity stays predictable and cheap.
  eks_managed_node_groups = {
    (var.node_group_name) = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      update_config = {
        max_unavailable = 1
      }

      metadata_options = {
        http_endpoint = "enabled"
        http_tokens   = "required"
      }
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            encrypted   = true
            volume_type = "gp3"
            volume_size = 40
          }
        }
      }

      labels = {
        workload = "scylla-demo"
      }

      tags = {
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
        "k8s.io/cluster-autoscaler/enabled"              = "true"
      }
    }
  }

  tags = local.tags
}

# --- EBS CSI driver: least-privilege pod-identity role ---
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# No standalone aws_eks_pod_identity_association for ebs-csi here. The
# module.eks addons block above creates and wires it via
# pod_identity_association, which guarantees the role and association exist
# before the addon tries to start controller pods. A separate top-level
# association resource can race against addon creation if there's no
# depends_on link, and the addon's health check will time out waiting for
# controller pods to become ready.

# --- Cluster Autoscaler: least-privilege pod-identity role ---
data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "autoscaling:DescribeScalingActivities",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.cluster_name}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name   = "${var.cluster_name}-cluster-autoscaler"
  role   = aws_iam_role.cluster_autoscaler.id
  policy = data.aws_iam_policy_document.cluster_autoscaler.json
}

resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler.arn

  depends_on = [module.eks, aws_iam_role_policy.cluster_autoscaler]
}
