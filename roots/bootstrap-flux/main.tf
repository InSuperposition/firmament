# The bootstrap has its own root and state, applied after the Kubernetes
# root has created the cluster. The Kubernetes provider must not be
# configured from resources created in the same apply, and keeping the
# in-cluster objects out of the other roots' state lets a destroy remove
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

# The cluster-access contract the Kubernetes root wrote: the kubeconfig
# path and the runtime values Flux substitutes.
locals {
  cluster = yamldecode(file("${var.state_directory}/cluster-access.yaml"))
}

provider "kubernetes" {
  config_path = local.cluster.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = local.cluster.kubeconfig_path
  }
}
