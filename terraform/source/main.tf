############################################################
# SOURCE cluster — own Terraform state. This first pass creates
# ONLY the EKS cluster + Cluster Autoscaler. ScyllaDB, ScyllaDB
# Manager, and the S3 backup bucket will be layered in as
# separate follow-up steps once this cluster is confirmed good.
############################################################

module "cluster" {
  source = "../modules/cluster"

  cluster_name           = var.cluster_name
  kubernetes_version     = var.kubernetes_version
  vpc_cidr               = var.vpc_cidr
  caller_identity_arn    = data.aws_caller_identity.current.arn
  enable_public_endpoint = var.enable_public_endpoint
  public_access_cidrs    = var.public_access_cidrs

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  tags = var.tags
}

data "aws_eks_cluster_auth" "this" {
  name = module.cluster.cluster_name
}

provider "kubernetes" {
  host                   = module.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.46.6"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.cluster.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.aws_region
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }
  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }
  set {
    name  = "extraArgs.skip-nodes-with-local-storage"
    value = "false"
  }

  depends_on = [module.cluster]
}

# cert-manager and the ScyllaDB Operator are installed via kubectl/helm CLI,
# not Terraform — see kubernetes/operator/README.md. Reason: unlike
# Cluster Autoscaler (a plain Deployment), the Operator's Helm chart creates
# CRDs that a later kubectl-applied ScyllaCluster resource depends on. Adding
# them here isn't wrong, but it's inconsistent with the ScyllaCluster CR
# itself already being kubectl-managed for CRD chicken-and-egg reasons — so
# both are kept on the same mechanism instead of splitting the install
# across Terraform and kubectl.
