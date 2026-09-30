# The bootstrap has its own root and state, applied after the environment
# root has created the cluster. The Kubernetes provider must not be
# configured from resources created in the same apply, and keeping the
# in-cluster objects out of the environment's state lets a destroy remove
# the machine without reaching the API server. After a rebuild, refresh
# finds the old namespace and release gone and plans them again.
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }

  backend "local" {}
}

# The environment root's outputs: the kubeconfig it wrote and the runtime
# values Flux substitutes.
data "terraform_remote_state" "environment" {
  backend = "local"

  config = {
    path = "${var.state_directory}/terraform.tfstate"
  }
}

locals {
  environment = data.terraform_remote_state.environment.outputs
}

provider "kubernetes" {
  config_path = local.environment.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = local.environment.kubeconfig_path
  }
}
