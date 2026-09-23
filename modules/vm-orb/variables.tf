variable "name" {
  type        = string
  default     = "firmament"
  description = "OrbStack machine name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.name))
    error_message = "invalid machine name."
  }
}

variable "image" {
  type        = string
  default     = "ubuntu:resolute"
  description = "OrbStack image, OS:VERSION format."
}

variable "arch" {
  type        = string
  default     = "arm64"
  description = "Machine architecture."

  validation {
    condition     = contains(["arm64", "amd64"], var.arch)
    error_message = "arch must be arm64 or amd64."
  }
}

variable "username" {
  type        = string
  default     = "tensor"
  description = "Default Linux user created on the machine."
}
