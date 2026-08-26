output "cluster_name" {
  value = module.cluster.cluster_name
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "vpc_id" {
  value = module.cluster.vpc_id
}

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.cluster.cluster_name} --region ${var.aws_region} --alias source"
}
