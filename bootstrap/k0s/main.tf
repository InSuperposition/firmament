terraform {
  required_version = ">= 1.12.0"

  required_providers {
    k0sctl = {
      source  = "registry.terraform.io/Mirantis/k0sctl"
      version = "0.0.3"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  backend "local" {}
}
