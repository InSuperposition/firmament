terraform {
  required_version = ">= 1.12.0"

  required_providers {
    orbstack = {
      source  = "registry.terraform.io/robertdebock/orbstack"
      version = "3.1.2"
    }
  }

  backend "local" {}
}
