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
