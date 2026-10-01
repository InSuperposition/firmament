variable "state_directory" {
  type        = string
  description = "The environment's state directory; the machine-hosts contract is written into it."
}

variable "orbstack_ssh_key_path" {
  type        = string
  default     = null
  description = "Absolute path to the SSH private key k0sctl uses to reach the OrbStack machine as root. Defaults to the key OrbStack creates, ~/.orbstack/ssh/id_ed25519."
}
