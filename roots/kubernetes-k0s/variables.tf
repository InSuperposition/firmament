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

variable "git_commit" {
  type        = string
  default     = ""
  description = "Commit of this repository that Flux applies: the tip of git_branch on origin. The publish pass writes it to the cluster-access contract and refuses an empty value."

  validation {
    condition     = var.git_commit == "" || can(regex("^[0-9a-f]{40}$", var.git_commit))
    error_message = "git_commit must be empty or 40 lowercase hex characters."
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

variable "environments_directory" {
  type        = string
  default     = null
  description = "Directory holding <environment>/environment.yaml; the repository's environments folder when unset."
}

variable "publish_cluster_access" {
  type        = bool
  default     = false
  description = "Whether to write the cluster-access contract. The task that runs k0sctl sets it true in the pass after the API answers, and false in every other pass, which removes the file."
}
