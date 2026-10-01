output "k0s_yaml" {
  value       = module.orch_k0s.k0s_yaml
  description = "Rendered k0sctl contract, for inspection."
}

output "kubeconfig_path" {
  value = local_sensitive_file.kubeconfig.filename
}

output "runtime_info" {
  value       = local.runtime_info
  description = "Values the packages substitute; the bootstrap root hands them to Flux, and the cluster suites check the cluster against them."
}

output "cluster_access_path" {
  value       = local_file.cluster_access.filename
  description = "The cluster-access contract the bootstrap root reads."
}
