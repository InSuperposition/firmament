output "k0sctl_yaml" {
  value       = yamlencode(local.k0sctl_cluster)
  description = "The complete k0sctl configuration as YAML text. The caller writes it to a file and runs k0sctl; this module writes nothing."

  # k0s fixes the kube-proxy setting when the cluster is created, and
  # switching it in place breaks the pod network.
  precondition {
    condition     = terraform_data.kube_proxy_replacement_at_creation.output == var.kube_proxy_replacement
    error_message = "kube_proxy_replacement is fixed at cluster creation; switching it in place breaks the pod network. Run teardown, then bootstrap with the new value."
  }
}
