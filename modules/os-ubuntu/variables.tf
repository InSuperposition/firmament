variable "ssh_target" {
  type        = string
  description = "SSH target (user@host, or an OrbStack user@machine@orb alias)."

  validation {
    condition     = length(var.ssh_target) > 0
    error_message = "ssh_target is required."
  }
}

variable "ssh_port" {
  type        = number
  default     = null
  description = "SSH port, if not the default."
}

variable "ssh_identity_file" {
  type        = string
  default     = null
  description = "Path to an SSH private key, if not using the default identity."
}
