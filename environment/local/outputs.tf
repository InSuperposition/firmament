output "machine_name" {
  value = module.vm_orb.name
}

output "machine_ip" {
  value = module.vm_orb.ip_address
}

output "machine_status" {
  value = module.vm_orb.status
}

output "k0s_yaml" {
  value       = module.orch_k0s.k0s_yaml
  description = "Rendered k0sctl contract, for inspection."
}

output "kubeconfig_path" {
  value = local_sensitive_file.kubeconfig.filename
}

output "kube_proxy_replacement" {
  value       = var.kube_proxy_replacement
  description = "Whether Cilium replaces kube-proxy in this cluster, as applied. The cluster suite reads it to know which mode to expect."
}
