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

variable "cluster_name" {
  type        = string
  default     = "firmament"
  description = "k0s cluster name."
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

variable "helm_charts" {
  type = list(object({
    repository = object({
      name = string
      url  = string
    })
    chart = object({
      name      = string
      chartname = string
      version   = string
      namespace = string
      values    = string
    })
  }))
  default     = []
  description = "Helm charts k0s installs during cluster bring-up, each with the repository it comes from."

  validation {
    condition     = length(distinct([for helm_chart in var.helm_charts : helm_chart.repository.name])) == length(distinct([for helm_chart in var.helm_charts : helm_chart.repository]))
    error_message = "each Helm repository name must point at one URL."
  }
}
