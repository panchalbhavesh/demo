variable "cluster_name" {
  description = "Unique EKS cluster name, also used for the VPC name and tag discovery."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR range for this cluster's VPC. Must not overlap another cluster's CIDR."
  type        = string
}

variable "caller_identity_arn" {
  description = "ARN used as the KMS key administrator (pass data.aws_caller_identity.current.arn from the caller)."
  type        = string
}

variable "enable_public_endpoint" {
  description = "Whether the EKS API is reachable from outside the VPC. Best practice: false, using a bastion/SSM/VPN instead."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint, when enable_public_endpoint is true. Never default this to 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "node_group_name" {
  description = "Name of the single managed node group."
  type        = string
  default     = "scylla-demo"
}

variable "node_instance_types" {
  description = "On-demand instance types for the node group."
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_min_size" {
  type    = number
  default = 3
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "tags" {
  type    = map(string)
  default = {}
}
