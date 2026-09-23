locals {
  k0s_cluster_config = {
    apiVersion = "k0s.k0sproject.io/v1beta1"
    kind       = "ClusterConfig"
    metadata = {
      name = var.cluster_name
    }
    spec = {
      api = {
        externalAddress = var.api_address
      }
      network = {
        provider    = "custom"
        podCIDR     = "10.244.0.0/16"
        serviceCIDR = "10.96.0.0/12"
        kubeProxy = {
          disabled = true
        }
      }
    }
  }
}

resource "k0sctl_config" "this" {
  metadata {
    name = var.cluster_name
  }

  spec {
    k0s {
      version = "1.36.4+k0s.0"
      config  = yamlencode(local.k0s_cluster_config)
    }

    host {
      role      = "controller+worker"
      no_taints = true

      ssh {
        address  = var.ssh_address
        user     = var.ssh_user
        port     = var.ssh_port
        key_path = var.ssh_key_path
      }
    }
  }
}
