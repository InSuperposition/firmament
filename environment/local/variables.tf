variable "orbstack_ssh_key_path" {
  type        = string
  default     = null
  description = "Absolute path to the SSH private key k0sctl uses to reach the OrbStack machine as root. Defaults to the key OrbStack creates, ~/.orbstack/ssh/id_ed25519."
}

variable "state_directory" {
  type        = string
  description = "Directory the rendered kubeconfig is written into."
}

variable "git_branch" {
  type        = string
  description = "Branch of this repository that Flux follows. The bootstrap Job interpolates it into a shell command, so only letters, digits and . _ / - are accepted, and it may not start with -. The mise tasks also check it with git check-ref-format before passing it."

  validation {
    condition     = can(regex("^[A-Za-z0-9._/][A-Za-z0-9._/-]*$", var.git_branch))
    error_message = "git_branch must use letters, digits and . _ / - only, and not start with -."
  }
}
