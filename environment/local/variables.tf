variable "orbstack_ssh_key_path" {
  type        = string
  description = "Absolute path to the SSH private key k0sctl uses to reach the OrbStack machine as root."
}

variable "state_directory" {
  type        = string
  description = "Directory the rendered kubeconfig is written into."
}

variable "kube_proxy_replacement" {
  type        = bool
  default     = true
  description = "Whether Cilium replaces kube-proxy. Fixed at cluster creation: changing it on a live cluster requires teardown and bootstrap."
}
