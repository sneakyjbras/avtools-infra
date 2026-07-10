output "cluster_id" {
  description = "Magnum cluster UUID."
  value       = openstack_containerinfra_cluster_v1.avtools.id
}

output "cluster_name" {
  description = "Magnum cluster name (use with `openstack coe cluster config`)."
  value       = openstack_containerinfra_cluster_v1.avtools.name
}

output "api_address" {
  description = "Kubernetes API endpoint."
  value       = openstack_containerinfra_cluster_v1.avtools.api_address
}

output "kubeconfig_hint" {
  description = "How to obtain a kubeconfig for kubectl/ArgoCD."
  value       = "eval $(openstack coe cluster config ${openstack_containerinfra_cluster_v1.avtools.name})"
}
