variable "state_directory" {
  type        = string
  description = "The environment's state directory: holds the machine-hosts contract this root reads, and receives the kubeconfig and the cluster-access contract."
}

variable "git_branch" {
  type        = string
  description = "Branch of this repository that Flux follows. The bootstrap Job interpolates it into a shell command, so only letters, digits and . _ / - are accepted, and it may not start with -. The mise tasks also check it with git check-ref-format before passing it."

  validation {
    condition     = can(regex("^[A-Za-z0-9._/][A-Za-z0-9._/-]*$", var.git_branch))
    error_message = "git_branch must use letters, digits and . _ / - only, and not start with -."
  }
}

variable "environment" {
  type        = string
  description = "Name of the environment this cluster runs in, as the mise tasks pass it; Flux reads it from the runtime values."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase letters, digits and -, starting with a letter."
  }
}
