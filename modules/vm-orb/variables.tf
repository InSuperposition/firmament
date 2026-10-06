variable "name" {
  type        = string
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
