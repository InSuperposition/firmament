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

  runtime_info_fields = [
    "api_address", "api_port", "kube_proxy_replacement", "cilium_datapath_mode",
    "cilium_operator_replicas", "environment", "cluster", "git_branch",
  ]

  invalid_runtime_info_fields = [
    for field in local.runtime_info_fields : "runtime_info.${field}"
    if !try(jsonencode(local.cluster.runtime_info[field]) == jsonencode(tostring(local.cluster.runtime_info[field])), false)
  ]
}

# The cluster-access contract, checked where it is read. The same fields
# contracts/cluster-access/schema.cue declares: a kubeconfig path and the
# eight runtime values, every one a string because Flux substitution is
# plain text replacement.
resource "terraform_data" "cluster_access_contract" {
  input = local.cluster

  lifecycle {
    precondition {
      condition     = try(local.cluster.kubeconfig_path != "", false)
      error_message = "cluster-access.yaml: kubeconfig_path must be set."
    }
    precondition {
      condition     = length(local.invalid_runtime_info_fields) == 0
      error_message = "cluster-access.yaml: ${join(", ", local.invalid_runtime_info_fields)} must be present and a string."
    }
    precondition {
      condition     = try(length(setsubtract(keys(local.cluster.runtime_info), local.runtime_info_fields)) == 0 && length(setsubtract(keys(local.cluster), ["kubeconfig_path", "runtime_info"])) == 0, false)
      error_message = "cluster-access.yaml: only kubeconfig_path and runtime_info (with ${join(", ", local.runtime_info_fields)}) are allowed."
    }
  }
}

provider "kubernetes" {
  config_path = local.cluster.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = local.cluster.kubeconfig_path
  }
}
