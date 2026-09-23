output "k0s_yaml" {
  value       = k0sctl_config.this.k0s_yaml
  description = "Rendered k0sctl contract, for inspection."
}

output "kube_yaml" {
  value       = k0sctl_config.this.kube_yaml
  description = "kubeconfig content — write this to disk from the caller."
  sensitive   = true
}
