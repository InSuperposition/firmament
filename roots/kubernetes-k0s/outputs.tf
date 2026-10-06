output "k0sctl_config_path" {
  value       = local_file.k0sctl.filename
  description = "The rendered k0sctl configuration the k0sctl edge applies."
}

output "known_hosts_path" {
  value       = local_file.known_hosts.filename
  description = "The trust file the rendered configuration names."
}

output "kubeconfig_path" {
  value       = "${var.state_directory}/admin.kubeconfig"
  description = "Where the k0sctl edge writes the kubeconfig."
}

output "runtime_info" {
  value       = local.runtime_info
  description = "Values the packages substitute; the bootstrap root hands them to Flux, and the cluster suites check the cluster against them."
}

output "cluster_access_path" {
  value       = "${var.state_directory}/cluster-access.yaml"
  description = "The cluster-access contract the bootstrap root reads."
}
