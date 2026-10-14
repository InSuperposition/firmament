variable "state_directory" {
  type        = string
  description = "The environment's state directory; the machine-hosts contract is written into it."
}

variable "environment" {
  type        = string
  description = "Name of the environment, as the mise tasks pass it; the machine is named <environment>-<cluster>."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase letters, digits and -, starting with a letter."
  }
}

variable "environments_directory" {
  type        = string
  default     = null
  description = "Directory holding <environment>/environment.yaml; the repository's environments folder when unset."
}
