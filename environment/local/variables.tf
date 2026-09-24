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
  description = "Branch of this repository that Flux follows. The bootstrap Job interpolates it into a shell command, so only letters, digits and . _ / - are accepted."

  validation {
    condition = (
      can(regex("^[A-Za-z0-9._/-]+$", var.git_branch)) &&
      !startswith(var.git_branch, "-") &&
      !startswith(var.git_branch, "/") &&
      !endswith(var.git_branch, "/") &&
      !endswith(var.git_branch, ".") &&
      !endswith(var.git_branch, ".lock") &&
      !strcontains(var.git_branch, "..") &&
      !strcontains(var.git_branch, "//")
    )
    error_message = "git_branch must be a Git branch name made of letters, digits and . _ / - only."
  }
}
