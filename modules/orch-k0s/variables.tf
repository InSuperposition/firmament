variable "ssh_address" {
  type        = string
  description = "SSH endpoint address of the controller+worker host."

  validation {
    condition     = can(regex("^[A-Za-z0-9._:-]+$", var.ssh_address))
    error_message = "invalid SSH address."
  }
}

variable "ssh_user" {
  type        = string
  description = "SSH user for the controller+worker host."

  validation {
    condition     = can(regex("^[A-Za-z0-9_.@-]+$", var.ssh_user))
    error_message = "invalid SSH user."
  }
}

variable "ssh_port" {
  type        = number
  description = "SSH port for the controller+worker host."

  validation {
    condition     = var.ssh_port >= 1 && var.ssh_port <= 65535
    error_message = "invalid SSH port."
  }
}

variable "ssh_key_path" {
  type        = string
  description = "Absolute path to the SSH private key."

  validation {
    condition     = can(regex("^/", var.ssh_key_path)) && !can(regex("\n", var.ssh_key_path))
    error_message = "invalid SSH key path."
  }
}

variable "known_hosts_path" {
  type        = string
  description = "Absolute path to the known_hosts file that holds the host's server keys. k0sctl trusts only that file."

  validation {
    condition     = can(regex("^/", var.known_hosts_path)) && !can(regex("\n", var.known_hosts_path))
    error_message = "invalid known_hosts path."
  }
}

variable "cluster_name" {
  type        = string
  default     = "firmament"
  description = "k0s cluster name."
}

variable "k0s_version" {
  type        = string
  default     = "1.36.4+k0s.1"
  description = "k0s release k0sctl installs on the host. The one place the version is set; bump it by changing this default and running the renderer's tests. The host runs no k0s binary of its own."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\+k0s\\.[0-9]+$", var.k0s_version))
    error_message = "k0s_version must look like 1.36.4+k0s.1."
  }
}

variable "pod_cidr" {
  type        = string
  description = "Pod network of the cluster, from its mesh allocation. Fixed at cluster creation."

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a CIDR."
  }
}

variable "service_cidr" {
  type        = string
  default     = "10.96.0.0/12"
  description = "Service network of the cluster."

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "service_cidr must be a CIDR."
  }
}

variable "api_address" {
  type        = string
  description = "External address published in the k0s API server certificate."

  validation {
    condition     = can(regex("^[A-Za-z0-9._:-]+$", var.api_address))
    error_message = "invalid API address."
  }
}

variable "api_port" {
  type        = number
  default     = 6443
  description = "Port the k0s API server listens on and advertises."

  validation {
    condition     = var.api_port >= 1 && var.api_port <= 65535 && floor(var.api_port) == var.api_port
    error_message = "invalid API port."
  }
}

variable "kube_proxy_replacement" {
  type        = bool
  default     = true
  description = "Whether the CNI replaces kube-proxy, so k0s does not run it. Fixed at cluster creation."
}
