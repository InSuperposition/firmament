output "machine_name" {
  value = local.machine.name
}

output "machine_ip" {
  value = local.machine.address
}

output "k0s_yaml" {
  value       = module.orch_k0s.k0s_yaml
  description = "Rendered k0sctl contract, for inspection."
}

output "kubeconfig_path" {
  value = local_sensitive_file.kubeconfig.filename
}

output "runtime_info" {
  value       = local.runtime_info
  description = "Values the components substitute; the bootstrap root hands them to Flux, and the cluster suites check the cluster against them."
}
