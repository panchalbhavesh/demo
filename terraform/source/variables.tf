variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "cluster_name" {
  type    = string
  default = "scylla-demo-source"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

# 1 managed node group, 3 fixed nodes, per the current sizing requirement.
variable "node_instance_types" {
  type    = list(string)
  default = ["m7i-flex.large"]
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_min_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 3
}

# BEST PRACTICE default is false (private endpoint only). Flip to true + list your
# IP/CIDR in public_access_cidrs if you need to reach the API from outside the VPC
# without a bastion/VPN/SSM session.
variable "enable_public_endpoint" {
  type    = bool
  default = false
}

variable "public_access_cidrs" {
  type    = list(string)
  default = []
}

variable "tags" {
  type = map(string)
  default = {
    Owner = "platform-demo"
  }
}

# Set to "your-github-org/your-repo-name" to enable the GitHub Actions
# backup workflow (.github/workflows/scylla-backup.yml). Leave null to skip
# creating the GitHub OIDC provider/IAM role entirely — everything in
# github-oidc.tf is conditional on this being set.
variable "github_repo" {
  type    = string
  default = null
}
