output "k0s_yaml" {
  value       = k0sctl_config.firmament.k0s_yaml
  description = "Rendered k0sctl contract, for inspection."
}

resource "local_sensitive_file" "kubeconfig" {
  content         = k0sctl_config.firmament.kube_yaml
  filename        = "${var.state_directory}/admin.kubeconfig"
  file_permission = "0600"
}
