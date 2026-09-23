variable "api_host" {
  type        = string
  description = "Kubernetes API server host the Cilium agent connects to directly, without kube-proxy."

  validation {
    condition     = can(regex("^[A-Za-z0-9._:-]+$", var.api_host))
    error_message = "invalid API host."
  }
}

variable "api_port" {
  type        = number
  default     = 6443
  description = "Kubernetes API server port."

  validation {
    condition     = var.api_port >= 1 && var.api_port <= 65535 && floor(var.api_port) == var.api_port
    error_message = "invalid API port."
  }
}

variable "kube_proxy_replacement" {
  type        = bool
  description = "Whether Cilium replaces kube-proxy, which also selects the netkit datapath over veth. Must match the cluster's kube-proxy setting."
}

variable "operator_replicas" {
  type        = number
  default     = 2
  description = "Cilium operator replica count."

  validation {
    condition     = var.operator_replicas >= 1 && floor(var.operator_replicas) == var.operator_replicas
    error_message = "operator_replicas must be a whole number of at least 1."
  }
}
